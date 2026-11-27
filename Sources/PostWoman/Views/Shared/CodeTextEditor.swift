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

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = font
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 0, height: 2)

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
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView else { return }
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
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
