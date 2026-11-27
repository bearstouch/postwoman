import Foundation
import XCTest

@testable import PostWoman

private func code(_ request: APIRequest) -> String { PythonGenerator().generate(from: request) }

private func lines(_ request: APIRequest) -> [String] { code(request).components(separatedBy: "\n") }

/// The `response = requests.…(…)` call line.
private func call(_ request: APIRequest) -> String? { lines(request).first { $0.hasPrefix("response = requests.") } }

private func body(_ content: String, _ type: ContentType) -> APIRequest {
    let request = APIRequest(name: "b", url: "https://h", method: .post)
    request.bodyType = type
    request.bodyContent = content
    return request
}

/// Evaluates the generated script with `python3` after stubbing `requests`, returning what the request call received as JSON.
private func pythonCall(_ source: String) throws -> [String: Any]? {
    let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }
    guard let python else { throw XCTSkip("python3 not found") }
    let stub = """
        import json, sys, types
        captured = {}
        def call(method):
            def f(url, **kw):
                captured.update(kw, method=method, url=url)
                return types.SimpleNamespace(status_code=200, headers={}, text="")
            return f
        sys.modules["requests"] = types.SimpleNamespace(**{m: call(m) for m in ["get", "post", "put", "delete"]})
        import builtins
        builtins.print = lambda *a, **k: None
        exec(compile(sys.stdin.read(), "generated.py", "exec"))
        sys.stdout.write(json.dumps(captured))
        """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: python)
    process.arguments = ["-I", "-W", "error", "-c", stub]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    input.fileHandleForWriting.write(Data(source.utf8))
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return try JSONSerialization.jsonObject(with: data) as? [String: Any]
}

final class PythonGeneratorTests: XCTestCase {
    func testPlainGetIsAMinimalScript() {
        XCTAssertEqual(
            code(APIRequest(name: "g", url: "https://api.example.com/users")),
            """
            import requests

            url = "https://api.example.com/users"
            response = requests.get(url)

            print(f"Status Code: {response.status_code}")
            print(f"Headers: {dict(response.headers)}")
            print(f"Response Body:")
            print(response.text)

            # For JSON responses, you can also use:
            # print(response.json())
            """)
    }

    func testMethodsAreLowercasedRequestsFunctions() {
        for method in HTTPMethod.allCases {
            XCTAssertEqual(call(APIRequest(name: "m", url: "https://h", method: method)), "response = requests.\(method.rawValue.lowercased())(url)", method.rawValue)
        }
    }

