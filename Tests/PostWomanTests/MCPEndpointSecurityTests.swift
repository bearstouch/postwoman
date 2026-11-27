import XCTest

@testable import PostWoman

/// A clock tests move by hand, for rate-limit windows and session expiry.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// Holds tool calls until released, and counts how many are waiting.
private final class CallGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private var entered = 0

    var waiting: Int { lock.withLock { entered } }

    func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                entered += 1
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for continuation in pending { continuation.resume() }
    }
}

/// The tool names and arguments an endpoint passed on.
private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, [String: JSONValue])] = []
    func add(_ name: String, _ arguments: [String: JSONValue]) { lock.withLock { entries.append((name, arguments)) } }
    var names: [String] { lock.withLock { entries.map(\.0) } }
    var last: [String: JSONValue]? { lock.withLock { entries.last?.1 } }
}

private func decode(_ response: MCPHTTPResponse) -> JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: response.body) }

final class MCPEndpointSecurityTests: XCTestCase {
    private let token = "pwm_security-token-0123456789abcdefghijklmnop"
    private let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#
    private let ping = #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#

    private func endpoint(
        loopbackOnly: Bool = true, clock: ManualClock? = nil, log: CallLog? = nil,
        tool: @escaping @Sendable (String, [String: JSONValue]) async -> Result<JSONValue, MCPToolError> = { name, _ in .success(.object(["tool": .string(name)])) }
    ) -> MCPEndpoint {
        var now: @Sendable () -> Date = { Date() }
        if let clock { now = { clock.now } }
        return MCPEndpoint(token: token, serverVersion: "9.9.9", loopbackOnly: loopbackOnly, now: now) { name, arguments in
            log?.add(name, arguments)
            return await tool(name, arguments)
        }
    }

    private func request(
        _ method: String = "POST", path: String = "/mcp", body: String = "", authorization: String? = nil, session: String? = nil, headers: [String: String] = [:],
        host: String? = "127.0.0.1:7778"
    ) -> MCPHTTPRequest {
        var all = ["Content-Type": "application/json", "Authorization": authorization ?? "Bearer \(token)"]
        if let host { all["Host"] = host }
        if let session { all["Mcp-Session-Id"] = session }
        all.merge(headers) { $1 }
        return MCPHTTPRequest(method: method, path: path, headers: all, body: Data(body.utf8))
    }

    private func open(_ endpoint: MCPEndpoint) async throws -> String {
        let response = await endpoint.handle(request(body: initialize))
        XCTAssertEqual(response.status, 200)
        return try XCTUnwrap(response.header("Mcp-Session-Id"))
    }

