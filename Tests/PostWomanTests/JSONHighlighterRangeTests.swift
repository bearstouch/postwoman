import AppKit
import XCTest

@testable import PostWoman

final class JSONHighlighterRangeTests: XCTestCase {
    /// Valid and broken JSON, with emoji, flags, combining marks and escapes that make UTF-16 offsets differ from characters.
    private let corpus = [
        "",
        "   \n\t",
        #"{"a": "b", "n": -1.5e+3, "t": true, "f": false, "z": null}"#,
        #"{"👩‍👩‍👧": "🇵🇹", "é": "e\u0301", "k": [1, "😀", {"x": "\"😀\""}]}"#,
        #"{"open"#,
        #""ends with a backslash \"#,
        #"{"a": tru, "b": nullish, "c": True, "d": undefined}"#,
        "[1,2,3]]]}}}{{{",
        #"{"k"  :  "v"  ,  "l"  :  [  ]  }"#,
        "\"\\",
        "-",
        "😀😀😀",
        #"{"a":"x","b":"y"}"#
    ]

    private func pieces(_ json: String) -> [(JSONHighlighter.Kind, String)] {
        let string = json as NSString
        return JSONHighlighter.tokens(in: json).map { ($0.kind, string.substring(with: $0.range)) }
    }

    func testTokensAreInBoundsOrderedAndNeverOverlap() {
        for json in corpus {
            let length = (json as NSString).length
            var end = 0
            for token in JSONHighlighter.tokens(in: json) {
                XCTAssertGreaterThan(token.range.length, 0, json)
                XCTAssertGreaterThanOrEqual(token.range.location, end, "overlap in \(json)")
                XCTAssertLessThanOrEqual(NSMaxRange(token.range), length, "out of bounds in \(json)")
                end = NSMaxRange(token.range)
            }
        }
    }

