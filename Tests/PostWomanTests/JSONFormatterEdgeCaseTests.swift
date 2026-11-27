import XCTest

@testable import PostWoman

final class JSONFormatterEdgeCaseTests: XCTestCase {
    func testEmptyAndWhitespaceOnlyInputIsNotJSON() {
        for input in ["", " ", "\n\t \r\n"] {
            XCTAssertFalse(JSONFormatter.isValid(input), input.debugDescription)
            XCTAssertNil(JSONFormatter.format(input), input.debugDescription)
            XCTAssertNil(JSONFormatter.minify(input), input.debugDescription)
            XCTAssertNil(JSONFormatter.prettify(input), input.debugDescription)
        }
    }

    func testPartialAndMalformedJSONIsRejectedEverywhere() {
        let inputs = [#"{"a":"#, #"{"a":1"#, #"["x""#, #"{"a" 1}"#, "{'a':1}", "[01]", "[1.]", "[-]", #"{"a":1}{"b":2}"#, "NaN", "[\"tab\there\"]"]
        for input in inputs {
            XCTAssertFalse(JSONFormatter.isValid(input), input)
            XCTAssertNil(JSONFormatter.format(input), input)
            XCTAssertNil(JSONFormatter.minify(input), input)
            XCTAssertNil(JSONFormatter.prettify(input), input)
        }
    }

    func testPrettifyKeepsNumberLiteralsThatFormatWouldRewrite() throws {
        let input = #"{"big":12345678901234567890123,"tenth":0.1,"one":1.0,"exp":1e2,"neg":-0.0}"#
        let pretty = try XCTUnwrap(JSONFormatter.prettify(input))
        for literal in ["12345678901234567890123", "0.1", "1.0", "1e2", "-0.0"] {
            XCTAssertTrue(pretty.contains(": \(literal)"), "\(literal) in \(pretty)")
        }
        let formatted = try XCTUnwrap(JSONFormatter.format(input))
        XCTAssertFalse(formatted.contains("1e2"), "format re-encodes numbers, which is why the editor uses prettify")
    }

    func testPrettifyKeepsStringEscapesAndUnicodeAsWritten() throws {
        let backslash = "\\"
        let input =
            "{\"e\":\"\(backslash)u00e9\",\"emoji\":\"😀👩‍👩‍👧\",\"combined\":\"e\u{301}\",\"slash\":\"a\(backslash)/b\",\"nl\":\"x\(backslash)ny\",\"bs\":\"end\(backslash)\(backslash)\"}"
        let expected = """
            {
              "e": "\\u00e9",
              "emoji": "😀👩‍👩‍👧",
              "combined": "e\u{301}",
              "slash": "a\\/b",
              "nl": "x\\ny",
              "bs": "end\\\\"
            }
            """
        XCTAssertEqual(JSONFormatter.prettify(input), expected)
    }

    func testPrettifyLeavesPunctuationInsideStringsAlone() {
        let input = #"["{[:,]}", "  spaced  out  ", "\"{\""]"#
        XCTAssertEqual(JSONFormatter.prettify(input), "[\n  \"{[:,]}\",\n  \"  spaced  out  \",\n  \"\\\"{\\\"\"\n]")
    }

    func testPrettifyKeepsDuplicateKeysInOrder() {
        XCTAssertEqual(JSONFormatter.prettify(#"{"a":1,"a":2}"#), "{\n  \"a\": 1,\n  \"a\": 2\n}")
    }

    func testPrettifyCollapsesEmptyContainersWrittenWithWhitespace() {
        XCTAssertEqual(JSONFormatter.prettify("{ \n\t }"), "{}")
        XCTAssertEqual(JSONFormatter.prettify(#"{"a" : [ ] , "b" : { } }"#), "{\n  \"a\": [],\n  \"b\": {}\n}")
        XCTAssertEqual(JSONFormatter.prettify("[[ ], [{ }]]"), "[\n  [],\n  [\n    {}\n  ]\n]")
    }

    func testPrettifyReindentsAlreadyIndentedJSON() {
        let input = "{\r\n\t\"a\" :\t[\r\n\t\t1,\r\n\t\t2\r\n\t]\r\n}"
        XCTAssertEqual(JSONFormatter.prettify(input), "{\n  \"a\": [\n    1,\n    2\n  ]\n}")
    }

    func testPrettifyUsesTheGivenIndent() {
        XCTAssertEqual(JSONFormatter.prettify(#"{"a":{"b":true}}"#, indent: "\t"), "{\n\t\"a\": {\n\t\t\"b\": true\n\t}\n}")
        XCTAssertEqual(JSONFormatter.prettify("[null]", indent: ""), "[\nnull\n]")
    }

    func testPrettifyHandlesDeepNesting() throws {
        let depth = 100
        let input = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let lines = try XCTUnwrap(JSONFormatter.prettify(input)).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2 * (depth - 1) + 1)
        XCTAssertEqual(lines[depth - 1], String(repeating: "  ", count: depth - 1) + "[]")
        XCTAssertEqual(lines.first, "[")
        XCTAssertEqual(lines.last, "]")
        XCTAssertEqual(lines[depth], String(repeating: "  ", count: depth - 2) + "]")
    }

    func testPrettifiedTextParsesToTheSameValue() throws {
        let input = #"{"z":[1,2.5,{"k":"v","n":null}],"a":{"t":true,"f":false},"s":"😀 \"q\""}"#
        let pretty = try XCTUnwrap(JSONFormatter.prettify(input))
        let original = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? NSDictionary
        let reparsed = try JSONSerialization.jsonObject(with: Data(pretty.utf8)) as? NSDictionary
        XCTAssertEqual(original, reparsed)
        XCTAssertEqual(JSONFormatter.minify(pretty), JSONFormatter.minify(input))
    }

    func testFormatKeepsUnicodeUnescapedAndIsStable() throws {
        let formatted = try XCTUnwrap(JSONFormatter.format(#"{"name":"Zoë 😀","path":"/a/b"}"#))
        XCTAssertTrue(formatted.contains("Zoë 😀"))
        XCTAssertTrue(formatted.contains(#""/a/b""#), "slashes are not escaped")
        XCTAssertEqual(JSONFormatter.format(formatted), formatted)
    }

    func testFormatSortsKeysAtEveryLevel() throws {
        let formatted = try XCTUnwrap(JSONFormatter.format(#"{"b":{"d":1,"c":2},"a":[{"y":1,"x":2}]}"#))
        let keys = formatted.components(separatedBy: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("\"") ? String(trimmed.prefix(3)) : nil
        }
        XCTAssertEqual(keys, [#""a""#, #""x""#, #""y""#, #""b""#, #""c""#, #""d""#])
    }

    func testMinifyRemovesWhitespaceButNotStringContent() {
        XCTAssertEqual(JSONFormatter.minify("{ \"a b\" : [ 1 , \"c d\" ] }"), #"{"a b":[1,"c d"]}"#)
        XCTAssertEqual(JSONFormatter.minify(#"["a/b"]"#), #"["a/b"]"#)
    }

    func testLeadingByteOrderMarkIsAcceptedAndKept() {
        XCTAssertTrue(JSONFormatter.isValid("\u{FEFF}{\"a\":1}"))
        XCTAssertEqual(JSONFormatter.prettify("\u{FEFF}{\"a\":1}"), "\u{FEFF}{\n  \"a\": 1\n}")
    }

    func testLoneSurrogateEscapeIsInvalid() {
        XCTAssertFalse(JSONFormatter.isValid(#"["\ud800"]"#))
        XCTAssertNil(JSONFormatter.prettify(#"["\ud800"]"#))
    }
}
