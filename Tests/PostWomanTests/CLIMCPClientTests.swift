import Foundation
import XCTest

@testable import PostWomanCLI

/// A scripted PostWoman MCP endpoint behind `CLIEnvironment.send`: it records every request and answers the handshake,
/// `tools/list` and `tools/call` like the app, unless `answer` replies first.
private final class ScriptedApp: @unchecked Sendable {
    typealias Reply = (status: Int, headers: [String: String], body: String)
    private let lock = NSLock()
    private var log: [URLRequest] = []
    /// `tools/call` results by tool name.
    var tools: [String: JSONValue] = [:]
    var toolList: [JSONValue] = []
    /// Endpoints that refuse the connection.
    var unreachable: Set<String> = []
    /// Answers before the defaults, by endpoint and JSON-RPC method (`DELETE` for closing the session).
    var answer: (@Sendable (_ url: String, _ method: String) -> Reply?)?

    var requests: [URLRequest] { lock.withLock { log } }
    /// Each request as "METHOD endpoint", in order.
    var trace: [String] { requests.map { "\(Self.method($0)) \($0.url?.absoluteString ?? "")" } }
    var toolCalls: [JSONValue] { requests.filter { Self.method($0) == "tools/call" }.compactMap { Self.message($0)?["params"] } }

    static func message(_ request: URLRequest) -> JSONValue? { request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } }
    static func method(_ request: URLRequest) -> String { request.httpMethod == "DELETE" ? "DELETE" : message(request)?["method"]?.string ?? "?" }
    static func result(_ value: JSONValue) -> String { JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(1), "result": value]).compact }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        lock.withLock { log.append(request) }
        let url = request.url?.absoluteString ?? ""
        if unreachable.contains(url) { throw URLError(.cannotConnectToHost) }
        let method = Self.method(request)
        let reply = answer?(url, method) ?? defaultReply(method, request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (Data(reply.body.utf8), response)
    }

    private func defaultReply(_ method: String, _ request: URLRequest) -> Reply {
        switch method {
        case "initialize": return (200, ["Mcp-Session-Id": "S1", "Content-Type": "application/json"], Self.result(.object(["protocolVersion": .string("2025-06-18")])))
        case "notifications/initialized": return (202, [:], "")
        case "tools/list": return (200, [:], Self.result(.object(["tools": .array(toolList)])))
        case "tools/call":
            let name = Self.message(request)?["params"]?["name"]?.string ?? ""
            return (200, [:], Self.result(tools[name] ?? structured(.object([:]))))
        case "DELETE": return (204, [:], "")
        default: return (400, [:], "")
        }
    }
}

/// A tool result as the app sends it: the JSON as text, plus structured content.
private func structured(_ value: JSONValue) -> JSONValue {
    .object(["content": .array([.object(["type": .string("text"), "text": .string(value.compact)])]), "structuredContent": value])
}

private func toolError(_ code: String?, _ message: String, details: JSONValue? = nil) -> JSONValue {
    var error: [String: JSONValue] = ["message": .string(message)]
    if let code { error["code"] = .string(code) }
    if let details { error["details"] = details }
    return .object([
        "isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string(message)])]), "structuredContent": .object(["error": .object(error)])
    ])
}

private let endpoint = "http://127.0.0.1:7778/mcp"

