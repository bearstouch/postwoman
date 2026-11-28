import AppKit
import Observation
import SwiftUI
import XCTest

@testable import Reqs

/// One accessibility element with its value, help, title element and enabled state, and a way to press it as VoiceOver does.
@MainActor
private struct AXNode: @MainActor CustomStringConvertible {
    let object: NSObject
    let role: String
    let label: String
    let strings: [String]
    let help: String
    let isEnabled: Bool

    var description: String { "\(role) '\(label)'" + (help.isEmpty ? "" : " help '\(help)'") }

    func press() {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return XCTFail("\(self) can't be pressed") }
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        _ = unsafeBitCast(object.method(for: selector), to: Action.self)(object, selector)
    }

    static func all(in root: NSView) -> [AXNode] {
        var found: [AXNode] = []
        var seen = Set<ObjectIdentifier>()
        func read(_ node: NSObject, _ getter: String) -> Any? {
            node.responds(to: NSSelectorFromString(getter)) ? node.perform(NSSelectorFromString(getter))?.takeUnretainedValue() : nil
        }
        func visit(_ object: Any, depth: Int) {
            guard depth < 60, let node = object as? NSObject, seen.insert(ObjectIdentifier(node)).inserted else { return }
            let texts = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { read(node, $0) as? String }.filter { !$0.isEmpty }
            let enabled = node.responds(to: NSSelectorFromString("isAccessibilityEnabled")) ? node.value(forKey: "accessibilityEnabled") as? Bool : nil
            found.append(
                AXNode(
                    object: node, role: read(node, "accessibilityRole") as? String ?? "", label: (read(node, "accessibilityLabel") as? String) ?? "",
                    strings: texts, help: read(node, "accessibilityHelp") as? String ?? "", isEnabled: enabled ?? true))
            for child in read(node, "accessibilityChildren") as? [Any] ?? [] { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return found
    }
}

@MainActor
private extension NSView {
    var nodes: [AXNode] { AXNode.all(in: self) }
    func nodes(_ role: String) -> [AXNode] { nodes.filter { $0.role == role } }
    var allStrings: [String] { nodes.flatMap(\.strings) }
    /// The first view of `type` under this one, depth first.
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstSubview(of: type) { return match }
        }
        return nil
    }
}

private let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

/// State a hosted view edits through bindings, observed so the view redraws when a test changes it.
@MainActor @Observable
private final class Model {
    var pair = KeyValuePair(key: "Content-Type", value: "application/json")
    var pairs: [KeyValuePair] = []
    var text = ""
    var highlightsJSON = false
    var fontSize: CGFloat = 12
    var themeRevision = 0
    var deletions = 0
}

private struct RowHost: View {
    @Bindable var model: Model
    var resolver: VariableResolver?
    var body: some View { KeyValueRowView(pair: $model.pair, resolver: resolver) { model.deletions += 1 } }
}

private struct EditorHost: View {
    @Bindable var model: Model
    var body: some View { KeyValueEditorView(pairs: $model.pairs, keyPlaceholder: "Header", valuePlaceholder: "Content") }
}

private struct CodeHost: View {
    @Bindable var model: Model
    var body: some View {
        CodeTextEditor(
            text: $model.text, font: .monospacedSystemFont(ofSize: model.fontSize, weight: .regular), highlightsJSON: model.highlightsJSON,
            themeRevision: model.themeRevision)
    }
}

private let resolver = VariableResolver(defaults: [Variable(key: "host", value: "api.example.com")], selected: nil)

// MARK: - Key-value rows

@MainActor
final class KeyValueRowViewTests: XCTestCase {
    func testShowsTheKeyAndValueInLightAndDark() {
        for appearance in appearances {
            let model = Model()
            let hosting = ViewHosting.host(RowHost(model: model), size: CGSize(width: 500, height: 40), appearance: appearance)
            XCTAssertEqual(hosting.nodes("AXTextField").map { $0.strings.last ?? "" }, ["Content-Type", "application/json"])
            XCTAssertEqual(hosting.nodes("AXCheckBox").count, 1)
            XCTAssertEqual(hosting.nodes("AXButton").count, 1, "the delete button")
            ViewHosting.close(hosting)
        }
    }

    func testTheCheckboxTurnsTheRowOnAndOff() throws {
        let model = Model()
        let hosting = ViewHosting.host(RowHost(model: model), size: CGSize(width: 500, height: 40))
        defer { ViewHosting.close(hosting) }
        try XCTUnwrap(hosting.nodes("AXCheckBox").first).press()
        ViewHosting.settle()
        XCTAssertFalse(model.pair.isEnabled)
        XCTAssertEqual("\(hosting.nodes("AXCheckBox").first?.object.value(forKey: "accessibilityValue") ?? "")", "0", "off is a checkbox state, not just dimming")
        try XCTUnwrap(hosting.nodes("AXCheckBox").first).press()
        ViewHosting.settle()
        XCTAssertTrue(model.pair.isEnabled)
    }

