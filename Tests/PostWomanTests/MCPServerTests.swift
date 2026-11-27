import Darwin
import SwiftData
import XCTest

@testable import PostWoman

final class MCPHTTPParserTests: XCTestCase {
    func testParsesPipelinedRequestsAndBuffersPartialOnes() throws {
        var parser = MCPHTTPRequestParser()
        let first = "POST /mcp?x=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n{}"
        let requests = try parser.append(Data((first + "GET /mcp HTTP/1.1\r\nHo").utf8))
        XCTAssertEqual(requests.map(\.path), ["/mcp"])
        XCTAssertEqual(requests.first?.body, Data("{}".utf8))
        XCTAssertTrue(parser.hasPartialRequest)
        XCTAssertEqual(try parser.append(Data("st: localhost\r\n\r\n".utf8)).map(\.method), ["GET"])
    }

    func testRejectsSmugglingAndOversizedRequests() {
        func status(_ raw: String) -> Int? {
            var parser = MCPHTTPRequestParser()
            do {
                _ = try parser.append(Data(raw.utf8))
                return nil
            } catch {
                return error.status
            }
        }
        XCTAssertEqual(status("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"), 411)
        XCTAssertEqual(status("POST /mcp HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n"), 400)
        XCTAssertEqual(status("POST /mcp HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n"), 400)
        XCTAssertEqual(status("POST /mcp HTTP/1.1\r\nContent-Length: 2000000\r\n\r\n"), 413)
        XCTAssertEqual(status("GET /mcp HTTP/2.0\r\n\r\n"), 505)
    }
}

final class RemoteAgentSettingsTests: XCTestCase {
    func testValidatesAddressAndPort() {
        XCTAssertTrue(RemoteAgentSettings().isValid)
        XCTAssertFalse(RemoteAgentSettings().mcpEnabled)
        XCTAssertFalse(RemoteAgentSettings(bindAddress: "localhost").isValid)
        XCTAssertFalse(RemoteAgentSettings(port: 80).isValid)
        XCTAssertTrue(RemoteAgentSettings(bindAddress: "::1").isLoopback)
        XCTAssertFalse(RemoteAgentSettings(bindAddress: "0.0.0.0").isLoopback)
        XCTAssertEqual(RemoteAgentSettings(bindAddress: "::1", port: 9000).endpointURL, "http://[::1]:9000/mcp")
        XCTAssertEqual(RemoteAgentSettings(bindAddress: "0.0.0.0").clientURL, "http://127.0.0.1:7778/mcp")
        XCTAssertTrue(IPAddressLiteral("100.101.102.103")?.isTailnet == true)
    }

    func testSavesAndLoads() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PostWomanTests.\(UUID().uuidString)"))
        XCTAssertEqual(RemoteAgentSettings.load(from: defaults), RemoteAgentSettings())
        let settings = RemoteAgentSettings(mcpEnabled: true, bindAddress: "::1", port: 9001)
        settings.save(to: defaults)
        XCTAssertEqual(RemoteAgentSettings.load(from: defaults), settings)
    }

    func testTokenIsSavedPrivatelyAndRegenerated() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "pw-\(UUID().uuidString)").appending(path: "token")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let token = RemoteAgentToken.loadOrCreate(at: url)
        XCTAssertTrue(token.hasPrefix("pwm_"))
        XCTAssertEqual(RemoteAgentToken.loadOrCreate(at: url), token)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertNotEqual(RemoteAgentToken.regenerate(at: url), token)
    }

    func testCLIInstallCommandQuotesTheBundlePath() {
        XCTAssertEqual(
            MCPClientSetup.cliInstallCommand(bundlePath: "/Applications/PostWoman.app"), "'/Applications/PostWoman.app/Contents/Helpers/postwoman' cli install-link")
        XCTAssertEqual(MCPClientSetup.cliInstallCommand(bundlePath: "/Users/a/Bob's/PostWoman.app"), #"'/Users/a/Bob'\''s/PostWoman.app/Contents/Helpers/postwoman' cli install-link"#)
        XCTAssertNil(MCPClientSetup.cliInstallCommand(bundlePath: "/Users/a/.build/debug"))
    }

    func testSnippetsNeverHoldTheToken() {
        for setup in MCPClientSetup.allCases {
            let snippet = setup.snippet(url: "http://127.0.0.1:7778/mcp")
            XCTAssertTrue(snippet.contains("http://127.0.0.1:7778/mcp"))
            XCTAssertFalse(snippet.contains("pwm_"))
        }
    }
}