    private func call(_ endpoint: MCPEndpoint, session: String, tool: String, arguments: String = "{}", id: Int = 9) async -> MCPHTTPResponse {
        await endpoint.handle(request(body: #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#, session: session))
    }

    // MARK: Origin and Host

    func testBrowserOriginsAreRefusedBeforeAnythingElse() async {
        let endpoint = endpoint()
        for origin in [
            "https://evil.example", "null", "http://localhost.evil.example", "http://127.0.0.1.nip.io", "file://", "chrome-extension://abcdef",
            "http://0.0.0.0:3000", "http://[::ffff:127.0.0.1]", "ws://localhost", "http://192.168.1.2"
        ] {
            // Even with a wrong token and path: a browser page learns nothing else.
            let response = await endpoint.handle(request(path: "/elsewhere", body: initialize, authorization: "Bearer nope", headers: ["Origin": origin]))
            XCTAssertEqual(response.status, 403, origin)
        }
        // Refused origins are not authentication failures, so they never lock the real agent out.
        let after = await endpoint.handle(request(body: initialize))
        XCTAssertEqual(after.status, 200)
    }

    func testLoopbackOriginsAreAllowed() async {
        let endpoint = endpoint()
        for origin in ["http://localhost", "http://LOCALHOST:5173", "https://127.0.0.1:8443", "http://127.9.9.9", "http://[::1]:3000"] {
            let response = await endpoint.handle(request(body: initialize, headers: ["Origin": origin]))
            XCTAssertEqual(response.status, 200, origin)
        }
    }

    func testOriginIsCheckedEvenOnANetworkBind() async {
        let response = await endpoint(loopbackOnly: false).handle(request(body: initialize, headers: ["Origin": "https://evil.example"], host: "192.168.1.20:7778"))
        XCTAssertEqual(response.status, 403)
    }

    func testLoopbackHostsAreAccepted() {
        for host in ["localhost", "LocalHost:7778", "127.0.0.1", "127.0.0.1:7778", "127.255.0.9:1", "[::1]", "[::1]:7778", "::1", "[0:0:0:0:0:0:0:1]:80"] {
            XCTAssertTrue(MCPEndpoint.isLoopbackHost(host), host)
        }
    }

    func testRebindingAndNonLoopbackHostsAreRefused() {
        for host in [
            "", "evil.example", "evil.example:7778", "localhost.", "localhost.evil.example", "127.0.0.1.nip.io", "0.0.0.0", "128.0.0.1", "192.168.1.20:7778",
            "[::]", "[::2]", "[::ffff:127.0.0.1]", "[::1", "127.1", "2130706433", "0x7f.0.0.1", "0177.0.0.1", "[fe80::1%lo0]", "127.0.0.1:7778:1", "loca1host"
        ] {
            XCTAssertFalse(MCPEndpoint.isLoopbackHost(host), host)
        }
    }

    func testHostIsRequiredAndCheckedOnALoopbackBind() async {
        let endpoint = endpoint()
        let missing = await endpoint.handle(request(body: initialize, host: nil))
        XCTAssertEqual(missing.status, 400)
        let rebound = await endpoint.handle(request(body: initialize, host: "attacker.example"))
        XCTAssertEqual(rebound.status, 403)
        XCTAssertNil(rebound.header("Mcp-Session-Id"))
        let sessionCount = await endpoint.sessionCount
        XCTAssertEqual(sessionCount, 0)
        let network = await self.endpoint(loopbackOnly: false).handle(request(body: initialize, host: nil))
        XCTAssertEqual(network.status, 200, "A network bind has no Host check")
    }

    func testOriginHelperHandlesSchemesAndIPv6() {
        XCTAssertTrue(MCPEndpoint.isLoopbackOrigin("http://[::1]"))
        XCTAssertTrue(MCPEndpoint.isLoopbackOrigin("HTTPS://localhost"))
        XCTAssertFalse(MCPEndpoint.isLoopbackOrigin("localhost"))
        XCTAssertFalse(MCPEndpoint.isLoopbackOrigin("ftp://localhost"))
        XCTAssertFalse(MCPEndpoint.isLoopbackOrigin(""))
    }

    // MARK: Routing

    func testRoutingHappensBeforeAuthenticationWithoutLeakingAnything() async {
        let endpoint = endpoint()
        let other = await endpoint.handle(request(path: "/mcp/", authorization: "Bearer wrong"))
        XCTAssertEqual(other.status, 404)
        for method in ["GET", "PUT", "PATCH", "OPTIONS", "HEAD"] {
            let response = await endpoint.handle(request(method, authorization: "Bearer wrong"))
            XCTAssertEqual(response.status, 405, method)
            XCTAssertEqual(response.header("Allow"), "POST, DELETE")
            XCTAssertTrue(response.body.isEmpty)
        }
        // None of these count as failed authentications.
        let after = await endpoint.handle(request(body: initialize))
        XCTAssertEqual(after.status, 200)
    }

    func testContentTypeMustBeJSON() async {
        let endpoint = endpoint()
        for type in ["text/plain", "application/x-www-form-urlencoded", "multipart/form-data; boundary=x"] {
            let response = await endpoint.handle(request(body: initialize, headers: ["Content-Type": type]))
            XCTAssertEqual(response.status, 415, type)
        }
        let missing = await endpoint.handle(MCPHTTPRequest(method: "POST", path: "/mcp", headers: ["Host": "localhost", "Authorization": "Bearer \(token)"]))
        XCTAssertEqual(missing.status, 415)
        let charset = await endpoint.handle(request(body: initialize, headers: ["Content-Type": "Application/JSON; charset=utf-8"]))
        XCTAssertEqual(charset.status, 200)
    }

    // MARK: Bearer token

    func testOnlyTheExactBearerTokenIsAccepted() async {
        let endpoint = endpoint()
        let refused = [
            "Basic \(Data("agent:\(token)".utf8).base64EncodedString())", token, "Bearer", "Bearer ", "Bearer    ", "Bearer\(token)", "Token \(token)",
            "Bearer \(token)x", "Bearer \(token.dropLast())", "Bearer \(token.uppercased())", "Bearer \(token) \(token)"
        ]
        for value in refused {
            let fresh = self.endpoint()
            let response = await fresh.handle(request(body: initialize, authorization: value))
            XCTAssertEqual(response.status, 401, value)
            XCTAssertEqual(response.header("WWW-Authenticate"), #"Bearer realm="postwoman", error="invalid_token""#)
            XCTAssertEqual(decode(response)?["error"]?["code"], .number(-32001))
            XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains(token), "Refusals never echo the token")
        }
        let lowercaseScheme = await endpoint.handle(request(body: initialize, authorization: "bearer \(token)"))
        XCTAssertEqual(lowercaseScheme.status, 200, "The scheme is case-insensitive")
        let padded = await endpoint.handle(request(body: initialize, authorization: "Bearer   \(token)  "))
        XCTAssertEqual(padded.status, 200)
    }

    func testAMissingAuthorizationHeaderIs401() async {
        let response = await endpoint().handle(MCPHTTPRequest(method: "POST", path: "/mcp", headers: ["Host": "localhost", "Content-Type": "application/json"], body: Data(initialize.utf8)))
        XCTAssertEqual(response.status, 401)
    }

    func testTheTokenIsCheckedBeforeTheBodyIsParsed() async {
        let response = await endpoint().handle(request(body: "{not json", authorization: "Bearer wrong"))
        XCTAssertEqual(response.status, 401, "An unauthenticated client cannot probe the parser")
    }

    func testEveryRequestOfASessionNeedsTheToken() async throws {
        let log = CallLog()
        let endpoint = endpoint(log: log)
        let session = try await open(endpoint)
        let withoutToken = await endpoint.handle(
            MCPHTTPRequest(
                method: "POST", path: "/mcp", headers: ["Host": "localhost", "Content-Type": "application/json", "Mcp-Session-Id": session],
                body: Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"collection_delete","arguments":{"id":"x"}}}"#.utf8)))
        XCTAssertEqual(withoutToken.status, 401, "A session ID is not a credential")
        XCTAssertEqual(log.names, [])
        let deleteWithout = await endpoint.handle(request("DELETE", authorization: "Bearer wrong", session: session))
        XCTAssertEqual(deleteWithout.status, 401)
        let still = await endpoint.handle(request(body: ping, session: session))
        XCTAssertEqual(still.status, 200, "A refused DELETE leaves the session open")
    }

    func testConstantTimeCompare() {
        XCTAssertTrue(MCPEndpoint.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(MCPEndpoint.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 4])))
        XCTAssertFalse(MCPEndpoint.constantTimeEqual(Data([1, 2, 3]), Data([1, 2])))
        XCTAssertTrue(MCPEndpoint.constantTimeEqual(Data(), Data()))
        // Tokens are compared as SHA-256 digests, so the compared length never depends on the guess.
        XCTAssertEqual(MCPEndpoint.hash("a").count, 32)
        XCTAssertEqual(MCPEndpoint.hash(String(repeating: "a", count: 10_000)).count, 32)
        XCTAssertNotEqual(MCPEndpoint.hash("pwm_a"), MCPEndpoint.hash("pwm_b"))
    }

