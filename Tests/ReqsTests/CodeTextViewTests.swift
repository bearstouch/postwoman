import AppKit
import XCTest

@testable import Reqs

@MainActor private let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

private func foreground(_ text: NSAttributedString, at location: Int) -> NSColor? {
    text.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
}

/// A text view inside a scroll view, as `CodeTextEditor` builds it.
@MainActor
private func makeTextView(_ string: String) -> (NSScrollView, NSTextView) {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let textView = NSTextView(usingTextLayoutManager: false)
    scrollView.documentView = textView
    textView.string = string
    return (scrollView, textView)
}

@MainActor
final class ResponseTextAttributesTests: XCTestCase {
    func testEmptyBodyHasNoAttributesToApply() {
        XCTAssertEqual(ResponseTextView.attributedText("", highlightsJSON: true, font: codeFont).length, 0)
    }

    func testEveryCharacterGetsTheCodeFontAndTextColor() {
        let text = ResponseTextView.attributedText("plain\nbody 😀", highlightsJSON: false, font: codeFont)
        for location in 0..<text.length {
            XCTAssertEqual(text.attribute(.font, at: location, effectiveRange: nil) as? NSFont, codeFont)
            XCTAssertTrue(foreground(text, at: location) === CodePalette.text)
        }
    }

    func testWrappedLinesHangUnderTheirOwnIndentation() throws {
        let body = "{\n    \"a\": 1,\n\t\"b\": 2\n}"
        let text = ResponseTextView.attributedText(body, highlightsJSON: false, font: codeFont)
        let unit = ("0" as NSString).size(withAttributes: [.font: codeFont]).width
        let string = body as NSString
        func style(atLineContaining needle: String) throws -> NSParagraphStyle {
            try XCTUnwrap(text.attribute(.paragraphStyle, at: string.range(of: needle).location, effectiveRange: nil) as? NSParagraphStyle)
        }
        XCTAssertEqual(try style(atLineContaining: "{").headIndent, 2 * unit, accuracy: 0.001)
        XCTAssertEqual(try style(atLineContaining: "\"a\"").headIndent, 6 * unit, accuracy: 0.001)
        XCTAssertEqual(try style(atLineContaining: "\"b\"").headIndent, 2 * unit, accuracy: 0.001, "only spaces count, not tabs")
        XCTAssertEqual(try style(atLineContaining: "\"a\"").lineSpacing, 3)
        XCTAssertEqual(try style(atLineContaining: "\"a\"").firstLineHeadIndent, 0)
    }

    func testJSONColorsOnlyWhenAsked() throws {
        let body = #"{"key": 1}"#
        let location = (body as NSString).range(of: #""key""#).location
        XCTAssertTrue(try XCTUnwrap(foreground(ResponseTextView.attributedText(body, highlightsJSON: true, font: codeFont), at: location)) === CodePalette.key)
        XCTAssertTrue(try XCTUnwrap(foreground(ResponseTextView.attributedText(body, highlightsJSON: false, font: codeFont), at: location)) === CodePalette.text)
    }

    func testHugeBodiesAreShownPlain() {
        let element = #"{"k": 1},"#
        let body = "[" + String(repeating: element, count: 1_000_000 / element.utf16.count + 1) + "null]"
        XCTAssertGreaterThan(body.utf16.count, 1_000_000)
        let text = ResponseTextView.attributedText(body, highlightsJSON: true, font: codeFont)
        XCTAssertTrue(foreground(text, at: 2) === CodePalette.text, "no JSON colors past the limit")
        XCTAssertNil(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil), "no hanging indents past the limit")
        XCTAssertEqual(text.attribute(.font, at: text.length - 1, effectiveRange: nil) as? NSFont, codeFont)
    }
}