private func settingsPlist(port: Int) throws -> Data {
    let settings = Data(#"{"mcpEnabled":true,"bindAddress":"127.0.0.1","port":\#(port)}"#.utf8)
    return try PropertyListSerialization.data(fromPropertyList: ["remoteAgent.settings": settings], format: .binary, options: 0)
}

/// Runs the CLI against `app`; `token` is passed as `--agent-token` at the end of the line unless nil.
private func runApp(_ words: [String], _ app: ScriptedApp, token: String? = "pwm_t", files: FakeFiles = FakeFiles()) async -> (status: Int32, stdout: String, stderr: String) {
    let output = CLIOutputBox()
    let environment = makeCLIEnvironment(output: output, files: files, send: { try app.send($0) })
    let status = await CLI.run(words + (token.map { ["--agent-token", $0] } ?? []), environment: environment)
    return (status, output.stdout, output.stderr)
}

private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

final class CLIMCPClientTests: XCTestCase {
    // MARK: Session

    func testInitializesCallsTheToolAndClosesTheSession() async throws {
        let app = ScriptedApp()
        app.tools["collection_list"] = structured(.object(["collections": .array([.object(["id": .string("C1"), "name": .string("Work"), "requestCount": .number(2)])])]))
        let result = await runApp(["collection", "list"], app)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "ID  NAME  REQUESTS\nC1  Work  2")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(app.trace, ["initialize", "notifications/initialized", "tools/call", "DELETE"].map { "\($0) \(endpoint)" })

        let requests = app.requests
        let initialize = try XCTUnwrap(ScriptedApp.message(requests[0]))
        XCTAssertEqual(initialize["jsonrpc"], .string("2.0"))
        XCTAssertEqual(initialize["id"], .number(1))
        XCTAssertEqual(
            initialize["params"],
            .object([
                "protocolVersion": .string("2025-06-18"), "capabilities": .object([:]), "clientInfo": .object(["name": .string("postwoman-cli"), "version": .string(CLI.version)])
            ]))
        let initialized = try XCTUnwrap(ScriptedApp.message(requests[1]))
        XCTAssertNil(initialized["id"], "A notification has no id")
        XCTAssertNil(initialized["params"])
        XCTAssertEqual(ScriptedApp.message(requests[2])?["params"], .object(["name": .string("collection_list"), "arguments": .object([:])]))
        XCTAssertNil(requests[3].httpBody)
    }

    func testEveryRequestCarriesTheTokenAndTheSessionAfterInitialize() async {
        let app = ScriptedApp()
        _ = await runApp(["request", "get", "--id", "R"], app, token: "pwm_secret")
        let requests = app.requests
        XCTAssertEqual(requests.count, 4)
        for (index, request) in requests.enumerated() {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer pwm_secret", "\(index)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Session-Id"), index == 0 ? nil : "S1", "Only initialize goes without a session: \(index)")
        }
        for request in requests.dropLast() {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json, text/event-stream")
            XCTAssertEqual(request.value(forHTTPHeaderField: "MCP-Protocol-Version"), "2025-06-18")
            XCTAssertEqual(request.timeoutInterval, 120, "Longer than request_execute's 30 s wait")
        }
        XCTAssertEqual(requests.last?.httpMethod, "DELETE")
        XCTAssertEqual(requests.last?.timeoutInterval, 5)
    }

    func testInitializeWithoutASessionIDFails() async {
        for headers in [[:], ["Mcp-Session-Id": ""]] as [[String: String]] {
            let app = ScriptedApp()
            app.answer = { _, method in method == "initialize" ? (200, headers, ScriptedApp.result(.object([:]))) : nil }
            let result = await runApp(["collection", "list"], app)
            XCTAssertEqual(result.status, 7)
            XCTAssertEqual(result.stderr, "postwoman: PostWoman didn't open an MCP session at \(endpoint). (TRANSPORT)")
            XCTAssertEqual(app.trace, ["initialize \(endpoint)"], "Nothing is called without a session")
        }
    }

    func testAFailingInitializedNotificationIsIgnored() async {
        for status in [500, 404, 200] {
            let app = ScriptedApp()
            app.answer = { _, method in method == "notifications/initialized" ? (status, [:], "") : nil }
            let result = await runApp(["request", "get", "--id", "R"], app)
            XCTAssertEqual(result.status, 0, "\(status): \(result.stderr)")
            XCTAssertEqual(result.stdout, "{\n\n}")
        }
    }

    // MARK: Results

    func testToolArgumentsReachTheToolUnchanged() async {
        let app = ScriptedApp()
        _ = await runApp(["request", "create", "--collection", "C", "--name", "Ünïcode ✓", "-X", "post", "--url", "https://x.test/a", "-H", "A: 1", "--bearer", "s"], app)
        XCTAssertEqual(
            app.toolCalls,
            [
                .object([
                    "name": .string("request_create"),
                    "arguments": .object([
                        "collectionId": .string("C"), "name": .string("Ünïcode ✓"), "method": .string("POST"), "url": .string("https://x.test/a"),
                        "headers": .array([.object(["key": .string("A"), "value": .string("1")])]), "auth": .object(["type": .string("bearer"), "token": .string("s")])
                    ])
                ])
            ])
    }

    func testAdHocExecuteNestsTheRequestAndSavedExecuteDoesNot() async {
        let app = ScriptedApp()
        _ = await runApp(["request", "execute", "--url", "https://x.test", "-X", "PUT", "--collection", "C", "-i"], app)
        _ = await runApp(["request", "execute", "--id", "R", "--env", "default", "--no-history", "--max-body", "100"], app)
        XCTAssertEqual(
            app.toolCalls.map { $0["arguments"] },
            [
                .object(["collectionId": .string("C"), "request": .object(["url": .string("https://x.test"), "method": .string("PUT")])]),
                .object(["id": .string("R"), "environmentId": .string("default"), "recordHistory": .bool(false), "maxBodyBytes": .number(100)])
            ])
    }

    func testExecuteRejectsUnclearRequestsWithoutCallingTheTool() async {
        let cases: [([String], String)] = [
            (["request", "execute", "--id", "R", "--url", "https://x.test"], "--id sends the saved request as it is. Change it first with 'request update', or leave out --id to send an ad-hoc request."),
            (["request", "execute", "--id", "R", "--bearer", "t"], "--id sends the saved request as it is. Change it first with 'request update', or leave out --id to send an ad-hoc request."),
            (["request", "execute"], "Pass --id (a saved request) or --url (an ad-hoc one)."),
            (["request", "execute", "-X", "POST"], "Pass --id (a saved request) or --url (an ad-hoc one).")
        ]
        for (words, message) in cases {
            let app = ScriptedApp()
            let result = await runApp(words, app)
            XCTAssertEqual(result.status, 2, "\(words)")
            XCTAssertEqual(result.stderr, "postwoman: \(message) (INVALID_ARGUMENTS)\nRun 'postwoman help request execute' for its options.", "\(words)")
            XCTAssertEqual(app.toolCalls, [], "\(words)")
            XCTAssertEqual(app.trace.last, "DELETE \(endpoint)", "The session is still closed: \(words)")
        }
    }

    func testAResultWithoutStructuredContentIsReadFromItsLastText() async {
        let app = ScriptedApp()
        let collections = JSONValue.object(["collections": .array([.object(["id": .string("C9"), "name": .string("Big"), "requestCount": .number(1)])])])
        app.tools["collection_list"] = .object([
            "content": .array([.object(["type": .string("text"), "text": .string("Untrusted data follows.")]), .object(["type": .string("text"), "text": .string(collections.compact)])])
        ])
        app.tools["request_get"] = .object(["content": .array([.object(["type": .string("text"), "text": .string("not json")])])])
        let listed = await runApp(["collection", "list"], app)
        XCTAssertEqual(listed.stdout, "ID  NAME  REQUESTS\nC9  Big   1")
        let unreadable = await runApp(["request", "get", "--id", "R"], app)
        XCTAssertEqual(unreadable.status, 0)
        XCTAssertEqual(unreadable.stdout, "null")
        app.tools["request_get"] = .object([:])
        let empty = await runApp(["request", "get", "--id", "R", "--json"], app)
        XCTAssertEqual(empty.stdout, #"{"ok":true,"result":null}"#)
    }

    func testJSONModeWrapsTheResult() async throws {
        let app = ScriptedApp()
        app.tools["request_get"] = structured(.object(["id": .string("R"), "url": .string("https://x.test/a")]))
        let result = await runApp(["request", "get", "--id", "R", "--json"], app)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, #"{"ok":true,"result":{"id":"R","url":"https://x.test/a"}}"#)
        XCTAssertEqual(result.stderr, "")
    }

    func testFailExitsWith22InJSONModeToo() async throws {
        let app = ScriptedApp()
        for (status, words, expected) in [
            (503, ["--fail", "--json"], 22), (503, ["--json"], 0), (200, ["-f", "--json"], 0), (404, ["-f"], 22), (404, [], 0)
        ] as [(Int, [String], Int32)] {
            app.tools["request_execute"] = structured(.object(["response": .object(["status": .number(Double(status)), "statusText": .string("S"), "body": .string("b")])]))
            let result = await runApp(["request", "execute", "--url", "https://x.test"] + words, app)
            XCTAssertEqual(result.status, expected, "\(status) \(words)")
            if words.contains("--json") {
                XCTAssertEqual(try json(result.stdout)["result"]?["response"]?["status"], .number(Double(status)), "The response is printed as well")
            } else {
                XCTAssertEqual(result.stdout, "b")
            }
        }
    }

    // MARK: Failures

    func testToolErrorCodesPickTheExitStatus() async {
        let cases: [(String?, Int32, String)] = [
            ("INVALID_PARAMS", 2, "INVALID_PARAMS"), ("NOT_FOUND", 4, "NOT_FOUND"), ("REQUEST_FAILED", 5, "REQUEST_FAILED"), ("LIMIT_EXCEEDED", 6, "LIMIT_EXCEEDED"),
            ("CONFLICT", 1, "CONFLICT"), (nil, 1, "INTERNAL_ERROR")
        ]
        for (code, status, shown) in cases {
            let app = ScriptedApp()
            app.tools["request_get"] = toolError(code, "No request R.")
            let result = await runApp(["request", "get", "--id", "R"], app)
            XCTAssertEqual(result.status, status, shown)
            XCTAssertEqual(result.stdout, "")
            let hint = shown == "INVALID_PARAMS" ? "\nRun 'postwoman help request get' for its options." : ""
            XCTAssertEqual(result.stderr, "postwoman: No request R. (\(shown))" + hint)
            XCTAssertEqual(app.trace.last, "DELETE \(endpoint)", "A tool error still closes the session")
        }
    }

    func testToolErrorsInJSONModeKeepTheirDetails() async throws {
        let app = ScriptedApp()
        app.tools["request_execute"] = toolError("REQUEST_FAILED", "Could not connect.", details: .object(["historyId": .string("H9")]))
        let result = await runApp(["--json", "request", "execute", "--url", "http://127.0.0.1:1"], app)
        XCTAssertEqual(result.status, 5)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(
            result.stdout, #"{"error":{"code":"REQUEST_FAILED","details":{"historyId":"H9"},"exitStatus":5,"message":"Could not connect."},"ok":false}"#)

        let plain = await runApp(["request", "execute", "--url", "http://127.0.0.1:1"], app)
        XCTAssertEqual(plain.stderr, "postwoman: Could not connect. (REQUEST_FAILED)\nRecorded in History as H9.")
    }

    func testAToolErrorWithoutStructuredContentUsesItsText() async {
        let app = ScriptedApp()
        app.tools["request_get"] = .object(["isError": .bool(true), "content": .array([.object(["text": .string("Notice")]), .object(["text": .string("Boom.")])])])
        let result = await runApp(["request", "get", "--id", "R"], app)
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.stderr, "postwoman: Boom. (INTERNAL_ERROR)")
        app.tools["request_get"] = .object(["isError": .bool(true)])
        let bare = await runApp(["request", "get", "--id", "R"], app)
        XCTAssertEqual(bare.stderr, "postwoman: The tool failed. (INTERNAL_ERROR)")
    }

    func testJSONRPCErrorsBecomeFailures() async {
        let cases: [(String, Int32, String)] = [
            (#"{"code":-32602,"message":"Unknown tool: nope"}"#, 2, "postwoman: Unknown tool: nope (INVALID_PARAMS)\nRun 'postwoman help request get' for its options."),
            (#"{"code":-32601,"message":"Method not found"}"#, 1, "postwoman: Method not found (PROTOCOL)"),
            (#"{"code":-32603}"#, 1, "postwoman: MCP error. (PROTOCOL)"), (#"{}"#, 1, "postwoman: MCP error. (PROTOCOL)")
        ]
        for (error, status, stderr) in cases {
            let app = ScriptedApp()
            app.answer = { _, method in method == "tools/call" ? (200, [:], #"{"jsonrpc":"2.0","id":1,"error":\#(error)}"#) : nil }
            let result = await runApp(["request", "get", "--id", "R"], app)
            XCTAssertEqual(result.status, status, error)
            XCTAssertEqual(result.stderr, stderr, error)
        }
    }

    func testHTTPStatusesDuringACallBecomeFailures() async {
        let long = String(repeating: "x", count: 400)
        let cases: [(Int, String, Int32, String)] = [
            (401, "", 3, "postwoman: PostWoman refused the agent token. Copy it again from Settings → Remote Agent (it changes when regenerated). (AUTH_FAILED)"),
            (404, "", 7, "postwoman: PostWoman ended the MCP session (it restarted or the token changed). Run the command again. (TRANSPORT)"),
            (429, "", 6, "postwoman: Too many failed sign-ins. Wait a minute and try again. (RATE_LIMITED)"),
            (500, "  oops\n", 7, "postwoman: PostWoman answered HTTP 500: oops (TRANSPORT)"), (503, "", 7, "postwoman: PostWoman answered HTTP 503 (TRANSPORT)"),
            (202, "", 7, "postwoman: PostWoman answered HTTP 202 (TRANSPORT)"),
            (500, long, 7, "postwoman: PostWoman answered HTTP 500: \(String(repeating: "x", count: 300)) (TRANSPORT)")
        ]
        for (status, body, exit, stderr) in cases {
            let app = ScriptedApp()
            app.answer = { _, method in method == "tools/call" ? (status, [:], body) : nil }
            let result = await runApp(["request", "get", "--id", "R"], app)
            XCTAssertEqual(result.status, exit, "\(status)")
            XCTAssertEqual(result.stderr, stderr, "\(status)")
            XCTAssertEqual(app.trace.last, "DELETE \(endpoint)", "\(status)")
        }
    }

    func testANotFoundDuringInitializeIsNotASessionEnding() async {
        let app = ScriptedApp()
        app.answer = { _, method in method == "initialize" ? (404, [:], "Not Found") : nil }
        let result = await runApp(["collection", "list"], app)
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.stderr, "postwoman: PostWoman answered HTTP 404: Not Found (TRANSPORT)")
    }

    func testAnswersThatAreNotJSONAreTransportFailures() async {
        // The app answers JSON; a server-sent-event framed answer is not read.
        for body in ["not json", "", "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n", "{\"jsonrpc\":"] {
            let app = ScriptedApp()
            app.answer = { _, method in method == "tools/call" ? (200, ["Content-Type": "text/event-stream"], body) : nil }
            let result = await runApp(["request", "get", "--id", "R"], app)
            XCTAssertEqual(result.status, 7, body)
            XCTAssertEqual(result.stderr, "postwoman: PostWoman's answer wasn't JSON. (TRANSPORT)", body)
        }
    }

    func testAnUnreachableAppSaysHowToTurnItOn() async throws {
        let app = ScriptedApp()
        app.unreachable = [endpoint, "http://localhost:9/mcp"]
        let result = await runApp(["collection", "list"], app)
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(
            result.stderr,
            "postwoman: PostWoman's MCP server isn't answering at \(endpoint). Open PostWoman and turn on Settings → Remote Agent, then press Apply. (APP_NOT_REACHABLE)")
        let custom = await runApp(["collection", "list", "--server", "localhost:9", "--json"], app)
        XCTAssertEqual(custom.status, 7)
        XCTAssertEqual(try json(custom.stdout)["error"]?["code"], .string("APP_NOT_REACHABLE"))
        XCTAssertTrue(try XCTUnwrap(json(custom.stdout)["error"]?["message"]?.string).contains("http://localhost:9/mcp"))
    }

    func testNoTokenAnywhereFailsBeforeContactingTheApp() async {
        let app = ScriptedApp()
        let result = await runApp(["--json", "collection", "list"], app, token: nil)
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(
            result.stdout,
            #"{"error":{"code":"AUTH_REQUIRED","exitStatus":3,"message":"No agent token found. Turn on Settings → Remote Agent in PostWoman, or pass --agent-token (or set POSTWOMAN_TOKEN) with the token shown there."},"ok":false}"#
        )
        XCTAssertEqual(app.requests.count, 0)
    }

    // MARK: Candidates

    func testCandidatesAreTriedInOrderUntilOneAnswers() async throws {
        let files = FakeFiles()
        let apps = AppLocation.all(home: "/Users/test")
        files.files[apps[0].tokenPath] = Data("pwm_release".utf8)
        files.files[try XCTUnwrap(apps[0].preferencesPath)] = try settingsPlist(port: 9001)
        files.files[apps[1].tokenPath] = Data("pwm_dev\n".utf8)
        let app = ScriptedApp()
        app.answer = { url, _ in url.contains(":9001") ? (401, [:], "") : nil }
        app.tools["collection_list"] = structured(.object(["collections": .array([])]))
        let result = await runApp(["collection", "list"], app, token: nil, files: files)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stderr, "No collections.")
        XCTAssertEqual(
            app.trace,
            ["initialize http://127.0.0.1:9001/mcp", "initialize \(endpoint)", "notifications/initialized \(endpoint)", "tools/call \(endpoint)", "DELETE \(endpoint)"])
        XCTAssertEqual(app.requests.map { $0.value(forHTTPHeaderField: "Authorization") ?? "" }, ["Bearer pwm_release"] + Array(repeating: "Bearer pwm_dev", count: 4))
    }

    func testARefusedTokenIsReportedOverAnUnreachableApp() async throws {
        for refusedFirst in [true, false] {
            let files = FakeFiles()
            let apps = AppLocation.all(home: "/Users/test")
            files.files[apps[0].tokenPath] = Data("pwm_release".utf8)
            files.files[try XCTUnwrap(apps[0].preferencesPath)] = try settingsPlist(port: 9001)
            files.files[apps[1].tokenPath] = Data("pwm_dev".utf8)
            let app = ScriptedApp()
            app.unreachable = [refusedFirst ? endpoint : "http://127.0.0.1:9001/mcp"]
            app.answer = { url, _ in url != (refusedFirst ? endpoint : "http://127.0.0.1:9001/mcp") ? (401, [:], "") : nil }
            let result = await runApp(["collection", "list"], app, token: nil, files: files)
            XCTAssertEqual(result.status, 3, "refused first: \(refusedFirst)")
            XCTAssertTrue(result.stderr.hasSuffix("(AUTH_FAILED)"), result.stderr)
            XCTAssertEqual(app.requests.count, 2, "Both were tried")
        }
    }

    func testWhenNoneAnswerTheFirstFailureIsReported() async throws {
        let files = FakeFiles()
        let apps = AppLocation.all(home: "/Users/test")
        files.files[apps[0].tokenPath] = Data("pwm_release".utf8)
        files.files[try XCTUnwrap(apps[0].preferencesPath)] = try settingsPlist(port: 9001)
        files.files[apps[2].tokenPath] = Data("pwm_run".utf8)
        let app = ScriptedApp()
        app.unreachable = ["http://127.0.0.1:9001/mcp", endpoint]
        let result = await runApp(["collection", "list"], app, token: nil, files: files)
        XCTAssertEqual(result.status, 7)
        XCTAssertTrue(result.stderr.contains("isn't answering at http://127.0.0.1:9001/mcp."), result.stderr)

        let broken = ScriptedApp()
        broken.answer = { url, _ in url.contains(":9001") ? (500, [:], "boom") : nil }
        broken.unreachable = [endpoint]
        let first = await runApp(["collection", "list"], broken, token: nil, files: files)
        XCTAssertEqual(first.stderr, "postwoman: PostWoman answered HTTP 500: boom (TRANSPORT)", "The first failure, unless a later one is a refused token")
    }

    func testRateLimitingStopsTryingOtherCandidates() async throws {
        let files = FakeFiles()
        let apps = AppLocation.all(home: "/Users/test")
        files.files[apps[0].tokenPath] = Data("pwm_release".utf8)
        files.files[try XCTUnwrap(apps[0].preferencesPath)] = try settingsPlist(port: 9001)
        files.files[apps[1].tokenPath] = Data("pwm_dev".utf8)
        let app = ScriptedApp()
        app.answer = { url, _ in url.contains(":9001") ? (429, ["Retry-After": "60"], "") : nil }
        let result = await runApp(["collection", "list"], app, token: nil, files: files)
        XCTAssertEqual(result.status, 6)
        XCTAssertEqual(result.stderr, "postwoman: Too many failed sign-ins. Wait a minute and try again. (RATE_LIMITED)")
        XCTAssertEqual(app.trace, ["initialize http://127.0.0.1:9001/mcp"], "Another token try would only extend the lockout")
    }

    // MARK: tools and call

    func testToolsListsWhatTheAppOffers() async throws {
        let app = ScriptedApp()
        app.toolList = [
            .object(["name": .string("collection_list"), "description": .string("Lists collections. With counts.")]),
            .object(["name": .string("request_execute"), "description": .string("Sends a request.")])
        ]
        let table = await runApp(["tools"], app)
        XCTAssertEqual(table.status, 0)
        XCTAssertEqual(table.stdout, "TOOL             DESCRIPTION\ncollection_list  Lists collections.\nrequest_execute  Sends a request.")
        XCTAssertEqual(app.trace.filter { $0.hasPrefix("tools/") }, ["tools/list \(endpoint)"])
        let listed = await runApp(["tools", "list", "--json"], app)
        XCTAssertEqual(try json(listed.stdout), .object(["ok": .bool(true), "result": .object(["tools": .array(app.toolList)])]))
    }

    func testCallSendsRawJSONArguments() async throws {
        let app = ScriptedApp()
        app.tools["history_list"] = structured(.object(["entries": .array([])]))
        let result = await runApp(["call", "history_list", "--args", #"{"limit":2,"nested":{"a":[1,true,null,"é"]}}"#], app)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "{\n  \"entries\" : [\n\n  ]\n}", "call prints the result as JSON")
        XCTAssertEqual(
            app.toolCalls.last,
            .object([
                "name": .string("history_list"),
                "arguments": .object(["limit": .number(2), "nested": .object(["a": .array([.number(1), .bool(true), .null, .string("é")])])])
            ]))
        _ = await runApp(["call", "collection_list"], app)
        XCTAssertEqual(app.toolCalls.last?["arguments"], .object([:]), "No --args, empty arguments")
    }

    func testCallRejectsArgumentsThatAreNotAJSONObject() async {
        for args in ["[1]", "nope", "\"text\"", "3", "{\"a\":"] {
            let app = ScriptedApp()
            let result = await runApp(["call", "history_list", "--args", args], app)
            XCTAssertEqual(result.status, 2, args)
            XCTAssertEqual(result.stderr, "postwoman: --args must be a JSON object, such as '{\"limit\": 5}'. (INVALID_ARGUMENTS)\nRun 'postwoman help call' for its commands.", args)
            XCTAssertEqual(app.toolCalls, [], args)
        }
    }
}