@MainActor
final class MCPToolHandlerTests: XCTestCase {
    private var container: ModelContainer!
    private var handler: MCPToolHandler!

    override func setUp() async throws {
        container = try ModelContainer(
            for: Folder.self, APIRequest.self, RequestHistory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        handler = MCPToolHandler(container: container)
    }

    override func tearDown() async throws {
        handler = nil
        container = nil
    }

    @discardableResult
    private func call(_ name: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        switch await handler.call(name, arguments) {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    private func failure(_ name: String, _ arguments: [String: JSONValue] = [:]) async -> MCPToolError? {
        if case .failure(let error) = await handler.call(name, arguments) { return error }
        return nil
    }

    private func id(_ value: JSONValue) -> JSONValue { value["id"] ?? .null }

    func testEveryToolHasAClosedSchemaAndAHandler() async {
        XCTAssertEqual(Set(MCPTools.all.map(\.name)).count, MCPTools.all.count)
        for tool in MCPTools.all {
            XCTAssertTrue(tool.name.allSatisfy { $0.isLowercase || $0 == "_" }, tool.name)
            XCTAssertEqual(tool.inputSchema["additionalProperties"], .bool(false), tool.name)
            for name in tool.required { XCTAssertNotNil(tool.properties[name], "\(tool.name).\(name)") }
            // Unknown arguments are refused before anything runs, which also proves the tool is dispatched.
            let error = await failure(tool.name, ["bogus": .bool(true)])
            XCTAssertEqual(error?.code, "INVALID_PARAMS", tool.name)
        }
        XCTAssertTrue(MCPTools.byName["request_execute"]!.openWorld)
        XCTAssertTrue(MCPTools.byName["collection_delete"]!.destructive)
        XCTAssertTrue(MCPTools.byName["history_list"]!.readOnly)
    }

    func testCreatesUpdatesAndDeletesCollections() async throws {
        let created = try await call("collection_create", ["name": .string("Users API")])
        XCTAssertEqual(created["name"], .string("Users API"))
        let updated = try await call("collection_update", ["id": id(created), "name": .string("Accounts")])
        XCTAssertEqual(updated["name"], .string("Accounts"))
        let list = try await call("collection_list")
        let single = try await call("collection_get", ["id": id(created), "includeRequests": .bool(false)])
        XCTAssertEqual(list["collections"], .array([single]))

        _ = try await call("request_create", ["collectionId": id(created), "name": .string("Me"), "url": .string("https://example.com/me")])
        let announced = expectation(forNotification: .remoteAgentWillDelete, object: nil) { note in
            (note.userInfo?["ids"] as? Set<UUID>)?.count == 2
        }
        let deleted = try await call("collection_delete", ["id": id(created)])
        XCTAssertEqual(deleted["deletedRequests"], .number(1))
        await fulfillment(of: [announced], timeout: 1)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<APIRequest>()), 0)
        let missing = await failure("collection_get", ["id": id(created)])
        XCTAssertEqual(missing?.code, "NOT_FOUND")
    }

    func testCreatesUpdatesAndDeletesRequests() async throws {
        // No collection yet: like New Request, a "Default Collection" is made.
        let request = try await call(
            "request_create",
            [
                "name": .string("Create user"), "url": .string("https://api.example.com/users"), "method": .string("post"),
                "headers": .array([.object(["key": .string("Accept"), "value": .string("application/json")])]),
                "body": .string(#"{"name":"Ada"}"#), "auth": .object(["type": .string("bearer"), "token": .string("secret")])
            ])
        XCTAssertEqual(request["method"], .string("POST"))
        XCTAssertEqual(request["bodyType"], .string("json"))
        XCTAssertEqual(request["auth"]?["tokenSet"], .bool(true))
        XCTAssertFalse(request.text.contains("secret"), "Credentials are write-only.")
        let folders = try container.mainContext.fetch(FetchDescriptor<Folder>())
        XCTAssertEqual(folders.map(\.name), ["Default Collection"])

        let other = try await call("collection_create", ["name": .string("Other")])
        let updated = try await call("request_update", ["id": id(request), "url": .string("https://api.example.com/v2/users"), "collectionId": id(other)])
        XCTAssertEqual(updated["url"], .string("https://api.example.com/v2/users"))
        XCTAssertEqual(updated["collectionId"], id(other))
        XCTAssertEqual(updated["name"], .string("Create user"), "Fields not passed are kept.")
        XCTAssertEqual(updated["auth"]?["tokenSet"], .bool(true))

        let listed = try await call("request_list", ["collectionId": id(other)])
        XCTAssertEqual(listed["requests"].flatMap { if case .array(let items) = $0 { items.count } else { nil } }, 1)

        let bad = await failure("request_update", ["id": id(request), "method": .string("TRACE")])
        XCTAssertEqual(bad?.code, "INVALID_PARAMS")
        _ = try await call("request_delete", ["id": id(request)])
        let gone = await failure("request_get", ["id": id(request)])
        XCTAssertEqual(gone?.code, "NOT_FOUND")
    }

    func testCreatesListsUpdatesAndDeletesHistory() async throws {
        let entry = try await call(
            "history_create",
            [
                "url": .string("https://api.example.com/ping"), "method": .string("GET"),
                "response": .object(["status": .number(200), "body": .string("pong"), "timeMs": .number(12)])
            ])
        XCTAssertEqual(entry["response"]?["status"], .number(200))
        XCTAssertEqual(entry["wasSuccessful"], .bool(true))
        _ = try await call("history_create", ["url": .string("https://api.example.com/down"), "errorMessage": .string("Offline")])

        let page = try await call("history_list", ["limit": .number(1)])
        XCTAssertEqual(page["total"], .number(2))
        XCTAssertEqual(page["nextOffset"], .number(1))

        let updated = try await call("history_update", ["id": id(entry), "name": .string("Ping")])
        XCTAssertEqual(updated["request"]?["name"], .string("Ping"))
        let truncated = try await call("history_get", ["id": id(entry), "maxBodyBytes": .number(2)])
        XCTAssertEqual(truncated["response"]?["body"], .string("po"))
        XCTAssertEqual(truncated["response"]?["bodyTruncated"], .bool(true))

        _ = try await call("history_delete", ["id": id(entry)])
        let cleared = try await call("history_clear")
        XCTAssertEqual(cleared["deleted"], .number(1))
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<RequestHistory>()), 0)
    }