    func testTokensCoverEveryNonWhitespaceUnitOfValidJSON() throws {
        let valid = [
            #"{"a": "b", "n": -1.5e+3, "t": true, "f": false, "z": null}"#,
            #"{"👩‍👩‍👧": "🇵🇹", "é": "e\u0301", "k": [1, "😀", {"x": "\"😀\""}]}"#,
            #"{"k"  :  "v"  ,  "l"  :  [  ]  }"#,
            try XCTUnwrap(JSONFormatter.prettify(#"{"deep":[[[{"a":[0.5,"\\"]}]]]}"#))
        ]
        for json in valid {
            XCTAssertTrue(JSONFormatter.isValid(json), json)
            let units = Array(json.utf16)
            var covered = [Bool](repeating: false, count: units.count)
            for token in JSONHighlighter.tokens(in: json) {
                for offset in token.range.location..<NSMaxRange(token.range) { covered[offset] = true }
            }
            for (offset, unit) in units.enumerated() where !covered[offset] {
                XCTAssertTrue([0x20, 0x09, 0x0A, 0x0D].contains(unit), "unit \(unit) at \(offset) is uncolored in \(json)")
            }
        }
    }

    func testRangesLandOnTheRightTextAfterSurrogatePairsAndZWJSequences() {
        let json = #"{"👩‍👩‍👧": "🇵🇹", "after": 42}"#
        let string = json as NSString
        let tokens = JSONHighlighter.tokens(in: json)
        XCTAssertEqual(tokens.first { $0.kind == .number }?.range, string.range(of: "42"))
        XCTAssertEqual(tokens.first { $0.kind == .key }?.range, string.range(of: #""👩‍👩‍👧""#))
        XCTAssertEqual(tokens.last { $0.kind == .key }?.range, string.range(of: #""after""#))
        XCTAssertEqual(tokens.first { $0.kind == .string }?.range, string.range(of: #""🇵🇹""#))
    }

    func testEmptyAndWhitespaceOnlyTextHasNoTokens() {
        XCTAssertEqual(JSONHighlighter.tokens(in: ""), [])
        XCTAssertEqual(JSONHighlighter.tokens(in: " \n\r\t"), [])
    }

    func testAKeyIsAStringFollowedByAColonEvenAcrossWhitespace() {
        let tokens = pieces("{\"a\"\n\t :1, \"b\" , \"c\"}")
        XCTAssertEqual(tokens.filter { $0.0 == .key }.map(\.1), [#""a""#])
        XCTAssertEqual(tokens.filter { $0.0 == .string }.map(\.1), [#""b""#, #""c""#])
    }

    func testStringsInArraysAreValuesNotKeys() {
        XCTAssertEqual(pieces(#"["a", "b"]"#).filter { $0.0 != .punctuation }.map(\.0), [.string, .string])
    }

    func testEscapedBackslashBeforeTheClosingQuoteEndsTheString() {
        let tokens = pieces(#"{"path": "C:\\", "n": 1}"#)
        XCTAssertEqual(tokens.first { $0.0 == .string }?.1, #""C:\\""#)
        XCTAssertEqual(tokens.filter { $0.0 == .key }.map(\.1), [#""path""#, #""n""#])
        XCTAssertEqual(tokens.last { $0.0 == .number }?.1, "1")
    }

    func testDigitsAndLiteralsInsideStringsStayString() {
        let tokens = pieces(#"{"v": "123 true null"}"#)
        XCTAssertEqual(tokens.filter { $0.0 != .punctuation }.map(\.0), [.key, .string])
    }

    func testNumbersIncludeSignsFractionsAndExponents() {
        let numbers = pieces("[0, -12, 3.25, 1e10, 2E-5, 6.02e+23]").filter { $0.0 == .number }.map(\.1)
        XCTAssertEqual(numbers, ["0", "-12", "3.25", "1e10", "2E-5", "6.02e+23"])
    }

    func testOnlyExactLowercaseLiteralsAreColored() {
        let tokens = pieces(#"[true, false, null, True, NULL, nullish, tru, undefined]"#)
        XCTAssertEqual(tokens.filter { $0.0 == .literal }.map(\.1), ["true", "false", "null"])
        XCTAssertEqual(tokens.filter { $0.0 != .punctuation }.count, 3, "unknown words are left uncolored")
    }

    func testUnterminatedStringRunsToTheEndOfTheText() {
        for json in [#"{"a": "no end"#, #""trailing backslash \"#, "\"\\"] {
            let length = (json as NSString).length
            let last = JSONHighlighter.tokens(in: json).last
            XCTAssertEqual(last?.kind, .string, json)
            XCTAssertEqual(last.map { NSMaxRange($0.range) }, length, json)
        }
    }

    func testEveryBracketAndSeparatorIsPunctuationEvenWhenUnbalanced() {
        let tokens = pieces("]]}{:,[")
        XCTAssertEqual(tokens.map(\.0), Array(repeating: .punctuation, count: 7))
        XCTAssertEqual(tokens.map(\.1), ["]", "]", "}", "{", ":", ",", "["])
    }

    func testColorizeColorsTokensAndKeepsOtherAttributes() throws {
        let json = #"{"k": [1, true, "s"]}"#
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let text = NSMutableAttributedString(string: json, attributes: [.font: font])
        JSONHighlighter.colorize(text)
        let string = json as NSString
        func color(of piece: String) -> NSColor? {
            text.attribute(.foregroundColor, at: string.range(of: piece).location, effectiveRange: nil) as? NSColor
        }
        XCTAssertTrue(try XCTUnwrap(color(of: #""k""#)) === CodePalette.key)
        XCTAssertTrue(try XCTUnwrap(color(of: "1")) === CodePalette.number)
        XCTAssertTrue(try XCTUnwrap(color(of: "true")) === CodePalette.literal)
        XCTAssertTrue(try XCTUnwrap(color(of: #""s""#)) === CodePalette.string)
        XCTAssertTrue(try XCTUnwrap(color(of: "[")) === CodePalette.punctuation)
        XCTAssertNil(text.attribute(.foregroundColor, at: string.range(of: " ").location, effectiveRange: nil), "whitespace is left alone")
        var fontRange = NSRange()
        let fullRange = NSRange(location: 0, length: string.length)
        XCTAssertEqual(text.attribute(.font, at: 0, longestEffectiveRange: &fontRange, in: fullRange) as? NSFont, font)
        XCTAssertEqual(fontRange, fullRange)
    }

    func testEachKindHasItsOwnPaletteColor() {
        let kinds: [JSONHighlighter.Kind] = [.key, .string, .number, .literal, .punctuation]
        let expected = [CodePalette.key, CodePalette.string, CodePalette.number, CodePalette.literal, CodePalette.punctuation]
        for (kind, color) in zip(kinds, expected) {
            XCTAssertTrue(JSONHighlighter.color(for: kind) === color, "\(kind)")
        }
    }

    func testLargeBodyTokenizesLinearly() {
        let element = #"{"id": 123, "name": "😀 item", "ok": true},"#
        let json = "[" + String(repeating: element, count: 5_000) + "null]"
        let tokens = JSONHighlighter.tokens(in: json)
        XCTAssertEqual(tokens.filter { $0.kind == .key }.count, 15_000)
        XCTAssertEqual(tokens.filter { $0.kind == .literal }.count, 5_001)
        XCTAssertEqual(tokens.last.map { NSMaxRange($0.range) }, (json as NSString).length)
    }
}
