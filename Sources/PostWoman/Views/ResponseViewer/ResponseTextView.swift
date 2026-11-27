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

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    /// Bodies larger than this (UTF-16 units) are shown without colors or hanging indents.
    private static let styledLimit = 1_000_000

    final class Coordinator {
        var text: String?
        var highlightsJSON = false
        var wrapsLines: Bool?
        var findRequest = 0
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

        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        // Only later increments open the find bar.
        context.coordinator.findRequest = findRequest
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator

        if coordinator.wrapsLines != wrapsLines {
            coordinator.wrapsLines = wrapsLines
            Self.applyWrapping(wrapsLines, to: textView, in: scrollView)
        }

        if coordinator.text != text || coordinator.highlightsJSON != highlightsJSON {
            coordinator.text = text
            coordinator.highlightsJSON = highlightsJSON
            textView.textStorage?.setAttributedString(Self.attributedText(text, highlightsJSON: highlightsJSON))
            textView.scroll(.zero)
            (scrollView.verticalRulerView as? LineNumberRulerView)?.textDidChange()
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
    static func attributedText(_ text: String, highlightsJSON: Bool) -> NSAttributedString {
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
            for token in JSONHighlighter.tokens(in: text) {
                result.addAttribute(.foregroundColor, value: color(for: token.kind), range: token.range)
            }
        }
        return result
    }

    private static func color(for kind: JSONHighlighter.Kind) -> NSColor {
        switch kind {
        case .key: return CodePalette.key
        case .string: return CodePalette.string
        case .number: return CodePalette.number
        case .literal: return CodePalette.literal
        case .punctuation: return CodePalette.punctuation
        }
    }
}

/// Draws line numbers beside an `NSTextView`, one per logical line (not per wrapped fragment).
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    /// UTF-16 offset where each line starts.
    private var lineStarts: [Int] = [0]
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        clipsToBounds = true
        ruleThickness = 40

        NotificationCenter.default.addObserver(
            self, selector: #selector(setNeedsRedraw), name: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(setNeedsRedraw), name: NSView.frameDidChangeNotification, object: textView)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    @objc private func setNeedsRedraw() {
        needsDisplay = true
    }

    func textDidChange() {
        let string = (textView?.string ?? "") as NSString
        var starts = [0]
        var location = 0
        while location < string.length {
            let lineEnd = NSMaxRange(string.lineRange(for: NSRange(location: location, length: 0)))
            if lineEnd < string.length { starts.append(lineEnd) }
            location = lineEnd
        }
        lineStarts = starts

        let digits = CGFloat(String(starts.count).count)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: numberFont]).width
        ruleThickness = max(36, ceil(digits * digitWidth + 22))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Views don't clip to their bounds by default since macOS 14, and dirtyRect can reach past them.
        let dirty = dirtyRect.intersection(bounds)
        CodePalette.gutterBackground.setFill()
        dirty.fill()
        CodePalette.gutterBorder.setFill()
        NSRect(x: bounds.maxX - 1, y: dirty.minY, width: 1, height: dirty.height).fill()

        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let string = textView.string as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: CodePalette.lineNumber]
        let origin = textView.textContainerOrigin
        let textLineHeight = layoutManager.defaultLineHeight(for: ResponseTextView.font)

        func drawNumber(_ number: Int, atTextY y: CGFloat) {
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            let point = convert(NSPoint(x: 0, y: y + origin.y), from: textView)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 10, y: point.y + (textLineHeight - size.height) / 2), withAttributes: attributes)
        }

        guard string.length > 0 else {
            drawNumber(1, atTextY: 0)
            return
        }

        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // The last line starting at or before the first visible character.
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= charRange.location { low = mid } else { high = mid - 1 }
        }

        var line = low
        while line < lineStarts.count, lineStarts[line] <= NSMaxRange(charRange), lineStarts[line] < string.length {
            let glyph = layoutManager.glyphIndexForCharacter(at: lineStarts[line])
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
            drawNumber(line + 1, atTextY: fragment.minY)
            line += 1
        }
    }
}
