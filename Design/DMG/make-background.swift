// Renders the DMG window background (660x400 pt) at 1x and 2x:
//   swift Design/DMG/make-background.swift Design/DMG
// Icon centres (180,170) and (480,170) must match scripts/make-dmg.sh.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let size = NSSize(width: 660, height: 400)

func render(scale: CGFloat, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGradient(starting: NSColor(srgbRed: 0.975, green: 0.975, blue: 0.965, alpha: 1), ending: NSColor(srgbRed: 0.925, green: 0.93, blue: 0.915, alpha: 1))!
        .draw(in: NSRect(origin: .zero, size: size), angle: -90)
    // Finder uses top-left coordinates; AppKit is bottom-left.
    let y = size.height - 170
    let arrow = NSBezierPath(); arrow.lineWidth = 5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 275, y: y)); arrow.line(to: NSPoint(x: 385, y: y))
    arrow.move(to: NSPoint(x: 365, y: y + 16)); arrow.line(to: NSPoint(x: 387, y: y)); arrow.line(to: NSPoint(x: 365, y: y - 16))
    NSColor(srgbRed: 1.0, green: 0.38, blue: 0.984, alpha: 0.85).setStroke(); arrow.stroke()
    let style = NSMutableParagraphStyle(); style.alignment = .center
    let text = NSAttributedString(string: "Drag PostWoman to Applications to install",
        attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor(white: 0.35, alpha: 1), .paragraphStyle: style])
    text.draw(in: NSRect(x: 0, y: 70, width: size.width, height: 24))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

render(scale: 1, to: "\(out)/background.png")
render(scale: 2, to: "\(out)/background@2x.png")
