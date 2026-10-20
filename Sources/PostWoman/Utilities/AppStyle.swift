import AppKit
import SwiftUI

extension Color {
    /// PostWoman's pink accent. SwiftPM builds have no asset catalog, so it is applied with `.tint`
    /// at each scene root and used directly where views previously read `Color.accentColor`.
    static let postWomanPink = Color(.sRGB, red: 1.0, green: 0.380, blue: 0.984)

    /// A color that follows the window's appearance: `light` in Aqua, `dark` in Dark Aqua.
    fileprivate static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            })
    }
}

extension NSColor {
    fileprivate convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// The app's surfaces and semantic colors. Light mode keeps the system look; dark mode uses
/// near-black neutral greys with hairline borders and the pink accent, like Trellis.
enum Theme {
    /// The request list and history column.
    static let listBackground = Color.adaptive(light: .white, dark: NSColor(hex: 0x0E0E11))
    /// The editor and response panes.
    static let canvas = Color.adaptive(light: .windowBackgroundColor, dark: NSColor(hex: 0x121216))
    /// Tab bars and toolbars inside the panes.
    static let bar = Color.adaptive(light: .controlBackgroundColor, dark: NSColor(hex: 0x17171C))
    /// Text areas and other inset fields.
    static let field = Color.adaptive(light: .textBackgroundColor, dark: NSColor(hex: 0x0B0B0E))
    /// Borders around inset fields and cards.
    static let hairline = Color.adaptive(light: NSColor(white: 0, alpha: 0.1), dark: NSColor(hex: 0x2E2F38))
    /// Small chips and unselected pills.
    static let chip = Color.adaptive(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(hex: 0x23232A))
    /// The selected tab's fill.
    static let selection = Color.adaptive(
        light: NSColor(srgbRed: 1, green: 0.38, blue: 0.984, alpha: 0.15),
        dark: NSColor(srgbRed: 1, green: 0.38, blue: 0.984, alpha: 0.16))
    /// Glow under the pink accent in dark mode; nothing in light mode.
    static let accentGlow = Color.adaptive(light: .clear, dark: NSColor(srgbRed: 1, green: 0.38, blue: 0.984, alpha: 0.45))

    /// The code export terminal, dark in both appearances.
    static let terminal = Color(nsColor: NSColor(hex: 0x08090A))
    static let terminalBar = Color(nsColor: NSColor(hex: 0x17171C))
    static let terminalText = Color(nsColor: NSColor(hex: 0x9CFF62))

    /// Status colors: the system palette in light mode, softer tones that read well on near-black in dark mode.
    static let success = Color.adaptive(light: .systemGreen, dark: NSColor(hex: 0x5FD38D))
    static let warning = Color.adaptive(light: .systemOrange, dark: NSColor(hex: 0xF5A35C))
    static let info = Color.adaptive(light: .systemBlue, dark: NSColor(hex: 0x7AA2FF))
    static let failure = Color.adaptive(light: .systemRed, dark: NSColor(hex: 0xFF6B6B))
    static let neutral = Color.adaptive(light: .systemGray, dark: NSColor(hex: 0x8F91A3))

    /// The color for an HTTP status code: 2xx green, 3xx orange, 4xx and 5xx red.
    static func status(_ code: Int) -> Color {
        switch code {
        case 200..<300: return success
        case 300..<400: return warning
        case 400..<600: return failure
        default: return neutral
        }
    }
}