    func testEnabledParamsBecomeAnEscapedDict() {
        let request = APIRequest(name: "q", url: "https://h")
        request.queryParams = [
            KeyValuePair(key: "q", value: #"say "hi" \ now"#), KeyValuePair(key: "off", value: "1", isEnabled: false), KeyValuePair(key: "", value: "keyless"),
            KeyValuePair(key: "n", value: "a\nb")
        ]
        let output = lines(request)
        let start = try! XCTUnwrap(output.firstIndex(of: "params = {"))
        XCTAssertEqual(Array(output[start...(start + 3)]), ["params = {", #"    "q": "say \"hi\" \\ now","#, #"    "n": "a\nb","#, "}"])
        XCTAssertEqual(call(request), "response = requests.get(url, params=params)")
    }

    func testOnlyDisabledParamsAddNoParamsDict() {
        let request = APIRequest(name: "q", url: "https://h")
        request.queryParams = [KeyValuePair(key: "off", value: "1", isEnabled: false)]
        XCTAssertFalse(code(request).contains("params"))
    }

    func testEnabledHeadersBecomeAnEscapedDict() {
        let request = APIRequest(name: "h", url: "https://h")
        request.headers = [KeyValuePair(key: "Accept", value: "application/json"), KeyValuePair(key: "Off", value: "1", isEnabled: false), KeyValuePair(key: "X-Q", value: #"a"b"#)]
        let output = lines(request)
        let start = try! XCTUnwrap(output.firstIndex(of: "headers = {"))
        XCTAssertEqual(Array(output[start...(start + 3)]), ["headers = {", #"    "Accept": "application/json","#, #"    "X-Q": "a\"b","#, "}"])
        XCTAssertEqual(call(request), "response = requests.get(url, headers=headers)")
    }

    func testBearerAddsAnAuthorizationHeaderEvenWithoutOtherHeaders() {
        let request = APIRequest(name: "a", url: "https://h")
        request.authenticationType = .bearer
        request.authBearerToken = #"t"k"#
        XCTAssertTrue(lines(request).contains(#"    "Authorization": "Bearer t\"k","#))
        XCTAssertEqual(call(request), "response = requests.get(url, headers=headers)")
        for token in [nil, ""] as [String?] {
            request.authBearerToken = token
            XCTAssertFalse(code(request).contains("headers ="), String(describing: token))
            XCTAssertEqual(call(request), "response = requests.get(url)", String(describing: token))
        }
    }

    func testBearerFollowsTheUsersHeaders() {
        let request = APIRequest(name: "a", url: "https://h")
        request.headers = [KeyValuePair(key: "Accept", value: "*/*")]
        request.authenticationType = .bearer
        request.authBearerToken = "t"
        let output = lines(request)
        XCTAssertEqual(output.firstIndex(of: #"    "Accept": "*/*","#)! + 1, output.firstIndex(of: #"    "Authorization": "Bearer t","#))
    }

    func testBasicAuthIsAnEscapedTuple() {
        let request = APIRequest(name: "a", url: "https://h")
        request.authenticationType = .basic
        request.authBasicUsername = #"u"1"#
        request.authBasicPassword = #"p\2"#
        XCTAssertTrue(lines(request).contains(#"auth = ("u\"1", "p\\2")"#))
        XCTAssertEqual(call(request), "response = requests.get(url, auth=auth)")
        request.authBasicPassword = nil
        XCTAssertFalse(code(request).contains("auth"))
    }

    func testOnlyTheSelectedAuthTypesCredentialsAreUsed() {
        let request = APIRequest(name: "a", url: "https://h")
        request.authBearerToken = "token"
        request.authBasicUsername = "user"
        request.authBasicPassword = "pass"
        let expected: [AuthenticationType: String] = [
            .none: "response = requests.get(url)", .oauth2: "response = requests.get(url)", .bearer: "response = requests.get(url, headers=headers)",
            .basic: "response = requests.get(url, auth=auth)"
        ]
        for type in AuthenticationType.allCases {
            request.authenticationType = type
            XCTAssertEqual(call(request), expected[type], type.rawValue)
        }
    }

    func testJSONBodyBecomesAPythonLiteral() {
        let output = lines(body(#"{"on":true,"off":false,"nothing":null,"n":1.5,"list":[1,2]}"#, .json))
        for line in [#"  "on" : True,"#, #"  "off" : False,"#, #"  "nothing" : None,"#, #"  "n" : 1.5,"#] {
            XCTAssertTrue(output.contains(line) || output.contains(String(line.dropLast())), line)
        }
        XCTAssertEqual(output.first { $0.hasPrefix("json_data") }, "json_data = {")
        XCTAssertEqual(call(body("{}", .json)), "response = requests.post(url, json=json_data)")
    }

    func testInvalidJSONFallsBackToATripleQuotedString() {
        XCTAssertTrue(lines(body("{not json", .json)).contains(#"json_data = """{not json""""#))
    }

    func testOtherBodiesAreTripleQuotedData() {
        for type in ContentType.allCases where type != .none && type != .json {
            let request = body("a=1&b=2\nsecond", type)
            XCTAssertTrue(code(request).contains("data = \"\"\"a=1&b=2\nsecond\"\"\"\n"), type.rawValue)
            XCTAssertEqual(call(request), "response = requests.post(url, data=data)", type.rawValue)
        }
    }

    func testNoBodyForTheNoneTypeOrEmptyContent() {
        XCTAssertEqual(call(body("ignored", .none)), "response = requests.post(url)")
        XCTAssertEqual(call(body("", .json)), "response = requests.post(url)")
    }

    func testCallArgumentsComeInParamsHeadersBodyAuthOrder() {
        let request = body(#"{"a":1}"#, .json)
        request.queryParams = [KeyValuePair(key: "q", value: "1")]
        request.headers = [KeyValuePair(key: "A", value: "1")]
        request.authenticationType = .basic
        request.authBasicUsername = "u"
        request.authBasicPassword = "p"
        XCTAssertEqual(call(request), "response = requests.post(url, params=params, headers=headers, json=json_data, auth=auth)")
    }

    func testGeneratedScriptRunsAndPassesWhatTheRequestHolds() throws {
        XCTAssertNil(try pythonCall("x = \"unterminated\n"), "The harness itself must reject bad syntax")
        XCTAssertNil(try pythonCall(#"x = "\d""#), "Invalid escapes are errors, not warnings, in the harness")
        let request = body(#"{"name":"Ada","admin":false,"tags":["x"],"boss":null}"#, .json)
        request.method = .put
        request.url = "https://api.example.com/users/1"
        request.queryParams = [KeyValuePair(key: "q", value: "say \"hi\" \\ \n done")]
        request.headers = [KeyValuePair(key: "X-Note", value: "naïve \"quote\"")]
        request.authenticationType = .basic
        request.authBasicUsername = "u\"1"
        request.authBasicPassword = "p\\2"
        let captured = try XCTUnwrap(try pythonCall(code(request)), "The script should run without errors or warnings")
        XCTAssertEqual(captured["method"] as? String, "put")
        XCTAssertEqual(captured["url"] as? String, "https://api.example.com/users/1")
        XCTAssertEqual(captured["params"] as? [String: String], ["q": "say \"hi\" \\ \n done"])
        XCTAssertEqual(captured["headers"] as? [String: String], ["X-Note": "naïve \"quote\""])
        XCTAssertEqual(captured["auth"] as? [String], ["u\"1", "p\\2"])
        let json = try XCTUnwrap(captured["json"] as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "Ada")
        XCTAssertEqual(json["admin"] as? Bool, false)
        XCTAssertEqual(json["tags"] as? [String], ["x"])
        XCTAssertTrue(json["boss"] is NSNull)
    }
}
