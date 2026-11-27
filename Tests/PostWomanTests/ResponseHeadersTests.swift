import XCTest

@testable import PostWoman

@MainActor
final class ResponseHeadersTests: XCTestCase {
    func testTokenListsSplitIntoItems() {
        XCTAssertEqual(
            ResponseHeadersView.listItems(in: "X-Request-Id,X-RateLimit-Limit, Retry-After"),
            ["X-Request-Id", "X-RateLimit-Limit", "Retry-After"])
    }

    func testOtherValuesStayWhole() {
        XCTAssertNil(ResponseHeadersView.listItems(in: "Fri, 27 Nov 2026 17:24:32 GMT"))
        XCTAssertNil(ResponseHeadersView.listItems(in: "application/json"))
        XCTAssertNil(ResponseHeadersView.listItems(in: "gzip, br"))
        XCTAssertNil(ResponseHeadersView.listItems(in: "a,,b,c"))
    }
}
