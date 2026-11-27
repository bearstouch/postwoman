import XCTest

@testable import PostWoman

final class HTTPResponseDetailsTests: XCTestCase {
    private func response(_ code: Int) -> HTTPResponse {
        HTTPResponse(statusCode: code, headers: [], body: nil, responseTime: 0, contentType: nil)
    }

    func testEveryMappedCodeHasItsStandardReasonPhrase() {
        let phrases: [Int: String] = [
            200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 206: "Partial Content", 301: "Moved Permanently", 302: "Found", 303: "See Other",
            304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
            405: "Method Not Allowed", 406: "Not Acceptable", 408: "Request Timeout", 409: "Conflict", 410: "Gone", 413: "Content Too Large",
            415: "Unsupported Media Type", 422: "Unprocessable Content", 429: "Too Many Requests", 500: "Internal Server Error", 501: "Not Implemented",
            502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout"
        ]
        for (code, phrase) in phrases {
            XCTAssertEqual(response(code).statusText, phrase, "\(code)")
        }
    }

    func testUnmappedCodesUseFoundationsTextCapitalized() {
        for code in [100, 418, 451, 599, 799] {
            XCTAssertEqual(response(code).statusText, HTTPURLResponse.localizedString(forStatusCode: code).capitalized, "\(code)")
            XCTAssertFalse(response(code).statusText.isEmpty)
        }
    }

    func testSuccessIsExactlyTheTwoHundreds() {
        let cases: [(Int, Bool)] = [(0, false), (100, false), (199, false), (200, true), (204, true), (299, true), (300, false), (404, false), (500, false)]
        for (code, success) in cases {
            XCTAssertEqual(response(code).isSuccess, success, "\(code)")
        }
    }

    func testAnErrorResponseCarriesTheMessageAndNoStatus() {
        let failure = HTTPResponse.error(URLError(.timedOut))
        XCTAssertEqual(failure.statusCode, 0)
        XCTAssertFalse(failure.isSuccess)
        XCTAssertEqual(failure.body, "Error: \(URLError(.timedOut).localizedDescription)")
        XCTAssertEqual(failure.headers, [])
        XCTAssertEqual(failure.responseTime, 0)
        XCTAssertNil(failure.contentType)
        XCTAssertEqual(HTTPResponse.error(HTTPClientError.invalidURL).body, "Error: Invalid URL")
    }

    func testOptionalDetailsDefaultToUnknown() {
        let plain = response(200)
        XCTAssertEqual(plain.cookies, [])
        XCTAssertNil(plain.timing)
        XCTAssertNil(plain.bodySize)
        XCTAssertNil(plain.stream)
    }

    func testClientErrorDescriptions() {
        XCTAssertEqual(HTTPClientError.invalidURL.errorDescription, "Invalid URL")
        XCTAssertEqual(HTTPClientError.invalidResponse.errorDescription, "Invalid response from server")
        XCTAssertEqual(HTTPClientError.networkError(URLError(.cannotFindHost)).errorDescription, URLError(.cannotFindHost).localizedDescription)
    }
}

final class ResponseTimingEdgeCaseTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 5000)

    private func at(_ milliseconds: Double) -> Date {
        start.addingTimeInterval(milliseconds / 1000)
    }

    func testNoMarksMeansNoPhases() {
        let timing = ResponseTiming(taskStart: start, total: 12.5, marks: ResponseTiming.Marks())
        XCTAssertEqual(timing.phases, [])
        XCTAssertEqual(timing.total, 12.5)
        XCTAssertFalse(timing.isReusedConnection)
        XCTAssertEqual(timing.redirectCount, 0)
        XCTAssertNil(timing.networkProtocol)
    }

    func testAPhaseThatEndsBeforeItStartsIsDropped() {
        let marks = ResponseTiming.Marks(domainLookupStart: at(10), domainLookupEnd: at(5), requestStart: at(20), requestEnd: at(20))
        let timing = ResponseTiming(taskStart: start, total: 30, marks: marks)
        XCTAssertEqual(timing.phases.map(\.kind), [.request], "A zero-length phase is kept; a negative one isn't.")
        XCTAssertEqual(timing.phases.first?.duration, 0)
    }

    func testAPhaseMissingEitherEndIsDropped() {
        let marks = ResponseTiming.Marks(domainLookupStart: at(0), connectEnd: at(5), requestEnd: at(6), responseStart: at(40))
        let timing = ResponseTiming(taskStart: start, total: 40, marks: marks)
        XCTAssertEqual(timing.phases.map(\.kind), [.waiting], "Waiting runs from the request's end to the first byte.")
    }

    func testATLSHandshakeWithoutItsEndStillEndsTheConnectPhase() {
        let marks = ResponseTiming.Marks(connectStart: at(2), secureConnectionStart: at(9), connectEnd: at(30))
        let timing = ResponseTiming(taskStart: start, total: 30, marks: marks)
        XCTAssertEqual(timing.phases.map(\.kind), [.connect])
        XCTAssertEqual(timing.phases[0].start, 2, accuracy: 0.001)
        XCTAssertEqual(timing.phases[0].duration, 7, accuracy: 0.001, "TCP connect stops where TLS starts.")
    }

    func testPhaseStartsAreOffsetsFromTheTaskStart() {
        let marks = ResponseTiming.Marks(requestStart: at(250), requestEnd: at(251), responseStart: at(300), responseEnd: at(1300))
        let timing = ResponseTiming(taskStart: start, total: 1300, marks: marks, redirectCount: 2)
        XCTAssertEqual(timing.phases.map { ($0.start * 1000).rounded() / 1000 }, [250, 251, 300], "Time spent on redirects shows as the first offset.")
        XCTAssertEqual(timing.phases.last?.duration ?? 0, 1000, accuracy: 0.001)
        XCTAssertEqual(timing.redirectCount, 2)
    }

    func testPhasesAreIdentifiedByKindInWaterfallOrder() {
        XCTAssertEqual(
            ResponseTiming.Phase.Kind.allCases.map(\.rawValue), ["DNS lookup", "TCP connect", "TLS handshake", "Request sent", "Waiting (TTFB)", "Content download"])
        XCTAssertEqual(ResponseTiming.Phase(kind: .tls, start: 0, duration: 1).id, .tls)
    }

    func testProtocolDisplayNames() {
        let cases = [("h2", "HTTP/2"), ("H2", "HTTP/2"), ("h3", "HTTP/3"), ("http/1.1", "HTTP/1.1"), ("HTTP/1.1", "HTTP/1.1"), ("http/1.0", "HTTP/1.0"), ("spdy/3", "SPDY/3"), ("", "")]
        for (name, display) in cases {
            XCTAssertEqual(ResponseTiming.protocolDisplayName(name), display, name)
        }
    }

    func testTimingSurvivesEncoding() throws {
        let marks = ResponseTiming.Marks(
            domainLookupStart: at(0), domainLookupEnd: at(3), connectStart: at(3), secureConnectionStart: at(8), secureConnectionEnd: at(20), connectEnd: at(20),
            requestStart: at(20), requestEnd: at(21), responseStart: at(80), responseEnd: at(90))
        let timing = ResponseTiming(
            taskStart: start, total: 91, marks: marks, networkProtocol: "HTTP/2", isReusedConnection: true, remoteAddress: "[::1]:443", tlsVersion: "TLS 1.3",
            redirectCount: 1)
        XCTAssertEqual(try JSONDecoder().decode(ResponseTiming.self, from: JSONEncoder().encode(timing)), timing)
    }
}

