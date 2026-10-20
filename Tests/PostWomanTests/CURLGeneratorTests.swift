import XCTest

@testable import PostWoman

final class CURLGeneratorTests: XCTestCase {
    func testGetRequestOmitsMethodAndAppendsEnabledQueryParams() {
        let request = APIRequest(name: "List", url: "https://api.example.com/items")
        request.queryParams = [KeyValuePair(key: "page", value: "2"), KeyValuePair(key: "skip", value: "x", isEnabled: false)]
        XCTAssertEqual(CURLGenerator().generate(from: request), "curl \\\n  'https://api.example.com/items?page=2'")
    }

    func testPostRequestIncludesHeadersBearerAuthAndEscapedBody() {
        let request = APIRequest(name: "Create", url: "https://api.example.com/items", method: .post)
        request.headers = [KeyValuePair(key: "Accept", value: "application/json")]
        request.authenticationType = .bearer
        request.authBearerToken = "token"
        request.bodyType = .json
        request.bodyContent = #"{"name":"it's"}"#
        let lines = CURLGenerator().generate(from: request).components(separatedBy: " \\\n  ")
        XCTAssertEqual(lines.first, "curl")
        XCTAssertTrue(lines.contains("-X POST"))
        XCTAssertTrue(lines.contains("-H 'Accept: application/json'"))
        XCTAssertTrue(lines.contains("-H 'Authorization: Bearer token'"))
        XCTAssertTrue(lines.contains(#"-d '{"name":"it'\''s"}'"#))
        XCTAssertTrue(lines.contains("-H 'Content-Type: application/json'"))
    }
}
