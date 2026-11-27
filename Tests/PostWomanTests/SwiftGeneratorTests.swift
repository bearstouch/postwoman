import Foundation
import XCTest

@testable import PostWoman

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

    func testEnabledParamsBecomeQueryItems() {
        let request = APIRequest(name: "q", url: "https://api.example.com/search")
        request.queryParams = [
            KeyValuePair(key: "q", value: "hello world"), KeyValuePair(key: "off", value: "1", isEnabled: false), KeyValuePair(key: "", value: "keyless"),
            KeyValuePair(key: "lang", value: "pt")
        ]
        XCTAssertEqual(
            Array(lines(request)[1...6]),
            [
                #"var components = URLComponents(string: "https://api.example.com/search")!"#, "components.queryItems = [", #"    URLQueryItem(name: "q", value: "hello world"),"#,
                #"    URLQueryItem(name: "lang", value: "pt"),"#, "]", "let url = components.url!"
            ])
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
        request.authBasicUsername = "user"
        request.authBasicPassword = nil
        for type in [AuthenticationType.basic, .none, .oauth2] {
            request.authenticationType = type
            XCTAssertFalse(code(request).contains("Authorization"), type.rawValue)
        }
    }

    func testJSONBodyGoesInAMultilineLiteral() {
        let request = APIRequest(name: "b", url: "https://h", method: .post)
        request.bodyType = .json
        request.bodyContent = "{\n  \"name\": \"Ada\"\n}"
        XCTAssertTrue(code(request).contains("let jsonBody = \"\"\"\n{\n  \"name\": \"Ada\"\n}\n\"\"\"\nrequest.httpBody = jsonBody.data(using: .utf8)\n"))
        XCTAssertTrue(lines(request).contains(#"request.setValue("application/json", forHTTPHeaderField: "Content-Type")"#))
    }

    func testOtherBodiesAreEscapedSingleLineLiterals() {
        for type in ContentType.allCases where type != .none && type != .json {
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
}