    func testBearerHelperExtractsTheToken() {
        func bearer(_ value: String?) -> String? {
            MCPEndpoint.bearer(MCPHTTPRequest(method: "POST", path: "/mcp", headers: value.map { ["Authorization": $0] } ?? [:]))
        }
        XCTAssertEqual(bearer("Bearer abc"), "abc")
        XCTAssertEqual(bearer("BEARER  abc "), "abc")
        XCTAssertNil(bearer(nil))
        XCTAssertNil(bearer("Bearer  "))
        XCTAssertNil(bearer("Bearerabc"))
    }

    // MARK: Rate limit

    func testFailuresAreLimitedPerWindowAndTheWindowSlides() async {
        let clock = ManualClock()
        let endpoint = endpoint(clock: clock)
        for _ in 0..<MCPEndpoint.maximumFailures {
            let refused = await endpoint.handle(request(body: initialize, authorization: "Bearer guess"))
            XCTAssertEqual(refused.status, 401)
        }
        let limited = await endpoint.handle(request(body: initialize))
        XCTAssertEqual(limited.status, 429, "Even the right token waits out the window")
        XCTAssertEqual(decode(limited)?["error"]?["code"], .number(-32002))
        XCTAssertEqual(limited.header("Retry-After"), "60")

        clock.advance(MCPEndpoint.failureWindow - 1)
        let stillLimited = await endpoint.handle(request(body: initialize))
        XCTAssertEqual(stillLimited.status, 429)
        clock.advance(1)
        let reset = await endpoint.handle(request(body: initialize))
        XCTAssertEqual(reset.status, 200, "Failures older than the window no longer count")
    }

