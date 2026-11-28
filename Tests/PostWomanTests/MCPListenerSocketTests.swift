import Darwin
import os
import SwiftData
import XCTest

@testable import PostWoman

/// A blocking loopback TCP client with a 5 s receive timeout.
private final class LoopbackClient: @unchecked Sendable {
    let fd: Int32

    init?(port: UInt16, address: String = "127.0.0.1") {
        let v6 = address.contains(":")
        fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let connected: Int32
        if v6 {
            var sin6 = sockaddr_in6()
            sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); sin6.sin6_family = sa_family_t(AF_INET6); sin6.sin6_port = port.bigEndian
            inet_pton(AF_INET6, address, &sin6.sin6_addr)
            connected = withUnsafePointer(to: &sin6) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        } else {
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); sin.sin_family = sa_family_t(AF_INET); sin.sin_port = port.bigEndian
            inet_pton(AF_INET, address, &sin.sin_addr)
            connected = withUnsafePointer(to: &sin) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
    }

    deinit { close(fd) }

    @discardableResult
    func send(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    @discardableResult
    func send(_ text: String) -> Bool { send(Data(text.utf8)) }

    private var pending = Data()

    /// One response (head plus Content-Length body), or nil on EOF or timeout.
    func response() -> (status: Int, headers: [String: String], body: String)? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            if let end = pending.firstRange(of: Data("\r\n\r\n".utf8)) {
                let lines = String(decoding: pending[pending.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                if pending.distance(from: end.upperBound, to: pending.endIndex) >= length {
                    let bodyEnd = pending.index(end.upperBound, offsetBy: length)
                    let body = String(decoding: pending[end.upperBound..<bodyEnd], as: UTF8.self)
                    let status = Int(lines[0].split(separator: " ").dropFirst().first ?? "") ?? 0
                    pending = Data(pending[bodyEnd...])
                    return (status, headers, body)
                }
            }
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { return nil }
            pending.append(contentsOf: buffer.prefix(count))
        }
    }

    /// True once the server has closed the connection (EOF or reset), false on a timeout.
    func isClosed() -> Bool {
        var byte: UInt8 = 0
        let count = read(fd, &byte, 1)
        return count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK)
    }
}

/// Waits up to `seconds` for `condition`, polling.
private func eventually(_ seconds: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        usleep(10_000)
    }
    return condition()
}

final class MCPListenerSocketTests: XCTestCase {
    private func echo() throws -> (MCPListener, UInt16) {
        let listener = MCPListener { request in
            .json(200, JSONValue.object(["method": .string(request.method), "path": .string(request.path), "bytes": .number(Double(request.body.count))]).data)
        }
        return (listener, try listener.start(address: "127.0.0.1", port: 0))
    }

