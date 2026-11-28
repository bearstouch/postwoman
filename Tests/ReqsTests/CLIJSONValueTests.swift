import Foundation
import XCTest

@testable import ReqsCLI

private func decode(_ text: String) throws -> ReqsCLI.JSONValue { try JSONDecoder().decode(ReqsCLI.JSONValue.self, from: Data(text.utf8)) }

/// The CLI's own JSON tree (the app has another; this file always means the CLI's).
final class CLIJSONValueTests: XCTestCase {
    func testDecodesEveryKind() throws {
        XCTAssertEqual(
            try decode(#"{"n":null,"t":true,"f":false,"i":1,"d":-2.5,"s":"x","a":[1,"a"],"o":{"k":{}}}"#),
            .object([
                "n": .null, "t": .bool(true), "f": .bool(false), "i": .number(1), "d": .number(-2.5), "s": .string("x"), "a": .array([.number(1), .string("a")]),
                "o": .object(["k": .object([:])])
            ]))
        XCTAssertEqual(try decode(#""x""#), .string("x"))
        XCTAssertEqual(try decode("3"), .number(3))
        XCTAssertEqual(try decode("null"), .null)
        XCTAssertEqual(try decode("[]"), .array([]))
    }

    func testBooleansAndNumbersStayDistinct() throws {
        XCTAssertEqual(try decode("[true,1,0,false,1.0,-0.5]"), .array([.bool(true), .number(1), .number(0), .bool(false), .number(1), .number(-0.5)]))
        XCTAssertNotEqual(ReqsCLI.JSONValue.bool(true), .number(1))
        XCTAssertEqual(ReqsCLI.JSONValue.array([.bool(false), .number(0)]).compact, "[false,0]")
    }

    func testWholeNumbersEncodeWithoutAFraction() {
        let cases: [(Double, String)] = [(1, "1"), (0, "0"), (-3, "-3"), (1.5, "1.5"), (0.1, "0.1"), (262_144, "262144"), (1e21, "1e+21")]
        for (number, expected) in cases { XCTAssertEqual(ReqsCLI.JSONValue.number(number).compact, expected, "\(number)") }
    }

    func testLargeIntegersAreDoublesAndLosePrecisionPast2To53() throws {
        XCTAssertEqual(try decode("9007199254740992"), .number(9_007_199_254_740_992))
        XCTAssertEqual(try decode("9007199254740993"), .number(9_007_199_254_740_992), "IDs are strings in the app's tools, so this never matters for them")
        XCTAssertEqual(try decode("12345678901234567890").number, 1.2345678901234567e19)
        XCTAssertEqual(try decode("1e2"), .number(100))
    }

    func testStringsAreEscapedOnlyWhereJSONRequires() throws {
        let text = "a/b\"\n\u{1}é😀\t\\"
        let encoded = ReqsCLI.JSONValue.string(text).compact
        XCTAssertEqual(encoded, #""a/b\"\n\u0001é😀\t\\""#, "Slashes and non-ASCII are kept as written")
        XCTAssertEqual(try decode(encoded), .string(text))
        XCTAssertEqual(try decode(#""é😀""#), .string("é😀"), "Escapes decode, including surrogate pairs")
    }

    func testKeysAreSortedCompactAndPretty() {
        let value = ReqsCLI.JSONValue.object(["b": .number(1), "a": .object(["d": .number(2), "c": .array([.null])]), "B": .string("upper")])
        XCTAssertEqual(value.compact, #"{"B":"upper","a":{"c":[null],"d":2},"b":1}"#)
        XCTAssertEqual(value.pretty, "{\n  \"B\" : \"upper\",\n  \"a\" : {\n    \"c\" : [\n      null\n    ],\n    \"d\" : 2\n  },\n  \"b\" : 1\n}")
        XCTAssertEqual(ReqsCLI.JSONValue.null.compact, "null")
        XCTAssertEqual(ReqsCLI.JSONValue.object([:]).compact, "{}")
        XCTAssertEqual(ReqsCLI.JSONValue.array([]).compact, "[]")
    }

    func testEncodingThenDecodingGivesTheSameValue() throws {
        let values: [ReqsCLI.JSONValue] = [
            .null, .bool(false), .number(-0.25), .string(""), .string("ünï 🍕 \u{0}"), .array([]), .object([:]),
            .object(["headers": .array([.object(["key": .string("A"), "value": .string("b: c")])]), "nested": .object(["deep": .array([.array([.bool(true)])])])])
        ]
        for value in values {
            XCTAssertEqual(try decode(value.compact), value, value.compact)
            XCTAssertEqual(try decode(value.pretty), value, value.compact)
            XCTAssertEqual(try JSONDecoder().decode(ReqsCLI.JSONValue.self, from: JSONEncoder().encode(value)), value)
        }
    }

    func testAccessorsAnswerOnlyForTheirKind() {
        let object = ReqsCLI.JSONValue.object(["a": .string("x"), "n": .number(2), "l": .array([.null])])
        XCTAssertEqual(object["a"], .string("x"))
        XCTAssertNil(object["missing"])
        XCTAssertEqual(object["a"]?.string, "x")
        XCTAssertEqual(object["n"]?.number, 2)
        XCTAssertEqual(object["l"]?.array, [.null])
        for other: ReqsCLI.JSONValue in [.null, .bool(true), .number(1), .string("a"), .array([.string("a")])] {
            XCTAssertNil(other["a"], other.compact)
        }
        XCTAssertNil(object["a"]?.number)
        XCTAssertNil(object["n"]?.string)
        XCTAssertNil(object["a"]?.array)
        XCTAssertNil(ReqsCLI.JSONValue.string("2").number, "A numeric string is not a number")
    }

    func testInvalidJSONIsRejected() {
        // Foundation's decoder tolerates trailing commas, so those are not listed.
        for text in ["", "{", "nul", "{'a':1}", "[1 2]", "{\"a\" 1}", "undefined"] {
            XCTAssertThrowsError(try decode(text), text)
        }
    }
}