    func testRefusalsWhileLimitedDoNotExtendTheLockout() async {
        let clock = ManualClock()
        let endpoint = endpoint(clock: clock)
        for _ in 0..<MCPEndpoint.maximumFailures { _ = await endpoint.handle(request(body: initialize, authorization: "Bearer guess")) }
        clock.advance(30)
        for _ in 0..<20 {
            let refused = await endpoint.handle(request(body: initialize, authorization: "Bearer guess"))
            XCTAssertEqual(refused.status, 429)
        }
        clock.advance(30)
        let reset = await endpoint.handle(request(body: initialize))
        XCTAssertEqual(reset.status, 200)
    }

    func testFailuresBelowTheLimitDoNotBlockAndSuccessesDoNotCount() async {
        let endpoint = endpoint()
        for _ in 0..<(MCPEndpoint.maximumFailures - 1) { _ = await endpoint.handle(request(body: initialize, authorization: "Bearer guess")) }
        for _ in 0..<20 {
            let response = await endpoint.handle(request(body: initialize))
            XCTAssertEqual(response.status, 200)
        }
    }

    func testFailuresSpreadOverTimeOnlyCountInsideTheWindow() async {
        let clock = ManualClock()
        let endpoint = endpoint(clock: clock)
        for _ in 0..<12 {
            let refused = await endpoint.handle(request(body: initialize, authorization: "Bearer guess"))
            XCTAssertEqual(refused.status, 401, "One failure every 15 s stays under five a minute")
            clock.advance(15)
        }
    }

    // MARK: Sessions

    func testRequestsOtherThanInitializeNeedAKnownSession() async throws {
        let endpoint = endpoint()
        let missing = await endpoint.handle(request(body: ping))
        XCTAssertEqual(missing.status, 400)
        let unknown = await endpoint.handle(request(body: ping, session: UUID().uuidString.lowercased()))
        XCTAssertEqual(unknown.status, 404)
        let session = try await open(endpoint)
        let uppercase = await endpoint.handle(request(body: ping, session: session.uppercased()))
        XCTAssertEqual(uppercase.status, 404, "Session IDs are matched exactly")
        let ok = await endpoint.handle(request(body: ping, session: session))
        XCTAssertEqual(decode(ok)?["result"], .object([:]))
    }

    func testEachInitializeOpensADistinctSession() async throws {
        let endpoint = endpoint()
        var ids = Set<String>()
        for _ in 0..<10 { ids.insert(try await open(endpoint)) }
        XCTAssertEqual(ids.count, 10)
        let sessionCount = await endpoint.sessionCount
        XCTAssertEqual(sessionCount, 10)
        XCTAssertTrue(ids.allSatisfy { UUID(uuidString: $0) != nil && $0 == $0.lowercased() })
    }