@MainActor
final class CodeTextEditorHighlightingTests: XCTestCase {
    func testJSONAndVariablesAreColoredWhenEnabled() throws {
        let body = #"{"url": "{{host}}/v1", "n": 2}"#
        let (_, textView) = makeTextView(body)
        CodeTextEditor.applyHighlighting(to: textView, enabled: true)
        let storage = try XCTUnwrap(textView.textStorage)
        let string = body as NSString
        XCTAssertTrue(try XCTUnwrap(foreground(storage, at: string.range(of: #""url""#).location)) === CodePalette.key)
        XCTAssertTrue(try XCTUnwrap(foreground(storage, at: string.range(of: "2").location)) === CodePalette.number)
        let variable = string.range(of: "{{host}}")
        for location in variable.location..<NSMaxRange(variable) {
            XCTAssertTrue(try XCTUnwrap(foreground(storage, at: location)) === CodePalette.variable, "variables win over string color")
        }
        XCTAssertTrue(try XCTUnwrap(foreground(storage, at: string.range(of: "/v1").location)) === CodePalette.string)
    }

    func testVariablesAreColoredEvenWithoutJSON() throws {
        let body = "token={{api key}} & id=1"
        let (_, textView) = makeTextView(body)
        CodeTextEditor.applyHighlighting(to: textView, enabled: false)
        let storage = try XCTUnwrap(textView.textStorage)
        let string = body as NSString
        XCTAssertTrue(try XCTUnwrap(foreground(storage, at: string.range(of: "{{api key}}").location)) === CodePalette.variable)
        XCTAssertTrue(try XCTUnwrap(foreground(storage, at: string.range(of: "1").location)) === CodePalette.text)
        XCTAssertTrue(try XCTUnwrap(textView.typingAttributes[.foregroundColor] as? NSColor) === CodePalette.text, "new typing starts plain")
    }

    func testRehighlightingClearsColorsOfRemovedTokens() throws {
        let (_, textView) = makeTextView(#"{"k": true}"#)
        CodeTextEditor.applyHighlighting(to: textView, enabled: true)
        CodeTextEditor.applyHighlighting(to: textView, enabled: false)
        let storage = try XCTUnwrap(textView.textStorage)
        for location in 0..<storage.length {
            XCTAssertTrue(try XCTUnwrap(foreground(storage, at: location)) === CodePalette.text)
        }
    }

    func testVariablesAfterEmojiLandOnTheRightCharacters() throws {
        let body = "👩‍👩‍👧 {{name}}"
        let (_, textView) = makeTextView(body)
        CodeTextEditor.applyHighlighting(to: textView, enabled: false)
        let storage = try XCTUnwrap(textView.textStorage)
        let variable = (body as NSString).range(of: "{{name}}")
        XCTAssertTrue(try XCTUnwrap(foreground(storage, at: variable.location - 1)) === CodePalette.text)
        XCTAssertTrue(try XCTUnwrap(foreground(storage, at: variable.location)) === CodePalette.variable)
        XCTAssertTrue(try XCTUnwrap(foreground(storage, at: NSMaxRange(variable) - 1)) === CodePalette.variable)
    }

    func testLargeBodiesAreLeftUncoloredSoTypingStaysFast() throws {
        let body = "{{host}}" + String(repeating: #"{"k": 1},"#, count: 25_000)
        XCTAssertGreaterThan(body.utf16.count, 200_000)
        let (_, textView) = makeTextView(body)
        CodeTextEditor.applyHighlighting(to: textView, enabled: true)
        let storage = try XCTUnwrap(textView.textStorage)
        XCTAssertTrue(try XCTUnwrap(foreground(storage, at: 0)) === CodePalette.text)
        XCTAssertTrue(try XCTUnwrap(foreground(storage, at: 9)) === CodePalette.text)
    }
}

@MainActor
final class LineNumberGutterTests: XCTestCase {
    private func thickness(forDigits digits: Int) -> CGFloat {
        let width = ("0" as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]).width
        return max(36, ceil(CGFloat(digits) * width + 22))
    }

    private func gutter(for string: String) -> LineNumberRulerView {
        let (_, textView) = makeTextView(string)
        let ruler = LineNumberRulerView(textView: textView, textFont: codeFont)
        ruler.textDidChange()
        return ruler
    }

    func testEmptyTextGetsTheMinimumWidth() {
        XCTAssertEqual(gutter(for: "").ruleThickness, thickness(forDigits: 1))
        XCTAssertEqual(thickness(forDigits: 1), 36)
    }

    func testGutterWidensForMoreDigits() {
        let hundred = gutter(for: Array(repeating: "x", count: 100).joined(separator: "\n"))
        XCTAssertEqual(hundred.ruleThickness, thickness(forDigits: 3))
        let tenThousand = gutter(for: Array(repeating: "x", count: 10_000).joined(separator: "\n"))
        XCTAssertEqual(tenThousand.ruleThickness, thickness(forDigits: 5))
        XCTAssertGreaterThan(tenThousand.ruleThickness, hundred.ruleThickness)
    }

    func testATrailingNewlineDoesNotStartANumberedLine() {
        let ninetyNine = gutter(for: String(repeating: "x\n", count: 99))
        XCTAssertEqual(ninetyNine.ruleThickness, thickness(forDigits: 2))
        XCTAssertLessThan(thickness(forDigits: 2), thickness(forDigits: 3), "the check above tells 99 lines from 100")
    }

    func testWindowsLineEndingsCountOnce() {
        XCTAssertEqual(gutter(for: Array(repeating: "x", count: 100).joined(separator: "\r\n")).ruleThickness, thickness(forDigits: 3))
        XCTAssertEqual(gutter(for: String(repeating: "x\r\n", count: 99)).ruleThickness, thickness(forDigits: 2))
    }

    func testGutterShrinksWhenTheTextDoes() {
        let (_, textView) = makeTextView(Array(repeating: "x", count: 1_000).joined(separator: "\n"))
        let ruler = LineNumberRulerView(textView: textView, textFont: codeFont)
        ruler.textDidChange()
        XCTAssertEqual(ruler.ruleThickness, thickness(forDigits: 4))
        textView.string = "x"
        ruler.textDidChange()
        XCTAssertEqual(ruler.ruleThickness, thickness(forDigits: 1))
    }
}