    func testExecutesSavedAndAdHocRequestsAndRecordsHistory() async throws {
        let target = MCPListener { request in
            let body = JSONValue.object(["method": .string(request.method), "path": .string(request.path), "auth": .from(request.header("authorization"))])
            return .json(201, body.data, headers: [("X-Test", "yes")])
        }
        let port = try target.start(address: "127.0.0.1", port: 0)
        defer { target.stop() }

        let saved = try await call(
            "request_create",
            [
                "url": .string("http://127.0.0.1:\(port)/users"), "method": .string("POST"), "body": .string("{}"),
                "auth": .object(["type": .string("bearer"), "token": .string("abc")])
            ])
        let result = try await call("request_execute", ["id": id(saved)])
        XCTAssertEqual(result["response"]?["status"], .number(201))
        XCTAssertEqual(result["response"]?["statusText"], .string("Created"))
        let echoed = try JSONDecoder().decode(JSONValue.self, from: Data(try XCTUnwrap(result["response"]?["body"].flatMap { if case .string(let s) = $0 { s } else { nil } }).utf8))
        XCTAssertEqual(echoed["auth"], .string("Bearer abc"))
        XCTAssertEqual(echoed["path"], .string("/users"))

        let history = try await call("history_list", ["requestId": id(saved)])
        XCTAssertEqual(history["total"], .number(1))
        XCTAssertEqual(history["entries"].flatMap { if case .array(let items) = $0 { items.first?["id"] } else { nil } }, result["historyId"])

        let adHoc = try await call("request_execute", ["request": .object(["url": .string("http://127.0.0.1:\(port)/ping")]), "recordHistory": .bool(false)])
        XCTAssertEqual(adHoc["response"]?["status"], .number(201))
        XCTAssertNil(adHoc["historyId"])
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<RequestHistory>()), 1)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<APIRequest>()), 1, "Ad-hoc requests are never saved.")

        let failed = await failure("request_execute", ["request": .object(["url": .string("http://127.0.0.1:1/nothing")])])
        XCTAssertEqual(failed?.code, "REQUEST_FAILED")
        XCTAssertNotNil(failed?.details?["historyId"])
        let both = await failure("request_execute", ["id": id(saved), "request": .object(["url": .string("http://x")])])
        XCTAssertEqual(both?.code, "INVALID_PARAMS")
    }

    func testTruncatesOnCharacterBoundaries() {
        XCTAssertEqual(MCPToolHandler.truncate("héllo", to: 2).0, "h")
        XCTAssertEqual(MCPToolHandler.truncate("héllo", to: 3).0, "hé")
        XCTAssertEqual(MCPToolHandler.truncate("hi", to: 5).1, false)
    }
}

