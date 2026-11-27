import XCTest

@testable import PostWoman

final class HTTPResponseTests: XCTestCase {
    private func response(_ code: Int) -> HTTPResponse {
        HTTPResponse(statusCode: code, headers: [], body: nil, responseTime: 0, contentType: nil)
    }

    func testCommonCodesUseStandardReasonPhrases() {
        XCTAssertEqual(response(200).statusText, "OK")
        XCTAssertEqual(response(201).statusText, "Created")
        XCTAssertEqual(response(404).statusText, "Not Found")
        XCTAssertEqual(response(500).statusText, "Internal Server Error")
    }

    func testOtherCodesFallBackToFoundation() {
        XCTAssertFalse(response(418).statusText.isEmpty)
    }
}