    func testEditsToThePairAreShownInTheFields() {
        let model = Model()
        let hosting = ViewHosting.host(RowHost(model: model), size: CGSize(width: 500, height: 40))
        defer { ViewHosting.close(hosting) }
        model.pair.key = "Accept"
        model.pair.value = "text/plain"
        ViewHosting.settle()
        XCTAssertEqual(hosting.nodes("AXTextField").map { $0.strings.last ?? "" }, ["Accept", "text/plain"])
    }

    func testTheDeleteButtonCallsOnDeleteOnce() throws {
        let model = Model()
        let hosting = ViewHosting.host(RowHost(model: model), size: CGSize(width: 500, height: 40))
        defer { ViewHosting.close(hosting) }
        try XCTUnwrap(hosting.nodes("AXButton").first).press()
        ViewHosting.settle()
        XCTAssertEqual(model.deletions, 1)
    }

    func testEveryControlInARowIsNamedForVoiceOver() throws {
        let model = Model()
        let hosting = ViewHosting.host(
            KeyValueRowView(pair: .constant(model.pair), keyPlaceholder: "Header", valuePlaceholder: "Content", onDelete: {}), size: CGSize(width: 500, height: 40))
        defer { ViewHosting.close(hosting) }
        let checkbox = try XCTUnwrap(hosting.nodes("AXCheckBox").first)
        XCTAssertEqual(checkbox.label, "Enabled")
        XCTAssertEqual(checkbox.help, "Only enabled rows are sent.")
        XCTAssertEqual(hosting.nodes("AXTextField").map(\.label), ["Header", "Content"], "named even once they hold text")
        let delete = try XCTUnwrap(hosting.nodes("AXButton").first)
        XCTAssertEqual(delete.label, "Delete", "not the symbol's own name")
        XCTAssertEqual(delete.help, "Delete this row")
    }

    func testWithoutAResolverThereIsNoVariableMark() {
        let model = Model()
        model.pair.value = "{{host}}"
        let hosting = ViewHosting.host(RowHost(model: model), size: CGSize(width: 500, height: 40))
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(hosting.nodes("AXImage").isEmpty)
    }

    func testAVariableMarkExplainsWhatTheRowsVariablesResolveTo() throws {
        let model = Model()
        model.pair = KeyValuePair(key: "X-{{missing}}", value: "https://{{host}}/v1")
        let hosting = ViewHosting.host(RowHost(model: model, resolver: resolver), size: CGSize(width: 500, height: 40))
        defer { ViewHosting.close(hosting) }
        let mark = try XCTUnwrap(hosting.nodes("AXImage").first)
        XCTAssertEqual(mark.help, "missing is not defined, so it is sent as written.\nhost = api.example.com  (Default)")
    }
}

@MainActor
final class KeyValueEditorViewTests: XCTestCase {
    func testAddAppendsAnEmptyEnabledPair() throws {
        let model = Model()
        let hosting = ViewHosting.host(EditorHost(model: model), size: CGSize(width: 500, height: 200))
        defer { ViewHosting.close(hosting) }
        let add = try XCTUnwrap(hosting.nodes("AXButton").first { $0.label == "Add" })
        add.press()
        add.press()
        ViewHosting.settle()
        XCTAssertEqual(model.pairs.count, 2)
        XCTAssertTrue(model.pairs.allSatisfy { $0.key.isEmpty && $0.value.isEmpty && $0.isEnabled })
        XCTAssertNotEqual(model.pairs[0].id, model.pairs[1].id)
        XCTAssertEqual(hosting.nodes("AXCheckBox").count, 2)
    }

    func testDeletingARowRemovesThatPairOnly() throws {
        let model = Model()
        model.pairs = [KeyValuePair(key: "A", value: "1"), KeyValuePair(key: "B", value: "2"), KeyValuePair(key: "C", value: "3")]
        let hosting = ViewHosting.host(EditorHost(model: model), size: CGSize(width: 500, height: 200))
        defer { ViewHosting.close(hosting) }
        let deletes = hosting.nodes("AXButton").filter { $0.label != "Add" }
        XCTAssertEqual(deletes.count, 3)
        deletes[1].press()
        ViewHosting.settle()
        XCTAssertEqual(model.pairs.map(\.key), ["A", "C"])
        XCTAssertEqual(hosting.nodes("AXTextField").compactMap { $0.strings.last }, ["A", "1", "C", "3"])
    }

