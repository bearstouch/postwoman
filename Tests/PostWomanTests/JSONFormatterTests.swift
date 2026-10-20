import XCTest

@testable import PostWoman

final class JSONFormatterTests: XCTestCase {
    func testFormatSortsKeysAndKeepsSlashes() {
        XCTAssertEqual(JSONFormatter.format(#"{"b":1,"a":"x/y"}"#), "{\n  \"a\" : \"x/y\",\n  \"b\" : 1\n}")
    }

    func testMinifyRoundTripsFormattedJSON() throws {
        let formatted = try XCTUnwrap(JSONFormatter.format(#"{"a":[1,2]}"#))
        XCTAssertEqual(JSONFormatter.minify(formatted), #"{"a":[1,2]}"#)
    }

    func testInvalidJSONIsRejected() {
        XCTAssertNil(JSONFormatter.format("{not json"))
        XCTAssertNil(JSONFormatter.minify("{not json"))
        XCTAssertFalse(JSONFormatter.isValid("{not json"))
        XCTAssertTrue(JSONFormatter.isValid("[]"))
    }
}
