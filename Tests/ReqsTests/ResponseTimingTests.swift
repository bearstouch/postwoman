import XCTest

@testable import Reqs

final class ResponseTimingTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1000)

    private func at(_ milliseconds: Double) -> Date {
        start.addingTimeInterval(milliseconds / 1000)
    }

    func testNewTLSConnectionHasEveryPhase() {
        let marks = ResponseTiming.Marks(
            domainLookupStart: at(1), domainLookupEnd: at(5), connectStart: at(5), secureConnectionStart: at(20),
            secureConnectionEnd: at(50), connectEnd: at(50), requestStart: at(50), requestEnd: at(52),
            responseStart: at(160), responseEnd: at(180))
        let timing = ResponseTiming(taskStart: start, total: 182, marks: marks)

        XCTAssertEqual(timing.phases.map(\.kind), ResponseTiming.Phase.Kind.allCases)
        let durations = timing.phases.map { ($0.duration * 1000).rounded() / 1000 }
        XCTAssertEqual(durations, [4, 15, 30, 2, 108, 20])
        XCTAssertEqual(timing.phases.first { $0.kind == .waiting }?.start ?? 0, 52, accuracy: 0.001)
    }

    func testReusedConnectionSkipsMissingPhases() {
        let marks = ResponseTiming.Marks(requestStart: at(0), requestEnd: at(1), responseStart: at(40), responseEnd: at(42))
        let timing = ResponseTiming(taskStart: start, total: 42, marks: marks, isReusedConnection: true)
        XCTAssertEqual(timing.phases.map(\.kind), [.request, .waiting, .download])
    }

    func testPlainHTTPConnectEndsAtConnectEnd() {
        let marks = ResponseTiming.Marks(connectStart: at(0), connectEnd: at(12))
        let timing = ResponseTiming(taskStart: start, total: 12, marks: marks)
        XCTAssertEqual(timing.phases.map(\.kind), [.connect])
        XCTAssertEqual(timing.phases[0].duration, 12, accuracy: 0.001)
    }

    func testProtocolNames() {
        XCTAssertEqual(ResponseTiming.protocolDisplayName("h2"), "HTTP/2")
        XCTAssertEqual(ResponseTiming.protocolDisplayName("http/1.1"), "HTTP/1.1")
    }

    func testParsesSetCookie() throws {
        let url = try XCTUnwrap(URL(string: "https://api.example.com/v1/login"))
        let cookies = ResponseCookie.parse(
            headerFields: ["Set-Cookie": "session=abc123; Path=/; Secure; HttpOnly; SameSite=Lax"], url: url)
        XCTAssertEqual(cookies.count, 1)
        let cookie = try XCTUnwrap(cookies.first)
        XCTAssertEqual(cookie.name, "session")
        XCTAssertEqual(cookie.value, "abc123")
        XCTAssertTrue(cookie.isSecure)
        XCTAssertTrue(cookie.isHTTPOnly)
        XCTAssertNil(cookie.expires)
    }
}
