import Foundation
import XCTest

@testable import Reqs

private func code(_ request: APIRequest) -> String { SwiftGenerator().generate(from: request) }

private func lines(_ request: APIRequest) -> [String] { code(request).components(separatedBy: "\n") }

/// Parses the generated Swift with `swiftc -parse`, which checks the syntax (string escaping included) without compiling.
private func parseErrors(_ source: String) throws -> String? {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftGeneratorTests-\(UUID().uuidString).swift")
    try source.write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["swiftc", "-parse", file.path]
    let errors = Pipe()
    process.standardError = errors
    process.standardOutput = Pipe()
    try process.run()
    let output = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? nil : String(decoding: output, as: UTF8.self)
}

/// A `URLProtocol` put before the generated code: it answers the generated request offline by printing what was sent as JSON and exiting.
private let capturingHarness = #"""
    import Foundation
    final class CapturingProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 { body.append(buffer, count: count) }
            }
            let sent: [String: Any] = [
                "url": request.url?.absoluteString ?? "", "method": request.httpMethod ?? "", "headers": request.allHTTPHeaderFields ?? [:],
                "body": body.base64EncodedString(),
            ]
            FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: sent))
            exit(0)
        }
        override func stopLoading() {}
    }
    URLProtocol.registerClass(CapturingProtocol.self)

    """#

/// Compiles the generated code with `swiftc` and runs it against `CapturingProtocol`, returning what the request sent (body decoded to `Data`).
private func runGenerated(_ source: String) throws -> [String: Any]? {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftGeneratorRun-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("main.swift")
    let binary = directory.appendingPathComponent("generated")
    try (capturingHarness + source).write(to: file, atomically: true, encoding: .utf8)
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    compile.arguments = ["swiftc", "-swift-version", "5", "-o", binary.path, file.path]
    let errors = Pipe()
    compile.standardError = errors
    compile.standardOutput = Pipe()
    try compile.run()
    let compileErrors = errors.fileHandleForReading.readDataToEndOfFile()
    compile.waitUntilExit()
    guard compile.terminationStatus == 0 else {
        XCTFail(String(decoding: compileErrors, as: UTF8.self))
        return nil
    }
    let run = Process()
    run.executableURL = binary
    let output = Pipe()
    run.standardOutput = output
    run.standardError = Pipe()
    try run.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    run.waitUntilExit()
    guard run.terminationStatus == 0, var sent = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    sent["body"] = (sent["body"] as? String).flatMap { Data(base64Encoded: $0) }
    return sent
}

final class SwiftGeneratorTests: XCTestCase {
    func testPlainGetBuildsTheURLAndSetsTheMethod() {
        let output = lines(APIRequest(name: "g", url: "https://api.example.com/users"))
        XCTAssertEqual(
            Array(output.prefix(4)), ["import Foundation", #"let url = URL(string: "https://api.example.com/users")!"#, "var request = URLRequest(url: url)", #"request.httpMethod = "GET""#])
        XCTAssertFalse(code(APIRequest(name: "g", url: "https://h")).contains("URLComponents"))
    }

    func testEveryMethodIsSetExplicitly() {
        for method in HTTPMethod.allCases {
            XCTAssertTrue(lines(APIRequest(name: "m", url: "https://h", method: method)).contains("request.httpMethod = \"\(method.rawValue)\""), method.rawValue)
        }
    }

    func testFormDataIsBuiltAsMultipartPartsWithABoundary() throws {
        let request = APIRequest(name: "f", url: "https://h/upload", method: .post)
        request.bodyType = .formData
        request.bodyContent = "name=Ana%20Lu&quo%22te=a%5C(b)%0Ac"
        let sent = try XCTUnwrap(try runGenerated(code(request)))
        let contentType = try XCTUnwrap((sent["headers"] as? [String: String])?["Content-Type"])
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary=Boundary-"), contentType)
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        XCTAssertEqual(
            String(decoding: sent["body"] as? Data ?? Data(), as: UTF8.self),
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\nAna Lu\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"quo%22te\"\r\n\r\na\\(b)\nc\r\n--\(boundary)--\r\n")
    }

    func testHeadSetsNoBodyAndPatchDoes() throws {
        let request = APIRequest(name: "h", url: "https://h", method: .head)
        request.bodyType = .json
        request.bodyContent = #"{"a":1}"#
        XCTAssertFalse(code(request).contains("httpBody"), "URLSession times out on a HEAD with a body")
        XCTAssertFalse(code(request).contains("Content-Type"))
        request.method = .patch
        XCTAssertTrue(code(request).contains("request.httpBody"))
    }

    func testEnabledParamsBecomeQueryItems() {
        let request = APIRequest(name: "q", url: "https://api.example.com/search")
        request.queryParams = [
            KeyValuePair(key: "q", value: "hello world"), KeyValuePair(key: "off", value: "1", isEnabled: false), KeyValuePair(key: "", value: "keyless"),
            KeyValuePair(key: "lang", value: "pt")
        ]
        XCTAssertEqual(
            Array(lines(request)[1...5]),
            [
                #"var components = URLComponents(string: "https://api.example.com/search")!"#, "let queryItems = [", #"    URLQueryItem(name: "q", value: "hello world"),"#,
                #"    URLQueryItem(name: "lang", value: "pt"),"#, "]"
            ])
        XCTAssertTrue(lines(request).contains("let url = components.url!"))
    }

    func testOnlyDisabledParamsFallBackToAPlainURL() {
        let request = APIRequest(name: "q", url: "https://h")
        request.queryParams = [KeyValuePair(key: "off", value: "1", isEnabled: false)]
        XCTAssertEqual(lines(request)[1], #"let url = URL(string: "https://h")!"#)
    }

    func testHeaderValuesAreEscapedForAStringLiteral() {
        let cases = [
            (#"say "hi""#, #"say \"hi\""#), (#"C:\path"#, #"C:\\path"#), ("a\nb", #"a\nb"#), ("a\rb", #"a\rb"#), ("a\tb", #"a\tb"#), ("café 💅", "café 💅"), ("", "")
        ]
        for (value, escaped) in cases {
            let request = APIRequest(name: "h", url: "https://h")
            request.headers = [KeyValuePair(key: "X-V", value: value)]
            XCTAssertTrue(lines(request).contains("request.setValue(\"\(escaped)\", forHTTPHeaderField: \"X-V\")"), value)
        }
    }

    func testDisabledAndKeylessHeadersAreLeftOut() {
        let request = APIRequest(name: "h", url: "https://h")
        request.headers = [KeyValuePair(key: "Off", value: "1", isEnabled: false), KeyValuePair(key: "", value: "keyless")]
        XCTAssertFalse(code(request).contains("request.setValue("))
    }

    func testBearerSetsAnEscapedAuthorizationHeader() {
        let request = APIRequest(name: "a", url: "https://h")
        request.authenticationType = .bearer
        request.authBearerToken = #"abc"def"#
        XCTAssertTrue(lines(request).contains(#"request.setValue("Bearer abc\"def", forHTTPHeaderField: "Authorization")"#))
        request.authBearerToken = ""
        XCTAssertFalse(code(request).contains("Authorization"))
        request.authBearerToken = nil
        XCTAssertFalse(code(request).contains("Authorization"))
    }

    func testBasicAuthEncodesCredentialsAtRunTime() {
        let request = APIRequest(name: "a", url: "https://h")
        request.authenticationType = .basic
        request.authBasicUsername = #"us"er"#
        request.authBasicPassword = #"p\ss"#
        let output = lines(request)
        XCTAssertTrue(output.contains(#"let credentials = "us\"er:p\\ss""#))
        XCTAssertTrue(output.contains("let base64Credentials = Data(credentials.utf8).base64EncodedString()"))
        XCTAssertTrue(output.contains(#"request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")"#))
    }

    func testBasicAuthNeedsBothFieldsAndOtherTypesAddNothing() {
        let request = APIRequest(name: "a", url: "https://h")
        request.authBearerToken = "token"
        request.authBasicUsername = nil
        request.authBasicPassword = nil
        for type in [AuthenticationType.basic, .none, .oauth2] {
            request.authenticationType = type
            XCTAssertFalse(code(request).contains("Authorization"), type.rawValue)
        }
        // One field is enough: the one never typed is empty.
        request.authBasicUsername = "user"
        request.authenticationType = .basic
        XCTAssertTrue(code(request).contains(#"let credentials = "user:""#))
    }

    func testJSONBodyGoesInAMultilineLiteral() {
        let request = APIRequest(name: "b", url: "https://h", method: .post)
        request.bodyType = .json
        request.bodyContent = "{\n  \"name\": \"Ada\"\n}"
        XCTAssertTrue(code(request).contains("let jsonBody = #\"\"\"\n{\n  \"name\": \"Ada\"\n}\n\"\"\"#\nrequest.httpBody = jsonBody.data(using: .utf8)\n"))
        XCTAssertTrue(lines(request).contains(#"request.setValue("application/json", forHTTPHeaderField: "Content-Type")"#))
    }

    func testOtherBodiesAreEscapedSingleLineLiterals() {
        for type in ContentType.allCases where type != .none && type != .json && type != .formData && type != .file {
            let request = APIRequest(name: "b", url: "https://h", method: .post)
            request.bodyType = type
            request.bodyContent = "say \"hi\"\n\tdone \\"
            let output = lines(request)
            XCTAssertTrue(output.contains(#"request.httpBody = "say \"hi\"\n\tdone \\".data(using: .utf8)"#), type.rawValue)
            XCTAssertTrue(output.contains("request.setValue(\"\(type.mimeType!)\", forHTTPHeaderField: \"Content-Type\")"), type.rawValue)
        }
    }

    func testExplicitContentTypeSuppressesTheDefaultButADisabledOneDoesNot() {
        let request = APIRequest(name: "b", url: "https://h", method: .post)
        request.bodyType = .json
        request.bodyContent = "{}"
        request.headers = [KeyValuePair(key: "CONTENT-TYPE", value: "application/vnd.api+json")]
        XCTAssertEqual(lines(request).filter { $0.contains("\"Content-Type\"") }, [], "Only the user's header, under its own spelling")
        XCTAssertTrue(lines(request).contains(#"request.setValue("application/vnd.api+json", forHTTPHeaderField: "CONTENT-TYPE")"#))
        request.headers[0].isEnabled = false
        XCTAssertTrue(lines(request).contains(#"request.setValue("application/json", forHTTPHeaderField: "Content-Type")"#))
    }

    func testNoBodyForTheNoneTypeOrEmptyContent() {
        for (type, content) in [(ContentType.none, "ignored"), (.text, "")] {
            let request = APIRequest(name: "b", url: "https://h", method: .post)
            request.bodyType = type
            request.bodyContent = content
            XCTAssertFalse(code(request).contains("httpBody"), type.rawValue)
            XCTAssertFalse(code(request).contains("Content-Type"), type.rawValue)
        }
    }

    func testEndsWithATaskAndARunLoopSoAScriptWaitsForTheResponse() {
        let output = code(APIRequest(name: "g", url: "https://h"))
        XCTAssertTrue(output.contains("let task = URLSession.shared.dataTask(with: request) { data, response, error in"))
        XCTAssertTrue(output.contains("task.resume()"))
        XCTAssertTrue(output.hasSuffix("RunLoop.main.run(until: Date(timeIntervalSinceNow: 30))"))
        XCTAssertTrue(output.contains(#"print("Status Code: \(httpResponse.statusCode)")"#), "Runtime interpolation is kept, not evaluated by the generator")
    }

    func testGeneratedCodeParsesWithSwiftc() throws {
        XCTAssertNotNil(try parseErrors(#"let broken = "unterminated"#), "The parser check itself must reject bad syntax")
        let request = APIRequest(name: "all", url: "https://api.example.com/items", method: .put)
        request.queryParams = [KeyValuePair(key: "q", value: "a b")]
        request.headers = [KeyValuePair(key: "X-Quote", value: "say \"hi\" \\ \n\r\t done")]
        request.authenticationType = .basic
        request.authBasicUsername = "u\"1"
        request.authBasicPassword = "p\\2"
        request.bodyType = .text
        request.bodyContent = "line \"1\"\nline \\2"
        if let errors = try parseErrors(code(request)) { XCTFail(errors) }
        request.bodyType = .json
        request.bodyContent = "{\n  \"a\": [1, true, null]\n}"
        request.authenticationType = .bearer
        request.authBearerToken = "tok\"en"
        if let errors = try parseErrors(code(request)) { XCTFail(errors) }
    }

    func testGeneratedCodeSendsTheJSONBodyByteForByte() throws {
        let request = APIRequest(name: "j", url: "https://api.example.com/items", method: .post)
        request.bodyType = .json
        request.bodyContent = "{\"esc\":\"x\\ny\",\"interp\":\"\\(x)\",\"hash\":\"#\\\"\\\"\\\"#\",\"raw\":\"\\#(y)\",\"quotes\":\"\"\"\",\"path\":\"C:\\\\dir\"}\r\n{\"tab\":\"\t\"}"
        let sent = try XCTUnwrap(try runGenerated(code(request)), "The generated code should compile and send")
        XCTAssertEqual(sent["body"] as? Data, Data(request.bodyContent.utf8))
        XCTAssertEqual(sent["method"] as? String, "POST")
    }

    func testURLQueryItemsHeadersAndBodiesAreEscapedLiterals() throws {
        let request = APIRequest(name: "e", url: #"https://h/a"b\(c)"#, method: .put)
        request.queryParams = [KeyValuePair(key: #"q"\(n)"#, value: #"v"\(x)\"#)]
        request.headers = [KeyValuePair(key: #"X-"K"\(k)"#, value: "v")]
        request.bodyType = .text
        request.bodyContent = "say \"hi\" \\(x) \u{0}\u{1}\r\n"
        if let errors = try parseErrors(code(request)) { XCTFail(errors) }
        request.headers = [KeyValuePair(key: "X-V", value: #"a"\(b)\"#)]
        let sent = try XCTUnwrap(try runGenerated(code(request)), "The generated code should compile and send")
        XCTAssertEqual(sent["url"] as? String, "https://h/a%22b%5C(c)?q%22%5C(n)=v%22%5C(x)%5C")
        XCTAssertEqual((sent["headers"] as? [String: String])?["X-V"], #"a"\(b)\"#)
        XCTAssertEqual(sent["body"] as? Data, Data(request.bodyContent.utf8))
    }

    func testParamsAreAppendedToTheURLsOwnQueryBeforeTheFragment() throws {
        let request = APIRequest(name: "q", url: "https://h/x?a=1&raw=%2F#frag")
        request.queryParams = [KeyValuePair(key: "b", value: "2"), KeyValuePair(key: "off", value: "1", isEnabled: false)]
        let sent = try XCTUnwrap(try runGenerated(code(request)), "The generated code should compile and send")
        XCTAssertEqual(sent["url"] as? String, "https://h/x?a=1&raw=%2F&b=2#frag")
    }

    func testEscapesInAURLWithSpacesAreSentAsWrittenWithAndWithoutParams() throws {
        let plain = APIRequest(name: "q", url: "https://h/a%2Fb c?q=%2F d")
        XCTAssertEqual(try XCTUnwrap(try runGenerated(code(plain)))["url"] as? String, "https://h/a%2Fb%20c?q=%2F%20d")
        let withParams = APIRequest(name: "q", url: "https://h/{{id}}?q=%2F d")
        withParams.queryParams = [KeyValuePair(key: "b", value: "2")]
        XCTAssertEqual(try XCTUnwrap(try runGenerated(code(withParams)))["url"] as? String, "https://h/%7B%7Bid%7D%7D?q=%2F%20d&b=2")
    }

    func testParamNamesAndValuesArePercentEncodedLikeTheAppSendsThem() throws {
        let request = APIRequest(name: "q", url: "https://h/x")
        request.queryParams = [KeyValuePair(key: "a&b=c+d#e", value: "1 2+3&4=5#6/?:@"), KeyValuePair(key: "empty", value: ""), KeyValuePair(key: "é", value: "💅")]
        let sent = try XCTUnwrap(try runGenerated(code(request)), "The generated code should compile and send")
        XCTAssertEqual(sent["url"] as? String, "https://h/x?a%26b%3Dc%2Bd%23e=1%202%2B3%264%3D5%236/?:@&empty=&%C3%A9=%F0%9F%92%85")
    }

    func testBasicAndBearerCredentialsAreEscapedLiterals() throws {
        let request = APIRequest(name: "c", url: "https://h")
        request.authenticationType = .basic
        request.authBasicUsername = #"u"\(1)"#
        request.authBasicPassword = #"p\(2)\"#
        let basic = try XCTUnwrap(try runGenerated(code(request)), "The generated code should compile and send")
        XCTAssertEqual((basic["headers"] as? [String: String])?["Authorization"], "Basic " + Data(#"u"\(1):p\(2)\"#.utf8).base64EncodedString())
        request.authenticationType = .bearer
        request.authBearerToken = #"t"\(k)"#
        let bearer = try XCTUnwrap(try runGenerated(code(request)), "The generated code should compile and send")
        XCTAssertEqual((bearer["headers"] as? [String: String])?["Authorization"], #"Bearer t"\(k)"#)
    }
}
