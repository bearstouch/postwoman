import XCTest
import os

@testable import PostWoman

/// Answers every request with `RecordingStubProtocol.reply` and records what arrived, body included
/// (URLSession moves `httpBody` into `httpBodyStream` before a protocol sees it).
private final class RecordingStubProtocol: URLProtocol {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        /// Sent at all: false leaves the request waiting for its response.
        var sendsResponse = true
        /// Fails with this code after the response and chunks (or instead of them).
        var failure: URLError.Code?
        /// How long after the chunks the failure comes. URLSession drops chunks a failure follows at once.
        var failureDelay: TimeInterval = 0
        /// Finishes loading; false keeps the body open until the task is cancelled.
        var finishes = true
    }

    struct Received: Sendable {
        let request: URLRequest
        let body: Data?
    }

    private struct State: Sendable {
        var reply = Reply()
        var received: [Received] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func serve(_ reply: Reply) { state.withLock { $0 = State(reply: reply) } }
    static var received: [Received] { state.withLock { $0.received } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let received = Received(request: request, body: Self.body(of: request))
        let reply = Self.state.withLock { state in
            state.received.append(received)
            return state.reply
        }
        if reply.sendsResponse {
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        }
        if let failure = reply.failure {
            if reply.failureDelay > 0 {
                nonisolated(unsafe) let stub = self
                DispatchQueue.global().asyncAfter(deadline: .now() + reply.failureDelay) { stub.client?.urlProtocol(stub, didFailWithError: URLError(failure)) }
            } else {
                client?.urlProtocol(self, didFailWithError: URLError(failure))
            }
        } else if reply.finishes, reply.sendsResponse {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@MainActor
private func makeClient() -> HTTPClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RecordingStubProtocol.self]
    return HTTPClient(session: URLSession(configuration: configuration))
}

private func makeRequest(_ url: String = "https://api.test/items", method: HTTPMethod = .get, _ configure: (inout RequestSnapshot) -> Void = { _ in }) -> RequestSnapshot {
    var request = RequestSnapshot(APIRequest(name: "Test", url: url, method: method))
    configure(&request)
    return request
}

/// What `HTTPClient` puts on the wire: URL, method, headers, authentication and body.
@MainActor
final class HTTPClientRequestTests: XCTestCase {
    /// Sends `request` to the stub and returns what the stub received.
    private func send(_ request: RequestSnapshot) async throws -> RecordingStubProtocol.Received {
        RecordingStubProtocol.serve(.init())
        _ = try await makeClient().execute(request: request)
        let received = RecordingStubProtocol.received
        XCTAssertEqual(received.count, 1, "One request reaches the server.")
        return try XCTUnwrap(received.first)
    }

    func testSendsEachMethodAsWritten() async throws {
        for method in HTTPMethod.allCases {
            let received = try await send(makeRequest(method: method))
            XCTAssertEqual(received.request.httpMethod, method.rawValue)
        }
    }

    func testAddsEnabledQueryParametersInOrder() async throws {
        let received = try await send(
            makeRequest {
                $0.queryParams = [
                    KeyValuePair(key: "page", value: "2"), KeyValuePair(key: "off", value: "x", isEnabled: false), KeyValuePair(key: "", value: "nameless"),
                    KeyValuePair(key: "sort", value: "name")
                ]
            })
        XCTAssertEqual(received.request.url?.absoluteString, "https://api.test/items?page=2&sort=name")
    }

    func testPercentEncodesQueryValues() async throws {
        let received = try await send(makeRequest { $0.queryParams = [KeyValuePair(key: "q", value: "a b&c=d/é"), KeyValuePair(key: "empty", value: "")] })
        let items = URLComponents(url: try XCTUnwrap(received.request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items, [URLQueryItem(name: "q", value: "a b&c=d/é"), URLQueryItem(name: "empty", value: "")], "Values come back exactly as typed.")
        XCTAssertTrue(received.request.url?.absoluteString.contains("%26c%3Dd") ?? false, "& and = in a value don't split it: \(received.request.url?.absoluteString ?? "")")
    }

    func testLeavesTheURLAloneWithoutEnabledParameters() async throws {
        let received = try await send(makeRequest("https://api.test/items?fixed=1#top") { $0.queryParams = [KeyValuePair(key: "off", value: "1", isEnabled: false)] })
        XCTAssertEqual(received.request.url?.absoluteString, "https://api.test/items?fixed=1#top")
    }

    func testSendsOnlyEnabledNamedHeaders() async throws {
        let received = try await send(
            makeRequest {
                $0.headers = [
                    KeyValuePair(key: "X-On", value: "1"), KeyValuePair(key: "X-Off", value: "2", isEnabled: false), KeyValuePair(key: "", value: "nameless"),
                    KeyValuePair(key: "X-Empty", value: "")
                ]
            })
        XCTAssertEqual(received.request.value(forHTTPHeaderField: "X-On"), "1")
        XCTAssertNil(received.request.value(forHTTPHeaderField: "X-Off"), "A disabled header isn't sent.")
        XCTAssertFalse(received.request.allHTTPHeaderFields?.values.contains("nameless") ?? false, "A header without a name isn't sent.")
    }

    func testLaterHeaderWithTheSameNameWins() async throws {
        let received = try await send(makeRequest { $0.headers = [KeyValuePair(key: "X-Dup", value: "first"), KeyValuePair(key: "x-dup", value: "second")] })
        XCTAssertEqual(received.request.value(forHTTPHeaderField: "X-Dup"), "second")
    }

    func testEverySendGoesToTheServerInsteadOfTheLocalCache() async throws {
        // A response with `Cache-Control: max-age` would otherwise be shown again, as if fresh, without a request.
        let received = try await send(makeRequest())
        XCTAssertEqual(received.request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testUsesAThirtySecondTimeout() async throws {
        let received = try await send(makeRequest())
        XCTAssertEqual(received.request.timeoutInterval, 30)
    }

    func testEachBodyTypeSendsItsContentType() async throws {
        let expected: [(ContentType, String)] = [
            (.json, "application/json"), (.xml, "application/xml"), (.text, "text/plain"), (.urlEncoded, "application/x-www-form-urlencoded"),
            (.formData, "multipart/form-data")
        ]
        for (type, mime) in expected {
            let received = try await send(
                makeRequest(method: .post) {
                    $0.bodyType = type
                    $0.bodyContent = "content é"
                })
            XCTAssertEqual(received.request.value(forHTTPHeaderField: "Content-Type"), mime, type.rawValue)
            XCTAssertEqual(received.body, Data("content é".utf8), "\(type.rawValue) bodies are sent as UTF-8.")
        }
    }

    func testAContentTypeHeaderOverridesTheBodyType() async throws {
        let received = try await send(
            makeRequest(method: .post) {
                $0.bodyType = .json
                $0.bodyContent = "{}"
                $0.headers = [KeyValuePair(key: "content-type", value: "application/vnd.api+json")]
            })
        XCTAssertEqual(received.request.value(forHTTPHeaderField: "Content-Type"), "application/vnd.api+json")
    }

    func testADisabledContentTypeHeaderFallsBackToTheBodyType() async throws {
        let received = try await send(
            makeRequest(method: .post) {
                $0.bodyType = .xml
                $0.bodyContent = "<a/>"
                $0.headers = [KeyValuePair(key: "Content-Type", value: "text/html", isEnabled: false)]
            })
        XCTAssertEqual(received.request.value(forHTTPHeaderField: "Content-Type"), "application/xml")
    }

    func testNoBodyWhenTheTypeIsNoneOrTheContentIsEmpty() async throws {
        let cases: [(ContentType, String)] = [(.none, #"{"ignored":true}"#), (.json, ""), (.text, "")]
        for (type, content) in cases {
            let received = try await send(
                makeRequest(method: .post) {
                    $0.bodyType = type
                    $0.bodyContent = content
                })
            XCTAssertTrue(received.body?.isEmpty ?? true, "\(type.rawValue) with \(content.count) characters sends no body.")
            XCTAssertNil(received.request.value(forHTTPHeaderField: "Content-Type"), "No body, no Content-Type (\(type.rawValue)).")
        }
    }

    func testSendsALargeBodyWhole() async throws {
        let content = String(repeating: "0123456789", count: 50_000)
        let received = try await send(
            makeRequest(method: .put) {
                $0.bodyType = .text
                $0.bodyContent = content
            })
        XCTAssertEqual(received.body?.count, 500_000)
        XCTAssertEqual(received.body, Data(content.utf8))
    }

    func testBearerAuthenticationSetsAuthorization() async throws {
        let received = try await send(
            makeRequest {
                $0.authenticationType = .bearer
                $0.authBearerToken = "tok-123"
            })
        XCTAssertEqual(received.request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
    }

    func testAuthenticationReplacesAnAuthorizationHeader() async throws {
        let received = try await send(
            makeRequest {
                $0.headers = [KeyValuePair(key: "Authorization", value: "Token manual")]
                $0.authenticationType = .basic
                $0.authBasicUsername = "ana"
                $0.authBasicPassword = "pa:ss"
            })
        XCTAssertEqual(received.request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("ana:pa:ss".utf8).base64EncodedString())
    }

    func testIncompleteAuthenticationLeavesTheAuthorizationHeader() async throws {
        let cases: [(AuthenticationType, String?, String?, String?)] = [
            (.bearer, nil, nil, nil), (.bearer, "", nil, nil), (.basic, nil, "ana", nil), (.basic, nil, nil, "secret"), (.oauth2, "tok", nil, nil), (.none, "tok", "a", "b")
        ]
        for (type, token, username, password) in cases {
            let received = try await send(
                makeRequest {
                    $0.headers = [KeyValuePair(key: "Authorization", value: "Token manual")]
                    $0.authenticationType = type
                    $0.authBearerToken = token
                    $0.authBasicUsername = username
                    $0.authBasicPassword = password
                })
            XCTAssertEqual(received.request.value(forHTTPHeaderField: "Authorization"), "Token manual", "\(type)")
        }
    }

    func testSendsVariablesAsWritten() async throws {
        let received = try await send(makeRequest("https://api.test/{{version}}/items") { $0.headers = [KeyValuePair(key: "X-Key", value: "{{key}}")] })
        XCTAssertEqual(received.request.url?.absoluteString, "https://api.test/%7B%7Bversion%7D%7D/items", "Unresolved names reach the server, encoded.")
        XCTAssertEqual(received.request.value(forHTTPHeaderField: "X-Key"), "{{key}}")
    }

    func testRejectsAnInvalidURLWithoutSending() async {
        RecordingStubProtocol.serve(.init())
        for url in ["http://[::1", "https://exa mple.com:port/"] {
            do {
                _ = try await makeClient().execute(request: makeRequest(url))
                XCTFail("\(url) was sent")
            } catch {
                XCTAssertEqual(error.localizedDescription, "Invalid URL", url)
                guard case .invalidURL? = error as? HTTPClientError else { return XCTFail("\(url): \(error)") }
            }
        }
        XCTAssertTrue(RecordingStubProtocol.received.isEmpty, "Nothing reaches the server.")
    }
}

/// What `HTTPClient` makes of the response: status, headers, body, size, timing, cookies and failures.
@MainActor
final class HTTPClientResponseTests: XCTestCase {
    private func receive(_ reply: RecordingStubProtocol.Reply, request: RequestSnapshot = makeRequest()) async throws -> HTTPResponse {
        RecordingStubProtocol.serve(reply)
        return try await makeClient().execute(request: request)
    }

    func testReturnsStatusHeadersBodyAndSize() async throws {
        let response = try await receive(
            .init(status: 201, headers: ["Content-Type": "application/json; charset=utf-8", "X-Request-Id": "abc"], chunks: [Data(#"{"id":"#.utf8), Data("7}".utf8)]))
        XCTAssertEqual(response.statusCode, 201)
        XCTAssertEqual(response.statusText, "Created")
        XCTAssertTrue(response.isSuccess)
        XCTAssertEqual(response.body, #"{"id":7}"#, "Chunks join into one body.")
        XCTAssertEqual(response.bodySize, 8)
        XCTAssertEqual(response.contentType, "application/json; charset=utf-8")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: response.headers.map { ($0.key, $0.value) })["X-Request-Id"], "abc")
        XCTAssertTrue(response.headers.contains { $0.key == "Content-Type" })
        XCTAssertNil(response.stream, "A JSON response isn't a stream.")
        XCTAssertTrue(response.cookies.isEmpty)
    }

    func testErrorStatusesAreResponsesNotErrors() async throws {
        for status in [301, 404, 418, 500, 503] {
            let response = try await receive(.init(status: status, chunks: [Data("nope".utf8)]))
            XCTAssertEqual(response.statusCode, status)
            XCTAssertFalse(response.isSuccess, "\(status)")
            XCTAssertEqual(response.body, "nope")
        }
    }

    func testAnEmptyBodyIsAnEmptyString() async throws {
        let response = try await receive(.init(status: 204))
        XCTAssertEqual(response.body, "")
        XCTAssertEqual(response.bodySize, 0)
        XCTAssertNil(response.contentType)
    }

    func testABodyThatIsNotUTF8HasNoTextButKeepsItsSize() async throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0xFE])
        let response = try await receive(.init(headers: ["Content-Type": "image/png"], chunks: [bytes]))
        XCTAssertNil(response.body, "Binary bodies aren't shown as garbled text.")
        XCTAssertEqual(response.bodySize, bytes.count)
    }

    func testACharacterSplitAcrossChunksDecodes() async throws {
        let bytes = Array("olá 👋".utf8)
        let response = try await receive(.init(chunks: [Data(bytes[..<3]), Data(bytes[3..<7]), Data(bytes[7...])]))
        XCTAssertEqual(response.body, "olá 👋")
        XCTAssertEqual(response.bodySize, bytes.count)
    }

    func testResponseTimeMatchesTheTimingTotal() async throws {
        let response = try await receive(.init(chunks: [Data("ok".utf8)]))
        XCTAssertGreaterThanOrEqual(response.responseTime, 0)
        if let timing = response.timing {
            XCTAssertEqual(response.responseTime, timing.total, "The total comes from URLSession's metrics when it has them.")
        }
    }

    func testReadsCookiesFromSetCookie() async throws {
        let response = try await receive(
            .init(headers: ["Set-Cookie": "session=abc; Path=/; Secure; HttpOnly; SameSite=Strict"]), request: makeRequest("https://api.test/v1/login"))
        let cookie = try XCTUnwrap(response.cookies.first)
        XCTAssertEqual(response.cookies.count, 1)
        XCTAssertEqual([cookie.name, cookie.value, cookie.domain, cookie.path], ["session", "abc", "api.test", "/"])
        XCTAssertTrue(cookie.isSecure)
        XCTAssertTrue(cookie.isHTTPOnly)
        XCTAssertEqual(cookie.sameSite?.lowercased(), "strict")
    }

    func testATransportFailureBeforeTheResponseThrows() async {
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .secureConnectionFailed] {
            RecordingStubProtocol.serve(.init(sendsResponse: false, failure: code))
            do {
                _ = try await makeClient().execute(request: makeRequest())
                XCTFail("\(code) returned a response")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, code, "The URLSession error reaches the caller as it is.")
            }
        }
    }

    func testAFailureAfterTheHeadersOfAPlainResponseThrows() async {
        RecordingStubProtocol.serve(.init(headers: ["Content-Type": "application/json"], chunks: [Data("{".utf8)], failure: .networkConnectionLost))
        do {
            _ = try await makeClient().execute(request: makeRequest())
            XCTFail("A cut-off JSON body was returned as complete")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
    }

    func testCancellingBeforeTheResponseThrows() async {
        RecordingStubProtocol.serve(.init(sendsResponse: false, finishes: false))
        let client = makeClient()
        let task = Task { try await client.execute(request: makeRequest()) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled request returned a response")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled, "\(error)")
        }
    }

    func testCancellingAPlainResponseWaitingForItsBodyThrows() async {
        RecordingStubProtocol.serve(.init(headers: ["Content-Type": "text/plain"], chunks: [Data("par".utf8)], finishes: false))
        let client = makeClient()
        let task = Task { try await client.execute(request: makeRequest()) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A partial plain body was returned")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled, "\(error)")
        }
    }
}

/// Streamed responses through `HTTPClient`: how they end and what they keep.
@MainActor
final class HTTPClientStreamEndTests: XCTestCase {
    private static func openAI(_ content: String) -> Data {
        Data("data: {\"choices\":[{\"delta\":{\"content\":\"\(content)\"}}]}\n\n".utf8)
    }

    func testALostConnectionKeepsTheEventsAndSaysWhy() async throws {
        RecordingStubProtocol.serve(.init(headers: ["Content-Type": "text/event-stream"], chunks: [Self.openAI("Hal"), Self.openAI("f")], failure: .networkConnectionLost, failureDelay: 0.05))
        let response = try await makeClient().execute(request: makeRequest())
        XCTAssertEqual(response.stream?.end, .failed(URLError(.networkConnectionLost).localizedDescription))
        XCTAssertEqual(response.stream?.text, "Half")
        XCTAssertEqual(response.stream?.events.count, 2)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.stream?.isLive, false)
    }

    func testTheLastEventWithoutABlankLineIsKept() async throws {
        RecordingStubProtocol.serve(.init(headers: ["Content-Type": "text/event-stream; charset=utf-8"], chunks: [Data("data: one\n\ndata: two".utf8)]))
        let response = try await makeClient().execute(request: makeRequest())
        XCTAssertEqual(response.stream?.events.map(\.data), ["one", "two"])
        XCTAssertEqual(response.stream?.end, .completed)
        XCTAssertNil(response.stream?.text, "Plain data has no LLM text.")
        XCTAssertNil(response.stream?.firstTextTime)
    }

    func testNDJSONStreamsAssembleOllamaText() async throws {
        let lines = [#"{"message":{"content":"Ol"},"done":false}"#, "", #"{"message":{"content":"á"},"done":true}"#]
        RecordingStubProtocol.serve(.init(headers: ["Content-Type": "application/x-ndjson"], chunks: [Data(lines.joined(separator: "\n").utf8)]))
        let response = try await makeClient().execute(request: makeRequest())
        XCTAssertEqual(response.stream?.kind, .ndjson)
        XCTAssertEqual(response.stream?.events.count, 2, "The blank line isn't an event.")
        XCTAssertEqual(response.stream?.text, "Olá")
        XCTAssertNotNil(response.stream?.firstTextTime)
    }

    func testAStreamDecodesInvalidUTF8Leniently() async throws {
        RecordingStubProtocol.serve(.init(headers: ["Content-Type": "text/event-stream"], chunks: [Data("data: a".utf8) + Data([0xFF]) + Data("b\n\n".utf8)]))
        let response = try await makeClient().execute(request: makeRequest())
        XCTAssertEqual(response.body, "data: a\u{FFFD}b\n\n", "A stream's body always has text, with U+FFFD for bad bytes.")
        XCTAssertEqual(response.stream?.events.map(\.data), ["a\u{FFFD}b"])
        XCTAssertEqual(response.bodySize, 11)
    }

    func testAnEmptyStreamCompletesWithNoEvents() async throws {
        var progress: [HTTPResponse] = []
        RecordingStubProtocol.serve(.init(headers: ["Content-Type": "text/event-stream"]))
        let response = try await makeClient().execute(request: makeRequest()) { progress.append($0) }
        XCTAssertEqual(response.stream?.events, [])
        XCTAssertEqual(response.stream?.end, .completed)
        XCTAssertNil(response.stream?.firstByteTime, "No body byte arrived.")
        XCTAssertEqual(progress.count, 1, "Progress still reports the headers.")
        XCTAssertEqual(progress.first?.stream?.end, .streaming)
    }

    func testStoppingRightAfterTheHeadersReturnsAStoppedStream() async throws {
        @MainActor final class TaskBox { var task: Task<HTTPResponse, Error>? }
        let box = TaskBox()
        RecordingStubProtocol.serve(.init(headers: ["Content-Type": "text/event-stream"], chunks: [Self.openAI("x")], finishes: false))
        let client = makeClient()
        box.task = Task { try await client.execute(request: makeRequest()) { _ in box.task?.cancel() } }
        let response = try await XCTUnwrap(box.task).value
        XCTAssertEqual(response.stream?.end, .stopped)
        XCTAssertEqual(response.statusCode, 200)
    }

    func testAFailureBeforeAStreamsHeadersStillThrows() async {
        RecordingStubProtocol.serve(.init(sendsResponse: false, failure: .timedOut))
        do {
            _ = try await makeClient().execute(request: makeRequest { $0.headers = [KeyValuePair(key: "Accept", value: "text/event-stream")] })
            XCTFail("A stream that never started returned a response")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }
}