    func testSessionsAreBoundedAndTheLeastRecentlyUsedGoesFirst() async throws {
        let clock = ManualClock()
        let endpoint = endpoint(clock: clock)
        var sessions: [String] = []
        for _ in 0..<MCPEndpoint.maximumSessions {
            sessions.append(try await open(endpoint))
            clock.advance(1)
        }
        // Touch the oldest, so the second oldest is the least recently used.
        let touched = await endpoint.handle(request(body: ping, session: sessions[0]))
        XCTAssertEqual(touched.status, 200)
        clock.advance(1)
        _ = try await open(endpoint)
        let sessionCount = await endpoint.sessionCount
        XCTAssertEqual(sessionCount, MCPEndpoint.maximumSessions)
        let evicted = await endpoint.handle(request(body: ping, session: sessions[1]))
        XCTAssertEqual(evicted.status, 404)
        let kept = await endpoint.handle(request(body: ping, session: sessions[0]))
        XCTAssertEqual(kept.status, 200)
    }

    func testIdleSessionsExpireAndUseKeepsThemAlive() async throws {
        let clock = ManualClock()
        let endpoint = endpoint(clock: clock)
        let busy = try await open(endpoint)
        let idle = try await open(endpoint)
        clock.advance(MCPEndpoint.idleLifetime - 1)
        let used = await endpoint.handle(request(body: ping, session: busy))
        XCTAssertEqual(used.status, 200)
        clock.advance(1)
        let expired = await endpoint.handle(request(body: ping, session: idle))
        XCTAssertEqual(expired.status, 404, "Idle for the whole lifetime")
        clock.advance(MCPEndpoint.idleLifetime - 2)
        let alive = await endpoint.handle(request(body: ping, session: busy))
        XCTAssertEqual(alive.status, 200)
        let sessionCount = await endpoint.sessionCount
        XCTAssertEqual(sessionCount, 1)
    }

    func testDeleteEndsOnlyThatSession() async throws {
        let endpoint = endpoint()
        let first = try await open(endpoint)
        let second = try await open(endpoint)
        let deleted = await endpoint.handle(request("DELETE", session: first))
        XCTAssertEqual(deleted.status, 204)
        let again = await endpoint.handle(request("DELETE", session: first))
        XCTAssertEqual(again.status, 404)
        let noSession = await endpoint.handle(request("DELETE"))
        XCTAssertEqual(noSession.status, 400)
        let other = await endpoint.handle(request(body: ping, session: second))
        XCTAssertEqual(other.status, 200)
    }

    func testUnsupportedProtocolVersionHeaderIsRefused() async throws {
        let endpoint = endpoint()
        let session = try await open(endpoint)
        let bad = await endpoint.handle(request(body: ping, session: session, headers: ["MCP-Protocol-Version": "1999-01-01"]))
        XCTAssertEqual(bad.status, 400)
        for version in MCPEndpoint.supportedVersions {
            let good = await endpoint.handle(request(body: ping, session: session, headers: ["MCP-Protocol-Version": version]))
            XCTAssertEqual(good.status, 200, version)
        }
    }

