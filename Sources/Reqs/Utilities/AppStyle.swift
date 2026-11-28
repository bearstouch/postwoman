import AppKit
import SwiftUI

extension Color {
    /// The accent from Settings → Appearance (electric blue by default). SwiftPM builds have no asset
    /// catalog, so it is applied with `.tint` at each scene root (`themedScene()`) and used directly where
    /// views would read `Color.accentColor`.
    @MainActor static var appAccent: Color { Theme.accent }

    /// A color that follows the window's appearance: `light` in Aqua, `dark` in Dark Aqua.
    fileprivate static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension View {
    /// Fills the dividers of the split view that contains this view (a `NavigationSplitView` column, or a
    /// `VSplitView` pane) with the theme's border color. On current macOS split views draw nothing in their
    /// 1 pt dividers, so whatever is behind the window shows through.
    func themedSplitDividers() -> some View { background(ThemedSplitDividers(revision: ThemeStore.shared.revision)) }

    /// The accent tint every scene root gets. A view of its own, so it redraws when the accent changes.
    func themedScene() -> some View { modifier(ThemedScene()) }
}

/// Colors the layer of the nearest enclosing `NSSplitView` and makes its divider views (and the sidebar's 1 pt
/// edge) transparent, so every divider shows the theme's border color. `revision` redraws it after a theme change.
private struct ThemedSplitDividers: NSViewRepresentable {
    let revision: Int

    func makeNSView(context: Context) -> FillView { FillView() }
    func updateNSView(_ nsView: FillView, context: Context) { nsView.apply() }

    final class FillView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // SwiftUI adds the split view's subviews after this view joins the window.
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            apply()
        }

        func apply() {
            guard let splitView = sequence(first: superview, next: { $0?.superview }).lazy.compactMap({ $0 as? NSSplitView }).first
            else { return }
            splitView.wantsLayer = true
            var color: CGColor?
            splitView.effectiveAppearance.performAsCurrentDrawingAppearance { color = CodePalette.border.cgColor }
            splitView.layer?.backgroundColor = color
            for view in splitView.subviews.flatMap({ [$0] + $0.subviews }) {
                if String(describing: type(of: view)).hasSuffix("SplitDividerView") {
                    // The divider views draw the system color over the layer. Transparent, not hidden, so they
                    // still take the drags that resize the columns.
                    view.alphaValue = 0
                } else if view is NSVisualEffectView, view.frame.width <= 1 {
                    view.isHidden = true  // the sidebar's edge line
                }
            }
        }
    }
}

/// Internal, not private: SwiftUI names window autosave keys after the root view's type, and a private
/// type's name includes an address that changes with every build.
struct ThemedScene: ViewModifier {
    func body(content: Content) -> some View { content.tint(Color.appAccent) }
}

/// The app's surfaces and semantic colors, from the light and dark themes chosen in Settings → Appearance.
/// Each color follows the window's appearance, and reading one inside a view's body makes that view
/// redraw when the theme changes (the colors read `ThemeStore.shared`, which is observable).
@MainActor
enum Theme {
    private static func color(_ value: (ThemePalette) -> UInt32) -> Color {
        let store = ThemeStore.shared
        return .adaptive(light: NSColor(hex: value(store.light)), dark: NSColor(hex: value(store.dark)))
    }

    private static func accentColor(alpha light: CGFloat, _ dark: CGFloat) -> Color {
        let store = ThemeStore.shared
        return .adaptive(
            light: NSColor(hex: store.accent.hex(in: store.light), alpha: light),
            dark: NSColor(hex: store.accent.hex(in: store.dark), alpha: dark))
    }

    /// A JSON syntax color, for SwiftUI previews of code (AppKit code views use `CodePalette`).
    static func syntax(_ value: (ThemePalette) -> UInt32) -> Color { color(value) }

