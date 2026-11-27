import AppKit
import SwiftUI

/// A read-only code view for response bodies: line numbers, JSON syntax colors, optional line
/// wrapping (wrapped lines keep their indentation) and the standard find bar.
struct ResponseTextView: NSViewRepresentable {
    let text: String
    var highlightsJSON: Bool
    var wrapsLines: Bool
    /// Increment to open the find bar.
    var findRequest: Int = 0
    /// When the text changes and the view was scrolled to the end, keep the end in view (a stream arriving).
    var followsEnd = false

    /// The code font (Settings → Appearance → Code text).
    var font: NSFont = .monospacedSystemFont(ofSize: ThemeStore.defaultCodeFontSize, weight: .regular)
    /// `ThemeStore.revision`: a change redraws the text in the new theme colors.
    var themeRevision = 0
    /// Bodies larger than this (UTF-16 units) are shown without colors or hanging indents.
    private static let styledLimit = 1_000_000

    final class Coordinator {
        var text: String?
        var highlightsJSON = false
        var wrapsLines: Bool?
        var findRequest = 0
        var font: NSFont?
        var themeRevision = 0
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textContainer?.lineFragmentPadding = 0
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView

        let ruler = LineNumberRulerView(textView: textView, textFont: font)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        // Only later increments open the find bar.
        context.coordinator.findRequest = findRequest
        context.coordinator.themeRevision = themeRevision
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator

        if coordinator.wrapsLines != wrapsLines {
            coordinator.wrapsLines = wrapsLines
            Self.applyWrapping(wrapsLines, to: textView, in: scrollView)
        }

        let fontChanged = coordinator.font != font
        if coordinator.text != text || coordinator.highlightsJSON != highlightsJSON || fontChanged {
            let textChanged = coordinator.text != text
            // A stream's text only grows; keep the reader's place instead of jumping back to the top.
            let appended = coordinator.text.map { !$0.isEmpty && text.hasPrefix($0) } ?? false
            let wasAtEnd = scrollView.contentView.bounds.maxY >= textView.frame.height - 24
            coordinator.text = text
            coordinator.highlightsJSON = highlightsJSON
            coordinator.font = font
            textView.textStorage?.setAttributedString(Self.attributedText(text, highlightsJSON: highlightsJSON, font: font))
            if fontChanged { (scrollView.verticalRulerView as? LineNumberRulerView)?.setTextFont(font) }
            if textChanged {
                if followsEnd, wasAtEnd {
                    textView.scrollToEndOfDocument(nil)
                } else if !appended {
                    textView.scroll(.zero)
                }
            }
            (scrollView.verticalRulerView as? LineNumberRulerView)?.textDidChange()
        }

        if coordinator.themeRevision != themeRevision {
            coordinator.themeRevision = themeRevision
            textView.needsDisplay = true
            scrollView.verticalRulerView?.needsDisplay = true
        }

        if coordinator.findRequest != findRequest {
            coordinator.findRequest = findRequest
            textView.window?.makeFirstResponder(textView)
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            textView.performTextFinderAction(item)
        }
    }

    private static func applyWrapping(_ wraps: Bool, to textView: NSTextView, in scrollView: NSScrollView) {
        guard let container = textView.textContainer else { return }
        scrollView.hasHorizontalScroller = !wraps
        textView.isHorizontallyResizable = !wraps
        container.widthTracksTextView = wraps
        if wraps {
            textView.autoresizingMask = [.width]
            textView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: textView.frame.height))
            container.containerSize = NSSize(
                width: scrollView.contentSize.width - textView.textContainerInset.width * 2, height: CGFloat.greatestFiniteMagnitude)
        } else {
            textView.autoresizingMask = []
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.sizeToFit()
        }
    }

    /// The body as styled text: the code font, JSON colors when asked, and a hanging indent per
    /// line so wrapped lines line up under their own text.
    static func attributedText(_ text: String, highlightsJSON: Bool, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: CodePalette.text])
        let length = result.length
        guard length > 0, length <= styledLimit else { return result }

        let string = text as NSString
        let indentUnit = ("0" as NSString).size(withAttributes: [.font: font]).width
        var location = 0
        while location < length {
            let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
            var leading = 0
            while leading < lineRange.length, string.character(at: lineRange.location + leading) == 0x20 { leading += 1 }
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            style.headIndent = CGFloat(leading + 2) * indentUnit
            result.addAttribute(.paragraphStyle, value: style, range: lineRange)
            location = NSMaxRange(lineRange)
        }

        if highlightsJSON {
            JSONHighlighter.colorize(result)
        }
        return result
    }

}