    func testEmptyFieldsShowTheEditorsPlaceholders() throws {
        let model = Model()
        model.pairs = [KeyValuePair(key: "", value: "")]
        let hosting = ViewHosting.host(EditorHost(model: model), size: CGSize(width: 500, height: 200))
        defer { ViewHosting.close(hosting) }
        let placeholders = hosting.nodes("AXTextField").map { $0.object.value(forKey: "accessibilityPlaceholderValue") as? String }
        XCTAssertEqual(placeholders, ["Header", "Content"])
    }
}

@MainActor
final class VariableStatusMarkTests: XCTestCase {
    func testNoMarkForTextsWithoutVariables() {
        XCTAssertNil(VariableStatusMark.status(texts: ["plain", "", "{ not a variable }"], resolver: resolver))
    }

    func testDefinedVariablesGetTheInfoMark() throws {
        let status = try XCTUnwrap(VariableStatusMark.status(texts: ["{{host}}", "{{host}}/x"], resolver: resolver))
        XCTAssertFalse(status.hasMissing)
        XCTAssertEqual(status.symbol, "curlybraces")
        XCTAssertEqual(status.help, "host = api.example.com  (Default)", "each variable is described once")
    }

    func testAnyUndefinedVariableGetsTheWarningMark() throws {
        let status = try XCTUnwrap(VariableStatusMark.status(texts: ["{{host}}", "{{token}}"], resolver: resolver))
        XCTAssertTrue(status.hasMissing)
        XCTAssertEqual(status.symbol, "exclamationmark.triangle.fill")
        XCTAssertTrue(status.help.contains("token is not defined"))
    }

    func testTheMarkSaysInWordsWhetherAVariableIsMissing() throws {
        for (texts, label) in [(["{{host}}"], "Variables"), (["{{host}}", "{{token}}"], "Undefined variables")] {
            let hosting = ViewHosting.host(VariableStatusMark(texts: texts, resolver: resolver), size: CGSize(width: 40, height: 20))
            XCTAssertEqual(hosting.nodes("AXImage").first?.label, label, "\(texts)")
            ViewHosting.close(hosting)
        }
    }

    func testTheMarkKeepsItsPlaceWhenThereAreNoVariables() {
        let hosting = ViewHosting.host(VariableStatusMark(texts: ["plain"], resolver: resolver), size: CGSize(width: 40, height: 20))
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(hosting.nodes("AXImage").isEmpty)
        XCTAssertEqual(hosting.fittingSize.width, 16, accuracy: 0.5)
    }
}

// MARK: - Empty state

@MainActor
final class EmptyStateViewTests: XCTestCase {
    func testExplainsWhatToDoInLightAndDark() {
        for appearance in appearances {
            let hosting = ViewHosting.host(EmptyStateView(), size: CGSize(width: 600, height: 400), appearance: appearance)
            XCTAssertTrue(hosting.allStrings.contains("No Request Selected"))
            XCTAssertTrue(hosting.allStrings.contains("Select a request from the sidebar or create a new one to get started."))
            XCTAssertEqual(ViewHosting.buttonLabels(in: hosting), ["New Request", "New Folder"])
            ViewHosting.close(hosting)
        }
    }

    func testItsButtonsAskForANewRequestAndANewFolder() {
        let hosting = ViewHosting.host(EmptyStateView(), size: CGSize(width: 600, height: 400))
        defer { ViewHosting.close(hosting) }
        for (label, name) in [("New Request", Notification.Name.createNewRequest), ("New Folder", .createNewFolder)] {
            let posted = expectation(forNotification: name, object: nil)
            hosting.nodes("AXButton").first { $0.label == label }?.press()
            wait(for: [posted], timeout: 1)
        }
    }

    func testTheDecorativeArrowsAreNotReadOut() {
        let hosting = ViewHosting.host(EmptyStateView(), size: CGSize(width: 600, height: 400))
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(hosting.nodes("AXImage").isEmpty, "\(hosting.nodes("AXImage"))")
    }

    func testFitsANarrowPane() {
        let hosting = ViewHosting.host(EmptyStateView(), size: CGSize(width: 320, height: 300))
        defer { ViewHosting.close(hosting) }
        XCTAssertEqual(ViewHosting.buttonLabels(in: hosting), ["New Request", "New Folder"])
        XCTAssertLessThanOrEqual(hosting.fittingSize.width, 320)
    }
}

// MARK: - Code editor

