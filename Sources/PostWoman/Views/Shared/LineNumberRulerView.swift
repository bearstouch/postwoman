import AppKit

/// Draws line numbers beside an `NSTextView`, one per logical line (not per wrapped fragment).
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    /// UTF-16 offset where each line starts.
    private var lineStarts: [Int] = [0]
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    /// The text view's font, to center numbers on its lines.
    private let textFont: NSFont

    init(textView: NSTextView, textFont: NSFont) {
        self.textView = textView
        self.textFont = textFont
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
        let textLineHeight = layoutManager.defaultLineHeight(for: textFont)

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
