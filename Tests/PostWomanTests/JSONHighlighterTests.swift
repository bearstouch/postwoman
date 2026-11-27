import XCTest

@testable import PostWoman

final class JSONHighlighterTests: XCTestCase {
    private func kinds(_ json: String) -> [(JSONHighlighter.Kind, String)] {
        let string = json as NSString
        return JSONHighlighter.tokens(in: json).map { ($0.kind, string.substring(with: $0.range)) }
    }

    func testClassifiesKeysValuesAndPunctuation() {
        let tokens = kinds(#"{"a": "b", "n": -1.5e3, "t": true, "z": null}"#)
        let colored = tokens.filter { $0.0 != .punctuation }
        XCTAssertEqual(colored.map(\.0), [.key, .string, .key, .number, .key, .literal, .key, .literal])
        XCTAssertEqual(colored.map(\.1), [#""a""#, #""b""#, #""n""#, "-1.5e3", #""t""#, "true", #""z""#, "null"])
        XCTAssertEqual(tokens.filter { $0.0 == .punctuation }.count, 9)
    }

    func testEscapedQuotesStayInsideTheString() {
        let tokens = kinds(#"{"k" : "say \"hi\"", "x": 1}"#)
        XCTAssertEqual(tokens[1].0, .key)
        XCTAssertEqual(tokens[3].1, #""say \"hi\"""#)
        XCTAssertEqual(tokens[3].0, .string)
    }

    func testRangesAreUTF16Offsets() {
        let json = #"{"emoji": "😀", "after": 2}"#
        let tokens = kinds(json)
        XCTAssertEqual(tokens.first { $0.0 == .string }?.1, #""😀""#)
        XCTAssertEqual(tokens.last { $0.0 == .number }?.1, "2")
    }

    func testUnterminatedStringDoesNotCrash() {
        XCTAssertEqual(kinds(#"{"open"#).last?.0, .string)
    }
}
