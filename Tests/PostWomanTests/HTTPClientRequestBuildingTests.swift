import Foundation
import os
import SwiftData
import XCTest

@testable import PostWoman

/// Captures each request URLSession would send and answers 200 with an empty body, so tests can see exactly what went out.
private final class CapturingURLProtocol: URLProtocol {
    static let sent = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var copy = request
        if copy.httpBody == nil, let stream = copy.httpBodyStream {
            copy.httpBody = Self.read(stream)
        }
        let captured = copy
        Self.sent.withLock { $0.append(captured) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
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
final class HTTPClientRequestBuildingTests: XCTestCase {
    private var client: HTTPClient!

    override func setUp() async throws {
        CapturingURLProtocol.sent.withLock { $0.removeAll() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapturingURLProtocol.self]
        client = HTTPClient(session: URLSession(configuration: configuration))
    }

    override func tearDown() async throws {
        client = nil
        CapturingURLProtocol.sent.withLock { $0.removeAll() }
    }

    /// Sends the request through the client and returns what reached the wire.
    private func send(_ request: some RequestFields) async throws -> URLRequest {
        _ = try await client.execute(request: request)
        let sent = CapturingURLProtocol.sent.withLock { $0 }
        XCTAssertEqual(sent.count, 1)
        return try XCTUnwrap(sent.last)
    }

    func testEveryMethodIsSentAsItsRawValue() async throws {
        for method in HTTPMethod.allCases {
            CapturingURLProtocol.sent.withLock { $0.removeAll() }
            let sent = try await send(APIRequest(name: "m", url: "https://api.example.com/items", method: method))
            XCTAssertEqual(sent.httpMethod, method.rawValue, method.rawValue)
        }
    }

    func testEnabledQueryParamsArePercentEncodedQueryItems() async throws {
        let request = APIRequest(name: "q", url: "https://api.example.com/search")
        request.queryParams = [
            KeyValuePair(key: "q", value: "a&b=c d"), KeyValuePair(key: "lang", value: "é"), KeyValuePair(key: "off", value: "1", isEnabled: false),
            KeyValuePair(key: "", value: "keyless")
        ]
        let sent = try await send(request)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.example.com/search?q=a%26b%3Dc%20d&lang=%C3%A9")
        let items = URLComponents(url: try XCTUnwrap(sent.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items, [URLQueryItem(name: "q", value: "a&b=c d"), URLQueryItem(name: "lang", value: "é")], "Values survive a round trip")
    }

    func testURLIsSentUnchangedWithoutEnabledParams() async throws {
        let request = APIRequest(name: "q", url: "https://api.example.com/search?fixed=1")
        request.queryParams = [KeyValuePair(key: "off", value: "1", isEnabled: false)]
        let sent = try await send(request)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.example.com/search?fixed=1")
    }

    func testParamsAreAppendedToTheURLsOwnQuery() async throws {
        let request = APIRequest(name: "q", url: "https://api.test/items?page=1")
        request.queryParams = [KeyValuePair(key: "limit", value: "10")]
        let sent = try await send(request)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.test/items?page=1&limit=10")
    }

    func testTheURLsOwnQueryIsKeptAsWritten() async throws {
        let request = APIRequest(name: "q", url: "https://api.test/items?tag=a+b&x=%2F&flag")
        request.queryParams = [KeyValuePair(key: "limit", value: "10")]
        let sent = try await send(request)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.test/items?tag=a+b&x=%2F&flag&limit=10")
    }

    func testParamsGoBeforeTheFragmentAndAfterAnEmptyQuery() async throws {
        let request = APIRequest(name: "q", url: "https://api.test/items#top")
        request.queryParams = [KeyValuePair(key: "limit", value: "10")]
        let fragment = try await send(request)
        XCTAssertEqual(fragment.url?.absoluteString, "https://api.test/items?limit=10#top")

        CapturingURLProtocol.sent.withLock { $0.removeAll() }
        let empty = APIRequest(name: "q", url: "https://api.test/items?")
        empty.queryParams = [KeyValuePair(key: "limit", value: "10")]
        let emptyQuery = try await send(empty)
        XCTAssertEqual(emptyQuery.url?.absoluteString, "https://api.test/items?limit=10")
    }

    /// What `request_execute` sends for an ad-hoc request: agents and the CLI share the app's send path.
    private func executeThroughMCP(url: String, params: [(String, String)]) async throws -> URLRequest {
        let container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let handler = MCPToolHandler(container: container, client: client)
        let pairs = JSONValue.array(params.map { .object(["key": .string($0.0), "value": .string($0.1)]) })
        let result = await handler.call("request_execute", ["request": .object(["url": .string(url), "queryParams": pairs]), "recordHistory": .bool(false)])
        if case .failure(let error) = result { XCTFail("request_execute failed: \(error.code) \(error.message)") }
        return try XCTUnwrap(CapturingURLProtocol.sent.withLock { $0.last })
    }

    func testRequestExecuteAppendsParamsToTheURLsOwnQuery() async throws {
        let sent = try await executeThroughMCP(url: "https://api.test/items?page=1", params: [("limit", "10")])
        XCTAssertEqual(sent.url?.absoluteString, "https://api.test/items?page=1&limit=10")
    }

    func testOnlyEnabledHeadersWithKeysAreSent() async throws {
        let request = APIRequest(name: "h", url: "https://api.example.com")
        request.headers = [
            KeyValuePair(key: "Accept", value: "application/json"), KeyValuePair(key: "X-Off", value: "1", isEnabled: false),
            KeyValuePair(key: "", value: "keyless"), KeyValuePair(key: "X-Unicode", value: "café")
        ]
        let sent = try await send(request)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(sent.value(forHTTPHeaderField: "X-Off"))
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-Unicode"), "café")
    }

    func testAuthenticationOverridesAHandWrittenAuthorizationHeader() async throws {
        let request = APIRequest(name: "a", url: "https://api.example.com")
        request.headers = [KeyValuePair(key: "Authorization", value: "Token old")]
        request.authenticationType = .bearer
        request.authBearerToken = "new"
        let sent = try await send(request)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer new")
    }

    func testHandWrittenAuthorizationHeaderStaysWhenAuthHasNoCredentials() async throws {
        let request = APIRequest(name: "a", url: "https://api.example.com")
        request.headers = [KeyValuePair(key: "Authorization", value: "Token kept")]
        request.authenticationType = .bearer
        request.authBearerToken = ""
        let sent = try await send(request)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Token kept")
    }

    func testBasicAuthIsSentEncoded() async throws {
        let request = APIRequest(name: "a", url: "https://api.example.com")
        request.authenticationType = .basic
        request.authBasicUsername = "user"
        request.authBasicPassword = "pass"
        let sent = try await send(request)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Basic dXNlcjpwYXNz")
    }

    func testEachBodyTypeSendsItsBytesAndDefaultContentType() async throws {
        for type in ContentType.allCases where type != .none {
            CapturingURLProtocol.sent.withLock { $0.removeAll() }
            let request = APIRequest(name: "b", url: "https://api.example.com", method: .post)
            request.bodyType = type
            request.bodyContent = "naïve \"body\"\nline 2"
            let sent = try await send(request)
            XCTAssertEqual(sent.httpBody, Data("naïve \"body\"\nline 2".utf8), type.rawValue)
            XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), type.mimeType, type.rawValue)
        }
    }

    func testExplicitContentTypeHeaderWinsInAnyCase() async throws {
        let request = APIRequest(name: "b", url: "https://api.example.com", method: .post)
        request.headers = [KeyValuePair(key: "content-type", value: "application/vnd.api+json")]
        request.bodyType = .json
        request.bodyContent = "{}"
        let sent = try await send(request)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/vnd.api+json")
    }

    func testDisabledContentTypeHeaderFallsBackToTheBodyDefault() async throws {
        let request = APIRequest(name: "b", url: "https://api.example.com", method: .post)
        request.headers = [KeyValuePair(key: "Content-Type", value: "text/csv", isEnabled: false)]
        request.bodyType = .xml
        request.bodyContent = "<a/>"
        let sent = try await send(request)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/xml")
    }

    func testNoBodyOrContentTypeForNoneTypeOrEmptyContent() async throws {
        for (type, content) in [(ContentType.none, "ignored"), (.json, "")] {
            CapturingURLProtocol.sent.withLock { $0.removeAll() }
            let request = APIRequest(name: "b", url: "https://api.example.com", method: .post)
            request.bodyType = type
            request.bodyContent = content
            let sent = try await send(request)
            XCTAssertTrue(sent.httpBody?.isEmpty ?? true, type.rawValue)
            XCTAssertNil(sent.value(forHTTPHeaderField: "Content-Type"), type.rawValue)
        }
    }

    func testUnparseableURLThrowsInvalidURLAndSendsNothing() async {
        let request = APIRequest(name: "bad", url: "http://exa mple.com/a b")
        do {
            _ = try await client.execute(request: request)
            XCTFail("Expected invalidURL")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Invalid URL")
        }
        XCTAssertTrue(CapturingURLProtocol.sent.withLock { $0.isEmpty })
    }

    func testAResolvedSnapshotIsSentWithItsValues() async throws {
        let request = APIRequest(name: "v", url: "{{host}}/users", method: .post)
        request.headers = [KeyValuePair(key: "X-User", value: "{{user}}")]
        request.queryParams = [KeyValuePair(key: "id", value: "{{user}}")]
        request.bodyType = .json
        request.bodyContent = #"{"user":"{{user}}"}"#
        request.authenticationType = .bearer
        request.authBearerToken = "{{token}}"
        let resolver = VariableResolver(
            defaults: [Variable(key: "host", value: "https://api.example.com"), Variable(key: "user", value: "ada")],
            selected: [Variable(key: "token", value: "s3cret", isSecret: true)])
        let sent = try await send(RequestSnapshot(request).resolved(with: resolver))
        XCTAssertEqual(sent.url?.absoluteString, "https://api.example.com/users?id=ada")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-User"), "ada")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer s3cret", "Secrets are only redacted for History and code, not when sending")
        XCTAssertEqual(sent.httpBody, Data(#"{"user":"ada"}"#.utf8))
    }

    func testUnknownVariablesAreSentAsWritten() async throws {
        let request = APIRequest(name: "v", url: "https://api.example.com")
        request.headers = [KeyValuePair(key: "X-Missing", value: "{{missing}}")]
        let sent = try await send(RequestSnapshot(request).resolved(with: .empty))
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-Missing"), "{{missing}}")
    }

    func testRequestUsesAThirtySecondTimeout() async throws {
        let sent = try await send(APIRequest(name: "t", url: "https://api.example.com"))
        XCTAssertEqual(sent.timeoutInterval, 30)
    }
}