    /// The accent color.
    static var accent: Color { accentColor(alpha: 1, 1) }
    /// The request list and history column.
    static var listBackground: Color { color(\.sidebar) }
    /// The editor and response panes.
    static var canvas: Color { color(\.background) }
    /// Tab bars and toolbars inside the panes.
    static var bar: Color { color(\.surface) }
    /// Text areas and other inset fields.
    static var field: Color { color(\.field) }
    /// Borders around inset fields and cards.
    static var hairline: Color { color(\.border) }
    /// Small chips and unselected pills.
    static var chip: Color { color(\.chip) }
    /// The selected tab's fill.
    static var selection: Color { accentColor(alpha: 0.15, 0.18) }
    /// Glow under the accent in dark mode; nothing in light mode.
    static var accentGlow: Color { accentColor(alpha: 0, 0.45) }

    /// The Pink environment color: fixed, since the accent is no longer pink by default.
    static let pink = Color(nsColor: NSColor(hex: AccentChoice.pinkHex))

    /// The code export terminal, dark in every theme.
    static let terminal = Color(nsColor: NSColor(hex: 0x08090A))
    static let terminalBar = Color(nsColor: NSColor(hex: 0x17171C))
    static let terminalText = Color(nsColor: NSColor(hex: 0x9CFF62))

    /// Status colors.
    static var success: Color { color(\.success) }
    static var warning: Color { color(\.warning) }
    static var info: Color { color(\.info) }
    static var failure: Color { color(\.failure) }
    static var neutral: Color { color(\.muted) }

    /// Phase colors in the response Timing tab.
    static var phaseDNS: Color { neutral }
    static var phaseConnect: Color { warning }
    static var phaseTLS: Color { info }
    static var phaseRequest: Color { color(\.cyan) }
    static var phaseWaiting: Color { accent }
    static var phaseDownload: Color { success }

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

/// AppKit colors for the code views (request body, response body): syntax colors and the line-number
/// gutter from the current themes. They resolve each time they are drawn, so a view only needs a redraw
/// when the theme changes (see `Notification.Name.themeDidChange`).
enum CodePalette {
    private static func themed(_ value: @escaping @Sendable (ThemePalette) -> UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(hex: value(ThemeStore.current.withLock { $0 }.palette(for: appearance)))
        }
    }

    static let key = themed { $0.key }
    static let string = themed { $0.string }
    static let number = themed { $0.number }
    static let literal = themed { $0.literal }
    static let punctuation = themed { $0.punctuation }
    static let text = themed { $0.foreground }
    /// `{{variables}}` in a request body.
    static let variable = themed { $0.cyan }
    /// Hairlines AppKit draws, such as split view dividers.
    static let border = themed { $0.border }

    /// The line-number gutter: the same fill as `Theme.field`, a hairline on its right edge.
    static let gutterBackground = themed { $0.field }
    static let gutterBorder = themed { $0.gutterBorder }
    static let lineNumber = themed { $0.lineNumber }
}

/// A one-point horizontal line in the theme's border color. Use it instead of `Divider()`, which draws in
/// the system separator color whatever the theme.
struct HairlineDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1).frame(maxWidth: .infinity)
    }
}

/// A text field on the theme's field color with a hairline border, instead of `.roundedBorder`'s system bezel.
struct ThemedTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).modifier(ThemedFieldFrame())
    }
}

/// The frame of a themed field. A view modifier, so it reads the theme on the main actor.
private struct ThemedFieldFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.hairline))
    }
}

extension TextFieldStyle where Self == ThemedTextFieldStyle {
    /// A text field framed in the theme's colors.
    static var themed: ThemedTextFieldStyle { ThemedTextFieldStyle() }
}

/// Turns off the window's titlebar separator, which AppKit draws in the system color: the panes draw their own
/// hairline under the toolbar. Put it in a window's content as a background.
struct ThemedWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // The split views are set up after this view joins the window.
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        private func apply() {
            guard let window else { return }
            window.titlebarSeparatorStyle = .none
            guard let root = window.contentView?.superview ?? window.contentView else { return }
            Self.removeTitlebarSeparators(in: root)
        }

        /// Split view controllers set a titlebar separator per column, which overrides the window's.
        private static func removeTitlebarSeparators(in view: NSView) {
            if let splitView = view as? NSSplitView, let controller = splitView.delegate as? NSSplitViewController {
                for item in controller.splitViewItems { item.titlebarSeparatorStyle = .none }
            }
            for subview in view.subviews { removeTitlebarSeparators(in: subview) }
        }
    }
}