    func testInitializeNegotiatesTheProtocolVersion() async throws {
        let endpoint = endpoint()
        for (requested, expected) in [("2025-03-26", "2025-03-26"), ("2099-01-01", MCPEndpoint.supportedVersions[0]), ("", MCPEndpoint.supportedVersions[0])] {
            let response = await endpoint.handle(request(body: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(requested)"}}"#))
            XCTAssertEqual(decode(response)?["result"]?["protocolVersion"], .string(expected), requested)
        }
        let noParams = await endpoint.handle(request(body: #"{"jsonrpc":"2.0","id":"a","method":"initialize"}"#))
        let result = decode(noParams)?["result"]
        XCTAssertEqual(result?["protocolVersion"], .string(MCPEndpoint.supportedVersions[0]))
        XCTAssertEqual(result?["serverInfo"]?["version"], .string("9.9.9"))
        XCTAssertEqual(result?["capabilities"]?["tools"]?["listChanged"], .bool(false))
        XCTAssertEqual(result?["instructions"], .string(MCPEndpoint.instructions))
        XCTAssertEqual(decode(noParams)?["id"], .string("a"))
    }

    func testANotificationInitializeOpensNoSession() async {
        let endpoint = endpoint()
        let response = await endpoint.handle(request(body: #"{"jsonrpc":"2.0","method":"initialize"}"#))
        XCTAssertEqual(response.status, 400)
        let sessionCount = await endpoint.sessionCount
        XCTAssertEqual(sessionCount, 0)
    }

    func testAStoppedEndpointOpensNoSessions() async throws {
        let endpoint = endpoint()
        let session = try await open(endpoint)
        await endpoint.closeAll()
        let old = await endpoint.handle(request(body: ping, session: session))
        XCTAssertEqual(old.status, 404)
        let fresh = await endpoint.handle(request(body: initialize))
        XCTAssertEqual(fresh.status, 503)
        let sessionCount = await endpoint.sessionCount
        XCTAssertEqual(sessionCount, 0)
    }

    func testANewTokenRefusesTheOldOneAndAcceptsTheNew() async throws {
        let endpoint = endpoint()
        _ = try await open(endpoint)
        let replacement = "pwm_replacement-0123456789abcdefghijklmnopqrstu"
        await endpoint.setToken(replacement)
        let sessionCount = await endpoint.sessionCount
        XCTAssertEqual(sessionCount, 0)
        let old = await endpoint.handle(request(body: initialize))
        XCTAssertEqual(old.status, 401)
        let new = await endpoint.handle(request(body: initialize, authorization: "Bearer \(replacement)"))
        XCTAssertEqual(new.status, 200)
    }

    // MARK: JSON-RPC

    func testMalformedJSONRPCMessages() async throws {
        let endpoint = endpoint()
        let session = try await open(endpoint)
        let cases: [(String, Int, Int?)] = [
            ("", 400, -32700), ("null", 400, -32600), ("42", 400, -32600), (#""text""#, 400, -32600), ("[]", 400, -32600),
            (#"{"id":1,"method":"ping"}"#, 400, -32600), (#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#, 400, -32600),
            (#"{"jsonrpc":2.0,"id":1,"method":"ping"}"#, 400, -32600), (#"{"jsonrpc":"2.0","id":true,"method":"ping"}"#, 400, -32600),
            (#"{"jsonrpc":"2.0","id":{"a":1},"method":"ping"}"#, 400, -32600), (#"{"jsonrpc":"2.0","id":[1],"method":"ping"}"#, 400, -32600),
            (#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#, 400, -32600), (#"{"jsonrpc":"2.0","id":1,"method":""}"#, 400, -32600),
            (#"{"jsonrpc":"2.0","id":1,"method":7}"#, 400, -32600), (#"{"jsonrpc":"2.0","id":1,"method":"\#(String(repeating: "m", count: 129))"}"#, 400, -32600),
            (#"{"jsonrpc":"2.0"}"#, 400, -32600)
        ]
        for (body, status, code) in cases {
            let response = await endpoint.handle(request(body: body, session: session))
            XCTAssertEqual(response.status, status, body)
            XCTAssertEqual(decode(response)?["error"]?["code"], code.map { .number(Double($0)) }, body)
        }
    }

    func testBatchesAreRefusedWithTheirOwnMessage() async throws {
        let endpoint = endpoint()
        let session = try await open(endpoint)
        let response = await endpoint.handle(request(body: "[\(ping),\(ping)]", session: session))
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(decode(response)?["error"]?["message"], .string(MCPRPCError.batch.message))
        XCTAssertEqual(decode(response)?["id"], .null)
    }

    func testDeepNestingIsRefusedBeforeDecoding() async throws {
        let endpoint = endpoint()
        let session = try await open(endpoint)
        let deep = #"{"jsonrpc":"2.0","id":1,"method":"ping","params":"# + String(repeating: "[", count: 70) + String(repeating: "]", count: 70) + "}"
        let refused = await endpoint.handle(request(body: deep, session: session))
        XCTAssertEqual(decode(refused)?["error"]?["code"], .number(-32700))
        let shallow = #"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"a":"# + String(repeating: "[", count: 10) + String(repeating: "]", count: 10) + "}}"
        let accepted = await endpoint.handle(request(body: shallow, session: session))
        XCTAssertEqual(accepted.status, 200)
    }

    func testAClientResponseWithoutMethodIsAccepted() async throws {
        let endpoint = endpoint()
        let session = try await open(endpoint)
        let response = await endpoint.handle(request(body: #"{"jsonrpc":"2.0","id":5,"result":{}}"#, session: session))
        XCTAssertEqual(response.status, 202)
        XCTAssertTrue(response.body.isEmpty)
    }

    func testNotificationsGetNoReplyButStillNeedASession() async throws {
        let log = CallLog()
        let endpoint = endpoint(log: log)
        let session = try await open(endpoint)
        for method in ["notifications/initialized", "notifications/cancelled", "unknown/notification", "tools/call"] {
            let response = await endpoint.handle(request(body: #"{"jsonrpc":"2.0","method":"\#(method)","params":{"name":"collection_list"}}"#, session: session))
            XCTAssertEqual(response.status, 202, method)
            XCTAssertTrue(response.body.isEmpty)
        }
        XCTAssertEqual(log.names, [], "A tools/call notification runs nothing")
        let withoutSession = await endpoint.handle(request(body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertEqual(withoutSession.status, 400)
    }

    func testUnknownMethodsAreMethodNotFoundWithTheirID() async throws {
        let endpoint = endpoint()
        let session = try await open(endpoint)
        let response = await endpoint.handle(request(body: #"{"jsonrpc":"2.0","id":"req-7","method":"resources/list"}"#, session: session))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(decode(response)?["error"]?["code"], .number(-32601))
        XCTAssertEqual(decode(response)?["id"], .string("req-7"))
    }

    func testToolsListMatchesTheCatalog() async throws {
        let endpoint = endpoint()
        let session = try await open(endpoint)
        let response = await endpoint.handle(request(body: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, session: session))
        XCTAssertEqual(decode(response)?["result"]?["tools"], .array(MCPTools.all.map(\.json)))
    }

    func testToolCallParamsAreValidatedBeforeTheToolRuns() async throws {
        let log = CallLog()
        let endpoint = endpoint(log: log)
        let session = try await open(endpoint)
        for params in [#"{}"#, #"{"name":7}"#, #"{"name":"nope"}"#, #"{"name":"collection_list","arguments":[]}"#, #"{"name":"collection_list","arguments":"x"}"#, #""x""#] {
            let response = await endpoint.handle(request(body: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":\#(params)}"#, session: session))
            XCTAssertEqual(decode(response)?["error"]?["code"], .number(-32602), params)
        }
        XCTAssertEqual(log.names, [])
        let nullArguments = await endpoint.handle(request(body: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"collection_list","arguments":null}}"#, session: session))
        XCTAssertEqual(decode(nullArguments)?["result"]?["isError"], .bool(false))
        XCTAssertEqual(log.last, [:])
    }

    func testToolArgumentsArePassedThrough() async throws {
        let log = CallLog()
        let endpoint = endpoint(log: log)
        let session = try await open(endpoint)
        _ = await call(endpoint, session: session, tool: "request_get", arguments: #"{"id":"abc","n":1.5,"flag":true,"list":[null]}"#)
        XCTAssertEqual(log.last, ["id": .string("abc"), "n": .number(1.5), "flag": .bool(true), "list": .array([.null])])
    }

    func testToolErrorsAreSuccessfulRPCResultsWithTheStableCode() async throws {
        let endpoint = endpoint { _, _ in .failure(.notFound("request", UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)) }
        let session = try await open(endpoint)
        let response = await call(endpoint, session: session, tool: "request_get", arguments: #"{"id":"x"}"#)
        XCTAssertEqual(response.status, 200)
        let result = decode(response)?["result"]
        XCTAssertNil(decode(response)?["error"])
        XCTAssertEqual(result?["isError"], .bool(true))
        XCTAssertEqual(result?["structuredContent"]?["error"]?["code"], .string("NOT_FOUND"))
        XCTAssertEqual(result?["structuredContent"]?["error"]?["retryable"], .bool(false))
        XCTAssertEqual(result?["structuredContent"]?["error"]?["details"]?["id"], .string("00000000-0000-0000-0000-000000000001"))
    }

    // MARK: Limits

    func testAtMostEightRequestsRunAtOnce() async throws {
        let gate = CallGate()
        let endpoint = endpoint { name, _ in
            if name == "request_execute" { await gate.pass() }
            return .success(.object(["tool": .string(name)]))
        }
        let session = try await open(endpoint)
        var running: [Task<MCPHTTPResponse, Never>] = []
        for index in 0..<MCPEndpoint.maximumWaitingCalls {
            let message = request(body: #"{"jsonrpc":"2.0","id":\#(index),"method":"tools/call","params":{"name":"request_execute","arguments":{}}}"#, session: session)
            running.append(Task { await endpoint.handle(message) })
        }
        let deadline = Date().addingTimeInterval(5)
        while gate.waiting < MCPEndpoint.maximumWaitingCalls, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(gate.waiting, MCPEndpoint.maximumWaitingCalls)

        let refused = await call(endpoint, session: session, tool: "request_execute")
        let error = decode(refused)?["result"]?["structuredContent"]?["error"]
        XCTAssertEqual(error?["code"], .string("LIMIT_EXCEEDED"))
        XCTAssertEqual(error?["retryable"], .bool(true))
        XCTAssertEqual(gate.waiting, MCPEndpoint.maximumWaitingCalls, "The refused call never ran")
        let other = await call(endpoint, session: session, tool: "collection_list")
        XCTAssertEqual(decode(other)?["result"]?["isError"], .bool(false), "Tools that don't wait are not limited")

        gate.open()
        for task in running {
            let response = await task.value
            XCTAssertEqual(decode(response)?["result"]?["isError"], .bool(false))
        }
        let afterwards = await call(endpoint, session: session, tool: "request_execute")
        XCTAssertEqual(decode(afterwards)?["result"]?["isError"], .bool(false), "Finished calls free their slots")
    }

    func testAResultThatFitsOnlyOnceKeepsItsTextAndDropsTheStructuredCopy() async throws {
        let blob = String(repeating: "a", count: 600_000)
        let endpoint = endpoint { _, _ in .success(.object(["blob": .string(blob)])) }
        let session = try await open(endpoint)
        let response = await call(endpoint, session: session, tool: "collection_list")
        XCTAssertLessThanOrEqual(response.body.count, MCPEndpoint.maximumResponse)
        let result = decode(response)?["result"]
        XCTAssertNil(result?["structuredContent"])
        XCTAssertEqual(result?["isError"], .bool(false))
        guard case .array(let content)? = result?["content"], case .string(let text)? = content.first?["text"] else { return XCTFail("No text") }
        XCTAssertTrue(text.contains(blob))
    }

    func testAResultLargerThanTheLimitIsALimitError() async throws {
        let endpoint = endpoint { _, _ in .success(.object(["blob": .string(String(repeating: "a", count: 1_100_000))])) }
        let session = try await open(endpoint)
        let response = await call(endpoint, session: session, tool: "history_get", arguments: #"{"id":"x"}"#)
        XCTAssertLessThan(response.body.count, 10_000)
        XCTAssertEqual(decode(response)?["result"]?["structuredContent"]?["error"]?["code"], .string("LIMIT_EXCEEDED"))
    }

    func testUntrustedToolsStartWithTheNoticeAndOthersDont() async throws {
        let endpoint = endpoint()
        let session = try await open(endpoint)
        for tool in MCPTools.all {
            let response = await call(endpoint, session: session, tool: tool.name)
            guard case .array(let content)? = decode(response)?["result"]?["content"] else {
                XCTFail(tool.name)
                continue
            }
            XCTAssertEqual(content.first?["text"] == .string(MCPTools.untrustedNotice), tool.untrusted, tool.name)
            XCTAssertEqual(content.count, tool.untrusted ? 2 : 1, tool.name)
        }
    }

    func testErrorBodiesAreJSONRPC() {
        let body = MCPEndpoint.errorBody(.methodNotFound, id: .number(3))
        XCTAssertEqual(
            try JSONDecoder().decode(JSONValue.self, from: body),
            .object(["jsonrpc": .string("2.0"), "id": .number(3), "error": .object(["code": .number(-32601), "message": .string("Method not found.")])]))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: MCPEndpoint.errorBody(.parse, id: nil))["id"], .null)
    }
}
