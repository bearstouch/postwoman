import Foundation
import XCTest

@testable import Reqs

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
    guard let data = try pythonOutput(source) else { return nil }
    return try JSONSerialization.jsonObject(with: data) as? [String: Any]
}

/// What the stubbed request call received, as the JSON text `json.dumps` writes (dict order kept), or nil if the script failed.
private func pythonOutput(_ source: String) throws -> Data? {
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
        sys.modules["requests"] = types.SimpleNamespace(**{m: call(m) for m in ["get", "post", "put", "patch", "delete", "head", "options"]})
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
    return process.terminationStatus == 0 ? data : nil
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

    func testFormDataFieldsGoAsMultipartFields() throws {
        let request = body("name=Ana%20Lu&q=%22x%22&name=again", .formData)
        XCTAssertEqual(call(request), "response = requests.post(url, files=files)")
        XCTAssertFalse(code(request).contains("Content-Type"), "requests writes the multipart header with its boundary")
        let received = try XCTUnwrap(try pythonCall(code(request)))
        XCTAssertEqual(received["files"] as? NSArray, [["name", [NSNull(), "Ana Lu"]], ["q", [NSNull(), "\"x\""]], ["name", [NSNull(), "again"]]] as NSArray)
        XCTAssertNil(received["data"])
    }

    func testMethodsAreLowercasedRequestsFunctions() {
        for method in HTTPMethod.allCases {
            let redirects = method == .head ? ", allow_redirects=True" : ""
            XCTAssertEqual(
                call(APIRequest(name: "m", url: "https://h", method: method)), "response = requests.\(method.rawValue.lowercased())(url\(redirects))", method.rawValue)
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
        XCTAssertTrue(lines(request).contains(#"auth = ("u\"1", "")"#), "A password never typed is an empty one")
        request.authBasicUsername = nil
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
        let start = try! XCTUnwrap(output.firstIndex(of: "json_data = {"))
        XCTAssertEqual(
            Array(output[start...(start + 9)]),
            ["json_data = {", #"    "on": True,"#, #"    "off": False,"#, #"    "nothing": None,"#, #"    "n": 1.5,"#, #"    "list": ["#, "        1,", "        2,", "    ],", "}"])
        XCTAssertEqual(output.first { $0.hasPrefix("json_data") }, "json_data = {")
        XCTAssertEqual(call(body("{}", .json)), "response = requests.post(url, json=json_data)")
    }

    func testInvalidJSONIsSentAsWrittenWithTheJSONContentType() {
        let request = body("{not json", .json)
        XCTAssertTrue(lines(request).contains(#"data = """{not json""""#))
        XCTAssertTrue(lines(request).contains(#"    "Content-Type": "application/json","#))
        XCTAssertEqual(call(request), "response = requests.post(url, headers=headers, data=data)")
        request.headers = [KeyValuePair(key: "content-TYPE", value: "application/vnd.api+json")]
        XCTAssertFalse(code(request).contains(#""Content-Type": "application/json""#), "The request's own Content-Type is kept")
    }

    func testOtherBodiesAreTripleQuotedData() {
        for type in ContentType.allCases where type != .none && type != .json && type != .formData && type != .file {
            let request = body("a=1&b=2\nsecond", type)
            XCTAssertTrue(code(request).contains("data = \"\"\"a=1&b=2\nsecond\"\"\"\n"), type.rawValue)
            XCTAssertEqual(call(request), "response = requests.post(url, headers=headers, data=data)", type.rawValue)
        }
    }

    func testAJSONBodyOfNullIsSentAsWrittenNotAsNoBody() throws {
        // requests reads `json=None` as no body at all; the app sends the four characters with the JSON Content-Type.
        for content in ["null", " null\n"] {
            let request = body(content, .json)
            XCTAssertEqual(call(request), "response = requests.post(url, headers=headers, data=data)", content)
            let received = try XCTUnwrap(try pythonCall(code(request)))
            XCTAssertEqual(received["data"] as? String, content)
            XCTAssertEqual((received["headers"] as? [String: String])?["Content-Type"], "application/json")
            XCTAssertNil(received["json"])
        }
        XCTAssertEqual(call(body("[null]", .json)), "response = requests.post(url, json=json_data)", "null inside a value is still None")
    }

    func testARepeatedParamIsSentEachTimeInOrder() throws {
        // A dict keeps only the last value of a repeated key; the app sends ?id=1&tag=a&id=2.
        let request = APIRequest(name: "q", url: "https://h")
        request.queryParams = [KeyValuePair(key: "id", value: "1"), KeyValuePair(key: "tag", value: "a"), KeyValuePair(key: "id", value: "2")]
        let output = lines(request)
        let start = try XCTUnwrap(output.firstIndex(of: "params = ["))
        XCTAssertEqual(Array(output[start...(start + 4)]), ["params = [", #"    ("id", "1"),"#, #"    ("tag", "a"),"#, #"    ("id", "2"),"#, "]"])
        let captured = try XCTUnwrap(try pythonCall(code(request)))
        XCTAssertEqual(captured["params"] as? [[String]], [["id", "1"], ["tag", "a"], ["id", "2"]])
    }

    func testTextBodiesCarryTheContentTypeTheAppSends() throws {
        // requests sets no Content-Type for a str body, and the app always sends the body type's.
        for type in [ContentType.xml, .text, .urlEncoded] {
            let request = body("<a/>", type)
            let received = try XCTUnwrap(try pythonCall(code(request)))
            XCTAssertEqual((received["headers"] as? [String: String])?["Content-Type"], type.mimeType, type.rawValue)
            request.headers = [KeyValuePair(key: "content-type", value: "application/vnd.custom")]
            let own = try XCTUnwrap(try pythonCall(code(request)))
            XCTAssertEqual(own["headers"] as? [String: String], ["content-type": "application/vnd.custom"], "The request's own Content-Type is the only one")
        }
        XCTAssertFalse(code(body("ignored", .none)).contains("Content-Type"))
        let head = body("<a/>", .xml)
        head.method = .head
        XCTAssertFalse(code(head).contains("Content-Type"), "No body, no Content-Type")
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

    func testHeadFollowsRedirectsLikeTheAppAndSendsNoBody() throws {
        let request = body(#"{"a":1}"#, .json)
        request.method = .head
        let captured = try XCTUnwrap(try pythonCall(code(request)), "The script should run")
        XCTAssertEqual(captured["method"] as? String, "head")
        XCTAssertEqual(captured["allow_redirects"] as? Bool, true, "requests.head doesn't follow redirects unless asked; the app does")
        XCTAssertNil(captured["json"])
        XCTAssertNil(captured["data"])
        XCTAssertNil(captured["headers"], "No Content-Type for a body that isn't sent")
    }

    func testPatchAndOptionsRunAndSendTheirBody() throws {
        for method in [HTTPMethod.patch, .options] {
            let request = body(#"{"a":1}"#, .json)
            request.method = method
            let captured = try XCTUnwrap(try pythonCall(code(request)), method.rawValue)
            XCTAssertEqual(captured["method"] as? String, method.rawValue.lowercased())
            XCTAssertEqual(captured["json"] as? [String: Int], ["a": 1], method.rawValue)
            XCTAssertNil(captured["allow_redirects"], "Other methods follow redirects by default")
        }
    }

    func testJSONBodyStringsAreKeptAsWrittenInPython() throws {
        let content = #"{"name":"nullable","flag":"true or false","path":"a/b","esc":"q\"uote \\ tab\t nl\n é 💅","null":null}"#
        let json = try XCTUnwrap(try pythonCall(code(body(content, .json)))?["json"] as? [String: Any], "The script should run")
        XCTAssertEqual(json["name"] as? String, "nullable")
        XCTAssertEqual(json["flag"] as? String, "true or false")
        XCTAssertEqual(json["path"] as? String, "a/b")
        XCTAssertEqual(json["esc"] as? String, "q\"uote \\ tab\t nl\n é 💅")
        XCTAssertTrue(json["null"] is NSNull)
    }

    func testJSONBodyKeepsKeyOrderAndNumberLiterals() throws {
        let content = #"{"z":1,"a":{"y":[1.5,-2,1e3,12345678901234567890],"b":true},"m":[],"e":{}}"#
        let text = String(decoding: try XCTUnwrap(try pythonOutput(code(body(content, .json))), "The script should run"), as: UTF8.self)
        XCTAssertTrue(text.contains(#""json": {"z": 1, "a": {"y": [1.5, -2, 1000.0, 12345678901234567890], "b": true}, "m": [], "e": {}}"#), text)
    }

    func testJSONBodyThatIsNotAnObjectStillBecomesALiteral() throws {
        for (content, expected) in [(#"[1,"x",null]"#, #""json": [1, "x", null]"#), (#""text""#, #""json": "text""#), ("false", #""json": false"#)] {
            let text = String(decoding: try XCTUnwrap(try pythonOutput(code(body(content, .json))), content), as: UTF8.self)
            XCTAssertTrue(text.contains(expected), "\(content): \(text)")
        }
    }

    func testTextBodiesReachPythonByteForByte() throws {
        let contents = [
            #"path C:\new\table \\ done"#, #"say """hi""" there"#, "ends with a quote\"", "\"starts with a quote", "crlf\r\nline\ttab\u{1}ctl \u{85}", "a=1&b=\\n2",
            "<x>\n  naïve 💅\n</x>\n"
        ]
        for type in ContentType.allCases where type != .none && type != .json && type != .formData && type != .file {
            for content in contents {
                let captured = try XCTUnwrap(try pythonCall(code(body(content, type))), "\(type.rawValue): \(content.debugDescription) should run")
                XCTAssertEqual(captured["data"] as? String, content, type.rawValue)
            }
        }
    }

    func testInvalidJSONBodyReachesPythonAsWritten() throws {
        let content = #"{"a": """x""" \n \"#
        let captured = try XCTUnwrap(try pythonCall(code(body(content, .json))), "The script should run")
        XCTAssertEqual(captured["data"] as? String, content, "Sent as written, not as a JSON string")
        XCTAssertNil(captured["json"])
        XCTAssertEqual((captured["headers"] as? [String: String])?["Content-Type"], "application/json")
        for unparsed in ["[1,]", #"{"n": {{count}}}"#] {
            let sent = try XCTUnwrap(try pythonCall(code(body(unparsed, .json))), unparsed)
            XCTAssertEqual(sent["data"] as? String, unparsed, unparsed)
        }
    }

    func testURLParamAndHeaderKeysAreEscaped() throws {
        let request = APIRequest(name: "k", url: #"https://h/a"b\c"#)
        request.queryParams = [KeyValuePair(key: #"q"uote\"#, value: "1")]
        request.headers = [KeyValuePair(key: #"X-"K"\"#, value: "2")]
        let captured = try XCTUnwrap(try pythonCall(code(request)), "The script should run")
        XCTAssertEqual(captured["url"] as? String, "https://h/a%22b%5Cc", "The URL as the app sends it; requests would encode these too")
        XCTAssertEqual(captured["params"] as? [String: String], [#"q"uote\"#: "1"])
        XCTAssertEqual(captured["headers"] as? [String: String], [#"X-"K"\"#: "2"])
    }
}
