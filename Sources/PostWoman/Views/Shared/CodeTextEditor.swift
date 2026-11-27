import AppKit
import SwiftUI

/// A plain-text editor for code (JSON, XML, raw bodies).
///
/// SwiftUI's `TextEditor` follows the system text-substitution settings, so it turns `"` into
/// curly quotes and `--` into dashes, which breaks JSON. This editor disables every automatic
/// substitution and correction.
struct CodeTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    /// Colors JSON tokens like the response body does.
    var highlightsJSON = false

    /// Larger texts are left uncolored so typing stays responsive.
    private static let highlightLimit = 200_000

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    /// Recolors the whole text: plain text color, then JSON token colors when enabled.
    static func applyHighlighting(to textView: NSTextView, enabled: Bool) {
        guard let storage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: fullRange)
        if enabled, storage.length <= highlightLimit {
            JSONHighlighter.colorize(storage)
        }
        storage.endEditing()
        textView.typingAttributes[.foregroundColor] = NSColor.textColor
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        // TextKit 1, which the line-number gutter reads.
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        scrollView.documentView = textView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = font
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false

        textView.string = text
        scrollView.verticalRulerView = LineNumberRulerView(textView: textView, textFont: font)
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        (scrollView.verticalRulerView as? LineNumberRulerView)?.textDidChange()
        context.coordinator.highlightsJSON = highlightsJSON
        Self.applyHighlighting(to: textView, enabled: highlightsJSON)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView else { return }
        var needsHighlighting = context.coordinator.highlightsJSON != highlightsJSON
        context.coordinator.highlightsJSON = highlightsJSON
        if textView.font != font {
            textView.font = font
        }
        if textView.string != text {
            let selection = textView.selectedRanges
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            // While the user is editing (e.g. Prettify), make the change undoable; otherwise
            // (another request was selected) replace the text and drop the old undo history.
            if textView.window?.firstResponder === textView,
                textView.shouldChangeText(in: fullRange, replacementString: text)
            {
                textView.replaceCharacters(in: fullRange, with: text)
                textView.didChangeText()
            } else {
                textView.string = text
                textView.undoManager?.removeAllActions(withTarget: textView.textStorage ?? textView)
            }
            let length = (text as NSString).length
            textView.selectedRanges = selection.map { value in
                let range = value.rangeValue
                let location = min(range.location, length)
                return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
            }
            needsHighlighting = true
            (scrollView.verticalRulerView as? LineNumberRulerView)?.textDidChange()
        }
        if needsHighlighting {
            Self.applyHighlighting(to: textView, enabled: highlightsJSON)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var highlightsJSON = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            CodeTextEditor.applyHighlighting(to: textView, enabled: highlightsJSON)
            (textView.enclosingScrollView?.verticalRulerView as? LineNumberRulerView)?.textDidChange()
            text.wrappedValue = textView.string
        }
    }
}