final class MCPEndpointTests: XCTestCase {
    private let token = "pwm_test-token-0123456789abcdefghijklmnopqrstuv"

    private func endpoint(loopbackOnly: Bool = true) -> MCPEndpoint {
        MCPEndpoint(token: token, serverVersion: "1.0", loopbackOnly: loopbackOnly) { name, _ in .success(.object(["tool": .string(name)])) }
    }

    private func post(_ body: String, token: String? = nil, session: String? = nil, extra: [String: String] = [:]) -> MCPHTTPRequest {
        var headers = ["Host": "127.0.0.1:7778", "Content-Type": "application/json", "Authorization": "Bearer \(token ?? self.token)"]
        if let session { headers["Mcp-Session-Id"] = session }
        headers.merge(extra) { $1 }
        return MCPHTTPRequest(method: "POST", path: "/mcp", headers: headers, body: Data(body.utf8))
    }

    private let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#

    private func open(_ endpoint: MCPEndpoint) async throws -> String {
        let response = await endpoint.handle(post(initialize))
        XCTAssertEqual(response.status, 200)
        return try XCTUnwrap(response.header("Mcp-Session-Id"))
    }

    func testInitializeListAndCallTools() async throws {
        let endpoint = endpoint()
        let first = await endpoint.handle(post(initialize))
        let result = try JSONDecoder().decode(JSONValue.self, from: first.body)
        XCTAssertEqual(result["result"]?["protocolVersion"], .string("2025-06-18"))
        XCTAssertEqual(result["result"]?["serverInfo"]?["name"], .string("postwoman"))
        let session = try XCTUnwrap(first.header("Mcp-Session-Id"))

        let list = await endpoint.handle(post(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, session: session))
        let tools = try JSONDecoder().decode(JSONValue.self, from: list.body)["result"]?["tools"]
        guard case .array(let items)? = tools else { return XCTFail("No tools") }
        XCTAssertEqual(items.count, MCPTools.all.count)

        let call = await endpoint.handle(post(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"history_list","arguments":{}}}"#, session: session))
        let content = try JSONDecoder().decode(JSONValue.self, from: call.body)["result"]
        XCTAssertEqual(content?["isError"], .bool(false))
        XCTAssertEqual(content?["structuredContent"]?["tool"], .string("history_list"))
        guard case .array(let parts)? = content?["content"] else { return XCTFail("No content") }
        XCTAssertEqual(parts.first?["text"], .string(MCPTools.untrustedNotice), "History is untrusted data.")

        let unknown = await endpoint.handle(post(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"nope"}}"#, session: session))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: unknown.body)["error"]?["code"], .number(-32602))

        let notification = await endpoint.handle(post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, session: session))
        XCTAssertEqual(notification.status, 202)
        let closed = await endpoint.handle(MCPHTTPRequest(method: "DELETE", path: "/mcp", headers: ["Host": "localhost", "Authorization": "Bearer \(token)", "Mcp-Session-Id": session]))
        XCTAssertEqual(closed.status, 204)
        let after = await endpoint.handle(post(#"{"jsonrpc":"2.0","id":5,"method":"ping"}"#, session: session))
        XCTAssertEqual(after.status, 404)
    }

    func testEveryRequestNeedsTheToken() async throws {
        let endpoint = endpoint()
        let session = try await open(endpoint)
        let wrong = await endpoint.handle(post(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#, token: "pwm_wrong", session: session))
        XCTAssertEqual(wrong.status, 401)
        XCTAssertNotNil(wrong.header("WWW-Authenticate"))
        XCTAssertFalse(String(decoding: wrong.body, as: UTF8.self).contains("pwm_wrong"))
        let missing = await endpoint.handle(MCPHTTPRequest(method: "POST", path: "/mcp", headers: ["Host": "localhost", "Content-Type": "application/json"], body: Data(initialize.utf8)))
        XCTAssertEqual(missing.status, 401)
        let noSession = await endpoint.handle(post(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#))
        XCTAssertEqual(noSession.status, 400)
    }

    func testRateLimitsFailedAuthentication() async {
        let endpoint = endpoint()
        for _ in 0..<MCPEndpoint.maximumFailures {
            let refused = await endpoint.handle(post(initialize, token: "pwm_guess"))
            XCTAssertEqual(refused.status, 401)
        }
        let limited = await endpoint.handle(post(initialize))
        XCTAssertEqual(limited.status, 429)
        XCTAssertEqual(limited.header("Retry-After"), "60")
    }

    func testRefusesBrowsersAndRebinding() async {
        let endpoint = endpoint()
        let origin = await endpoint.handle(post(initialize, extra: ["Origin": "https://evil.example"]))
        XCTAssertEqual(origin.status, 403)
        let localOrigin = await endpoint.handle(post(initialize, extra: ["Origin": "http://localhost:3000"]))
        XCTAssertEqual(localOrigin.status, 200)
        let host = await endpoint.handle(post(initialize, extra: ["Host": "evil.example:7778"]))
        XCTAssertEqual(host.status, 403)
        let network = await self.endpoint(loopbackOnly: false).handle(post(initialize, extra: ["Host": "192.168.1.20:7778"]))
        XCTAssertEqual(network.status, 200)
        let path = await endpoint.handle(MCPHTTPRequest(method: "POST", path: "/other", headers: ["Host": "localhost"]))
        XCTAssertEqual(path.status, 404)
        let get = await endpoint.handle(MCPHTTPRequest(method: "GET", path: "/mcp", headers: ["Host": "localhost"]))
        XCTAssertEqual(get.status, 405)
    }

    func testANewTokenEndsSessions() async throws {
        let endpoint = endpoint()
        let session = try await open(endpoint)
        await endpoint.setToken("pwm_new-token-0123456789abcdefghijklmnopqrstu")
        let old = await endpoint.handle(post(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#, session: session))
        XCTAssertEqual(old.status, 401)
        let reused = await endpoint.handle(post(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#, token: "pwm_new-token-0123456789abcdefghijklmnopqrstu", session: session))
        XCTAssertEqual(reused.status, 404)
    }

    func testRejectsBatchesAndBadJSON() async throws {
        let endpoint = endpoint()
        let batch = await endpoint.handle(post("[\(initialize)]"))
        XCTAssertEqual(batch.status, 400)
        let garbage = await endpoint.handle(post("{nope"))
        XCTAssertEqual(garbage.status, 400)
        let deep = await endpoint.handle(post(String(repeating: "[", count: 100) + String(repeating: "]", count: 100)))
        XCTAssertEqual(deep.status, 400)
        let wrongType = await endpoint.handle(MCPHTTPRequest(method: "POST", path: "/mcp", headers: ["Host": "localhost", "Content-Type": "text/plain"]))
        XCTAssertEqual(wrongType.status, 415)
    }
}

/// The whole stack over TCP: the server, the endpoint and the tools on an in-memory store.
@MainActor
final class MCPServerEndToEndTests: XCTestCase {
    func testAnAgentCreatesAndSendsARequestOverHTTP() async throws {
        let container = try ModelContainer(
            for: Folder.self, APIRequest.self, RequestHistory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let handler = MCPToolHandler(container: container)
        let token = RemoteAgentToken.generate()
        let server = MCPServer(serverVersion: "test") { name, arguments in await handler.call(name, arguments) }
        // Settings only allow ports 1024–65535, so find a free one first.
        let probe = MCPListener { _ in .empty(204) }
        let port = try probe.start(address: "127.0.0.1", port: 0)
        probe.stop()
        guard case .running(let url) = server.apply(RemoteAgentSettings(mcpEnabled: true, port: port), token: token) else {
            return XCTFail("The server did not start")
        }
        defer { server.stop() }
        XCTAssertTrue(url.hasPrefix("http://127.0.0.1:"))
        let endpoint = try XCTUnwrap(URL(string: url))

        func rpc(_ body: String, session: String?) async throws -> (JSONValue, HTTPURLResponse) {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
            request.httpBody = Data(body.utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            return (try JSONDecoder().decode(JSONValue.self, from: data), try XCTUnwrap(response as? HTTPURLResponse))
        }

        let (_, opened) = try await rpc(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#, session: nil)
        let session = try XCTUnwrap(opened.value(forHTTPHeaderField: "Mcp-Session-Id"))
        let (created, _) = try await rpc(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"collection_create","arguments":{"name":"From an agent"}}}"#, session: session)
        XCTAssertEqual(created["result"]?["structuredContent"]?["name"], .string("From an agent"))
        // The agent's own endpoint is a handy target: an unauthenticated GET gets 405.
        let (sent, _) = try await rpc(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"request_execute","arguments":{"request":{"url":"\#(url)"}}}}"#, session: session)
        XCTAssertEqual(sent["result"]?["structuredContent"]?["response"]?["status"], .number(405))
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<RequestHistory>()), 1)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Folder>()).map(\.name), ["From an agent"])
    }
}