    func testARequestIsAnsweredAndTheConnectionStaysOpen() throws {
        let (listener, port) = try echo()
        defer { listener.stop() }
        let client = try XCTUnwrap(LoopbackClient(port: port))
        client.send("POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\r\nabc")
        let first = try XCTUnwrap(client.response())
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(first.body, #"{"bytes":3,"method":"POST","path":"/mcp"}"#)
        XCTAssertEqual(first.headers["connection"], "keep-alive")
        XCTAssertEqual(first.headers["cache-control"], "no-store")
        client.send("GET /again HTTP/1.1\r\n\r\n")
        XCTAssertEqual(client.response()?.body, #"{"bytes":0,"method":"GET","path":"/again"}"#)
    }

    func testPipelinedRequestsAreAnsweredInOrder() throws {
        let (listener, port) = try echo()
        defer { listener.stop() }
        let client = try XCTUnwrap(LoopbackClient(port: port))
        client.send((1...5).map { "GET /\($0) HTTP/1.1\r\n\r\n" }.joined())
        let paths = (1...5).compactMap { _ in client.response()?.body }
        XCTAssertEqual(paths, (1...5).map { #"{"bytes":0,"method":"GET","path":"/\#($0)"}"# })
    }

    func testABodySentInPiecesIsAssembled() throws {
        let (listener, port) = try echo()
        defer { listener.stop() }
        let client = try XCTUnwrap(LoopbackClient(port: port))
        client.send("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\n01234")
        usleep(50_000)
        client.send("56789")
        XCTAssertEqual(client.response()?.body, #"{"bytes":10,"method":"POST","path":"/mcp"}"#)
    }

    func testConnectionCloseAndHTTP10EndTheConnection() throws {
        let (listener, port) = try echo()
        defer { listener.stop() }
        let closing = try XCTUnwrap(LoopbackClient(port: port))
        closing.send("GET / HTTP/1.1\r\nConnection: close\r\n\r\n")
        XCTAssertEqual(closing.response()?.headers["connection"], "close")
        XCTAssertTrue(closing.isClosed())
        let old = try XCTUnwrap(LoopbackClient(port: port))
        old.send("GET / HTTP/1.0\r\n\r\n")
        XCTAssertEqual(old.response()?.headers["connection"], "close")
        XCTAssertTrue(old.isClosed())
    }

    func testMalformedRequestsGetTheirStatusAndAreClosed() throws {
        let (listener, port) = try echo()
        defer { listener.stop() }
        let cases: [(String, Int)] = [
            ("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", 411), ("GET /mcp HTTP/2.0\r\n\r\n", 505), ("get /mcp HTTP/1.1\r\n\r\n", 400),
            ("POST /mcp HTTP/1.1\r\nContent-Length: +5\r\n\r\n", 400), ("POST /mcp HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n", 400),
            ("POST /mcp HTTP/1.1\r\nX: a\r\n folded\r\n\r\n", 400)
        ]
        for (raw, status) in cases {
            let client = try XCTUnwrap(LoopbackClient(port: port))
            client.send(raw)
            let response = client.response()
            XCTAssertEqual(response?.status, status, raw)
            XCTAssertEqual(response?.headers["connection"], "close", raw)
            XCTAssertTrue(client.isClosed(), raw)
        }
    }

    func testAnOversizedBodyIsRefusedWithoutReadingIt() throws {
        let called = OSAllocatedUnfairLock(initialState: false)
        let listener = MCPListener { _ in
            called.withLock { $0 = true }
            return .empty(200)
        }
        let port = try listener.start(address: "127.0.0.1", port: 0)
        defer { listener.stop() }
        let client = try XCTUnwrap(LoopbackClient(port: port))
        client.send("POST /mcp HTTP/1.1\r\nContent-Length: \(MCPHTTPRequestParser.maximumBody + 1)\r\n\r\n")
        XCTAssertEqual(client.response()?.status, 413)
        XCTAssertTrue(client.isClosed())
        XCTAssertFalse(called.withLock { $0 })
    }

    func testAHeaderFloodIsRefusedWith431() throws {
        let (listener, port) = try echo()
        defer { listener.stop() }
        let client = try XCTUnwrap(LoopbackClient(port: port))
        client.send("GET /mcp HTTP/1.1\r\nX: " + String(repeating: "a", count: MCPHTTPRequestParser.maximumHeaderBytes + 10))
        XCTAssertEqual(client.response()?.status, 431)
        XCTAssertTrue(client.isClosed())
    }

    func testTheSeventeenthConnectionGets503() throws {
        let (listener, port) = try echo()
        defer { listener.stop() }
        var held: [LoopbackClient] = []
        for _ in 0..<MCPListener.maximumConnections { held.append(try XCTUnwrap(LoopbackClient(port: port))) }
        for client in held {
            client.send("GET / HTTP/1.1\r\n\r\n")
            XCTAssertEqual(client.response()?.status, 200)
        }
        XCTAssertEqual(listener.connectionCount, MCPListener.maximumConnections)
        let extra = try XCTUnwrap(LoopbackClient(port: port))
        let refused = extra.response()
        XCTAssertEqual(refused?.status, 503)
        XCTAssertEqual(refused?.headers["retry-after"], "1")
        XCTAssertTrue(extra.isClosed())

        // Closing a held connection frees its slot.
        held.removeLast()
        XCTAssertTrue(eventually { listener.connectionCount < MCPListener.maximumConnections })
        let next = try XCTUnwrap(LoopbackClient(port: port))
        next.send("GET / HTTP/1.1\r\n\r\n")
        XCTAssertEqual(next.response()?.status, 200)
    }

    func testClosedConnectionsAreForgotten() throws {
        let (listener, port) = try echo()
        defer { listener.stop() }
        for _ in 0..<(MCPListener.maximumConnections * 2) {
            let client = try XCTUnwrap(LoopbackClient(port: port))
            client.send("GET / HTTP/1.1\r\nConnection: close\r\n\r\n")
            XCTAssertEqual(client.response()?.status, 200)
        }
        XCTAssertTrue(eventually { listener.connectionCount == 0 })
    }

    func testStopClosesConnectionsAndFreesThePort() throws {
        let (listener, port) = try echo()
        let client = try XCTUnwrap(LoopbackClient(port: port))
        client.send("GET / HTTP/1.1\r\n\r\n")
        XCTAssertNotNil(client.response())
        XCTAssertTrue(listener.isRunning)
        listener.stop()
        XCTAssertFalse(listener.isRunning)
        XCTAssertTrue(client.isClosed())
        XCTAssertNil(LoopbackClient(port: port), "Nothing listens after stop")
        let again = MCPListener { _ in .empty(204) }
        XCTAssertEqual(try again.start(address: "127.0.0.1", port: port), port, "The port can be bound again at once")
        again.stop()
        listener.stop()  // A second stop does nothing.
    }

    func testBindErrorsAreReported() throws {
        let (listener, port) = try echo()
        defer { listener.stop() }
        XCTAssertThrowsError(try MCPListener { _ in .empty(200) }.start(address: "127.0.0.1", port: port)) { XCTAssertEqual($0 as? MCPListenerError, .addressInUse) }
        XCTAssertThrowsError(try MCPListener { _ in .empty(200) }.start(address: "203.0.113.7", port: 0)) { XCTAssertEqual($0 as? MCPListenerError, .addressUnavailable) }
        for address in ["localhost", "", "fe80::1%lo0", "999.0.0.1"] {
            XCTAssertThrowsError(try MCPListener { _ in .empty(200) }.start(address: address, port: 0), address) {
                XCTAssertEqual($0 as? MCPListenerError, .invalidAddress)
            }
        }
    }

    func testErrorMessagesNameThePort() {
        XCTAssertTrue(MCPListenerError.addressInUse.message(port: 7778).contains("7778"))
        XCTAssertTrue(MCPListenerError.io(48).message(port: 1).contains("48"))
        for error in [MCPListenerError.invalidAddress, .addressUnavailable, .permissionDenied] { XCTAssertFalse(error.message(port: 1).isEmpty) }
    }

    func testIPv6LoopbackServes() throws {
        let listener = MCPListener { request in .plain(200, request.header("host") ?? "") }
        let port: UInt16
        do { port = try listener.start(address: "::1", port: 0) } catch { throw XCTSkip("IPv6 loopback unavailable") }
        defer { listener.stop() }
        XCTAssertNil(LoopbackClient(port: port), "An IPv6 bind does not accept IPv4 clients")
        let client = try XCTUnwrap(LoopbackClient(port: port, address: "::1"))
        client.send("GET / HTTP/1.1\r\nHost: [::1]\r\n\r\n")
        XCTAssertEqual(client.response()?.body, "[::1]\n")
    }

    /// The real endpoint behind the real listener: refusals over the wire.
    func testTheEndpointRefusesBadClientsOverTCP() throws {
        let token = RemoteAgentToken.generate()
        let endpoint = MCPEndpoint(token: token, serverVersion: "t", loopbackOnly: true) { _, _ in .success(.object([:])) }
        let listener = MCPListener { request in await endpoint.handle(request) }
        let port = try listener.start(address: "127.0.0.1", port: 0)
        defer { listener.stop() }
        let body = #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#
        func send(_ headers: String) -> Int? {
            guard let client = LoopbackClient(port: port) else { return nil }
            client.send("POST /mcp HTTP/1.1\r\n\(headers)Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
            return client.response()?.status
        }
        XCTAssertEqual(send("Host: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\n"), 200)
        XCTAssertEqual(send("Host: evil.example:\(port)\r\nAuthorization: Bearer \(token)\r\n"), 403)
        XCTAssertEqual(send("Host: localhost\r\nOrigin: https://evil.example\r\nAuthorization: Bearer \(token)\r\n"), 403)
        XCTAssertEqual(send("Host: localhost\r\nAuthorization: Bearer wrong\r\n"), 401)
        XCTAssertEqual(send("Authorization: Bearer \(token)\r\n"), 400)
    }
}

final class MCPServerLifecycleTests: XCTestCase {
    private func freePort() throws -> UInt16 {
        let probe = MCPListener { _ in .empty(204) }
        let port = try probe.start(address: "127.0.0.1", port: 0)
        probe.stop()
        return port
    }

    private func server() -> MCPServer { MCPServer(serverVersion: "t") { _, _ in .success(.object([:])) } }

    func testDisabledOrInvalidSettingsStartNothing() throws {
        let server = server()
        XCTAssertEqual(server.apply(RemoteAgentSettings(mcpEnabled: false), token: "pwm_x"), .stopped)
        guard case .failed(let reason) = server.apply(RemoteAgentSettings(mcpEnabled: true, bindAddress: "localhost"), token: "pwm_x") else {
            return XCTFail("A hostname is not a bind address")
        }
        XCTAssertFalse(reason.isEmpty)
        guard case .failed = server.apply(RemoteAgentSettings(mcpEnabled: true, port: 80), token: "pwm_x") else { return XCTFail("Port 80 is out of range") }
    }

    func testApplyingAgainMovesTheListenerAndAPortInUseFails() throws {
        let server = server()
        defer { server.stop() }
        let first = try freePort()
        XCTAssertEqual(server.apply(RemoteAgentSettings(mcpEnabled: true, port: first), token: "pwm_x"), .running(url: "http://127.0.0.1:\(first)/mcp"))
        XCTAssertNotNil(LoopbackClient(port: first))
        let second = try freePort()
        XCTAssertEqual(server.apply(RemoteAgentSettings(mcpEnabled: true, port: second), token: "pwm_x"), .running(url: "http://127.0.0.1:\(second)/mcp"))
        XCTAssertNil(LoopbackClient(port: first), "The old port is released")

        let blocker = MCPListener { _ in .empty(200) }
        let busy = try blocker.start(address: "127.0.0.1", port: 0)
        defer { blocker.stop() }
        guard case .failed(let reason) = server.apply(RemoteAgentSettings(mcpEnabled: true, port: busy), token: "pwm_x") else { return XCTFail("Expected a failure") }
        XCTAssertTrue(reason.contains("already in use"), reason)
        XCTAssertNil(LoopbackClient(port: second), "A failed apply still stops the previous listener")
        server.stop()
        XCTAssertEqual(server.apply(RemoteAgentSettings(mcpEnabled: false), token: "pwm_x"), .stopped)
    }

    func testANewTokenEndsSessionsWithoutRestarting() async throws {
        let server = server()
        defer { server.stop() }
        let port = try freePort()
        let old = RemoteAgentToken.generate(), new = RemoteAgentToken.generate()
        XCTAssertEqual(server.apply(RemoteAgentSettings(mcpEnabled: true, port: port), token: old), .running(url: "http://127.0.0.1:\(port)/mcp"))
        let body = #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#
        let status: @Sendable (String) -> Int? = { token in
            guard let client = LoopbackClient(port: port) else { return nil }
            client.send("POST /mcp HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
            return client.response()?.status
        }
        let before = await Task.detached { status(old) }.value
        XCTAssertEqual(before, 200)
        await server.setToken(new)
        let refused = await Task.detached { status(old) }.value
        XCTAssertEqual(refused, 401)
        let accepted = await Task.detached { status(new) }.value
        XCTAssertEqual(accepted, 200)
    }
}

@MainActor
final class RemoteAgentControllerTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "pw-controller-\(UUID().uuidString)")
        suite = "PostWomanTests.controller.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    private func controller() throws -> RemoteAgentController {
        let container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return RemoteAgentController(container: container, defaults: defaults, tokenURL: directory.appending(path: "token"))
    }

    func testStartsStoppedWithASavedPrivateToken() throws {
        let controller = try controller()
        controller.start()
        XCTAssertEqual(controller.status, .stopped, "The server is off by default")
        XCTAssertTrue(controller.token.hasPrefix(RemoteAgentToken.prefix))
        XCTAssertEqual(try String(contentsOf: directory.appending(path: "token"), encoding: .utf8), controller.token)
        XCTAssertEqual(try self.controller().token, controller.token, "The token survives a relaunch")
        XCTAssertEqual(controller.clientURL, "http://127.0.0.1:7778/mcp")
    }

    func testInvalidSettingsAreNeitherSavedNorApplied() throws {
        let controller = try controller()
        XCTAssertFalse(controller.apply(RemoteAgentSettings(mcpEnabled: true, bindAddress: "example.com")))
        XCTAssertFalse(controller.apply(RemoteAgentSettings(mcpEnabled: true, port: 1023)))
        XCTAssertEqual(controller.settings, RemoteAgentSettings())
        XCTAssertNil(defaults.data(forKey: RemoteAgentSettings.defaultsKey))
        XCTAssertEqual(controller.status, .stopped)
    }

    func testApplyingSavesStartsAndStops() throws {
        let probe = MCPListener { _ in .empty(204) }
        let port = try probe.start(address: "127.0.0.1", port: 0)
        probe.stop()
        let controller = try controller()
        let settings = RemoteAgentSettings(mcpEnabled: true, port: port)
        XCTAssertTrue(controller.apply(settings))
        defer { controller.stop() }
        XCTAssertEqual(controller.status, .running(url: "http://127.0.0.1:\(port)/mcp"))
        XCTAssertEqual(RemoteAgentSettings.load(from: defaults), settings)
        XCTAssertNotNil(LoopbackClient(port: port))
        controller.stop()
        XCTAssertEqual(controller.status, .stopped)
        XCTAssertNil(LoopbackClient(port: port))
    }

    func testRegeneratingReplacesTheSavedToken() throws {
        let controller = try controller()
        let old = controller.token
        controller.regenerateToken()
        XCTAssertNotEqual(controller.token, old)
        XCTAssertEqual(try String(contentsOf: directory.appending(path: "token"), encoding: .utf8), controller.token)
    }
}