@MainActor
final class ResponseFormattingTests: XCTestCase {
    func testDurationsUseMillisecondsThenSeconds() {
        let cases: [(Double, String)] = [
            (0, "0.0 ms"), (0.04, "0.0 ms"), (0.44, "0.4 ms"), (9.94, "9.9 ms"), (10, "10 ms"), (10.4, "10 ms"), (10.5, "11 ms"), (999.4, "999 ms"), (1000, "1.00 s"),
            (1500, "1.50 s"), (61_000, "61.00 s")
        ]
        for (milliseconds, text) in cases {
            XCTAssertEqual(ResponseTimingView.format(milliseconds), text, "\(milliseconds)")
        }
    }

    func testHeaderListsNeedThreeTokens() {
        let cases: [(String, [String]?)] = [
            ("GET, POST, PUT, DELETE", ["GET", "POST", "PUT", "DELETE"]), ("a,b,c", ["a", "b", "c"]), (" a ,\tb\t, c ", ["a", "b", "c"]),
            ("Accept,Accept-Encoding,Origin,", nil), (",a,b", nil), (",,,", nil), ("a,b", nil), ("a", nil), ("", nil),
            ("text/html, application/xhtml+xml, application/xml;q=0.9", ["text/html", "application/xhtml+xml", "application/xml;q=0.9"]),
            ("max-age=0, no cache, private", nil)
        ]
        for (value, items) in cases {
            XCTAssertEqual(ResponseHeadersView.listItems(in: value), items, value)
        }
    }
}

final class ResponseCookieTests: XCTestCase {
    private let url = URL(string: "https://api.example.com/v1/login")!

    private func cookies(_ setCookie: String) -> [ResponseCookie] {
        ResponseCookie.parse(headerFields: ["Set-Cookie": setCookie], url: url)
    }

    func testDefaultsComeFromTheURL() throws {
        let cookie = try XCTUnwrap(cookies("theme=dark").first)
        XCTAssertEqual(cookie.domain, "api.example.com")
        XCTAssertEqual(cookie.path, "/v1", "The default path is the URL's directory.")
        XCTAssertNil(cookie.expires, "Without Expires or Max-Age it's a session cookie.")
        XCTAssertFalse(cookie.isSecure)
        XCTAssertFalse(cookie.isHTTPOnly)
        XCTAssertNil(cookie.sameSite)
        XCTAssertEqual(cookie.id, "api.example.com/v1theme")
    }

    func testReadsAttributes() throws {
        let cookie = try XCTUnwrap(cookies("id=a1; Domain=example.com; Path=/; Max-Age=3600; SameSite=Lax; Secure").first)
        XCTAssertEqual(cookie.domain, ".example.com")
        XCTAssertEqual(cookie.path, "/")
        XCTAssertTrue(cookie.isSecure)
        XCTAssertEqual(cookie.sameSite?.lowercased(), "lax")
        let expires = try XCTUnwrap(cookie.expires)
        XCTAssertEqual(expires.timeIntervalSinceNow, 3600, accuracy: 60)
    }

    func testAnExpiresDateMakesItPersistent() throws {
        let cookie = try XCTUnwrap(cookies("old=1; Expires=Wed, 21 Oct 2037 07:28:00 GMT").first)
        XCTAssertGreaterThan(try XCTUnwrap(cookie.expires), Date())
    }

    func testSeveralCookiesInOneHeader() {
        let parsed = cookies("a=1; Path=/, b=two; HttpOnly")
        XCTAssertEqual(parsed.map(\.name), ["a", "b"])
        XCTAssertEqual(parsed.map(\.value), ["1", "two"])
        XCTAssertEqual(parsed.map(\.isHTTPOnly), [false, true])
        XCTAssertNotEqual(parsed[0].id, parsed[1].id)
    }

    func testNoSetCookieMeansNoCookies() {
        XCTAssertEqual(ResponseCookie.parse(headerFields: [:], url: url), [])
        XCTAssertEqual(ResponseCookie.parse(headerFields: ["Cookie": "a=1", "Content-Type": "text/plain"], url: url), [], "A request Cookie header isn't a set cookie.")
        XCTAssertEqual(cookies("=novalue"), [])
    }
}