@MainActor
final class CodeTextEditorViewTests: XCTestCase {
    private func host(_ model: Model, appearance: NSAppearance.Name = .aqua) throws -> (NSHostingView<AnyView>, NSTextView) {
        let hosting = ViewHosting.host(CodeHost(model: model), size: CGSize(width: 400, height: 300), appearance: appearance)
        return (hosting, try XCTUnwrap(hosting.firstSubview(of: NSTextView.self)))
    }

    func testEveryAutomaticSubstitutionIsOff() throws {
        let (hosting, textView) = try host(Model())
        defer { ViewHosting.close(hosting) }
        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(textView.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(textView.isAutomaticTextCompletionEnabled)
        XCTAssertFalse(textView.isAutomaticLinkDetectionEnabled)
        XCTAssertFalse(textView.isAutomaticDataDetectionEnabled)
        XCTAssertFalse(textView.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(textView.isGrammarCheckingEnabled)
        XCTAssertFalse(textView.smartInsertDeleteEnabled)
        XCTAssertFalse(textView.isRichText)
        XCTAssertTrue(textView.allowsUndo)
        XCTAssertTrue(textView.usesFindBar)
    }

    func testTypedQuotesAndDashesStayPlain() throws {
        let model = Model()
        let (hosting, textView) = try host(model)
        defer { ViewHosting.close(hosting) }
        textView.insertText(#"{"a": "--"}"#, replacementRange: NSRange(location: 0, length: 0))
        ViewHosting.settle()
        XCTAssertEqual(model.text, #"{"a": "--"}"#)
    }

    func testTheBindingAndTheTextViewStayInStep() throws {
        let model = Model()
        model.text = "first"
        let (hosting, textView) = try host(model)
        defer { ViewHosting.close(hosting) }
        XCTAssertEqual(textView.string, "first")
        model.text = "second\nline"
        ViewHosting.settle()
        XCTAssertEqual(textView.string, "second\nline")
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertText("!", replacementRange: textView.selectedRange())
        ViewHosting.settle()
        XCTAssertEqual(model.text, "second\nline!")
    }

    func testReplacingTheTextKeepsTheSelectionInsideIt() throws {
        let model = Model()
        model.text = "a long first body"
        let (hosting, textView) = try host(model)
        defer { ViewHosting.close(hosting) }
        textView.setSelectedRange(NSRange(location: 10, length: 7))
        model.text = "short"
        ViewHosting.settle()
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 5, length: 0))
    }

    func testTheLineNumberGutterIsAttachedAndFollowsTheText() throws {
        let model = Model()
        model.text = "one"
        let (hosting, textView) = try host(model)
        defer { ViewHosting.close(hosting) }
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        let ruler = try XCTUnwrap(scrollView.verticalRulerView as? LineNumberRulerView)
        XCTAssertTrue(scrollView.rulersVisible)
        XCTAssertTrue(ruler.clientView === textView)
        let narrow = ruler.ruleThickness
        model.text = (1...1_000).map(String.init).joined(separator: "\n")
        ViewHosting.settle()
        XCTAssertGreaterThan(ruler.ruleThickness, narrow, "four-digit line numbers need a wider gutter")
    }

    func testAFontChangeReachesTheTextView() throws {
        let model = Model()
        let (hosting, textView) = try host(model)
        defer { ViewHosting.close(hosting) }
        model.fontSize = 18
        ViewHosting.settle()
        XCTAssertEqual(textView.font?.pointSize, 18)
    }

    func testJSONColorsFollowTheSetting() throws {
        let model = Model()
        model.text = #"{"key": 1}"#
        let (hosting, textView) = try host(model)
        defer { ViewHosting.close(hosting) }
        let storage = try XCTUnwrap(textView.textStorage)
        XCTAssertTrue(storage.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor === CodePalette.text)
        model.highlightsJSON = true
        ViewHosting.settle()
        XCTAssertTrue(storage.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor === CodePalette.key)
    }

    func testIsATextAreaForVoiceOverInLightAndDark() throws {
        for appearance in appearances {
            let model = Model()
            model.text = "body"
            let (hosting, _) = try host(model, appearance: appearance)
            XCTAssertEqual(hosting.nodes("AXTextArea").first?.strings.last, "body")
            ViewHosting.close(hosting)
        }
    }

    func testTheGutterDrawsAnEmptyText() throws {
        let (hosting, textView) = try host(Model())
        defer { ViewHosting.close(hosting) }
        let ruler = try XCTUnwrap(textView.enclosingScrollView?.verticalRulerView)
        let bitmap = try XCTUnwrap(ruler.bitmapImageRepForCachingDisplay(in: ruler.bounds))
        ruler.cacheDisplay(in: ruler.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
    }
}
