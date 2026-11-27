import AppKit
import Observation
import os

/// One color theme: the app's surfaces, status colors and JSON syntax colors, as sRGB hex values.
/// The bundled themes are in `ThemeCatalog.swift`.
struct ThemePalette: Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let isDark: Bool
    /// The editor and response panes.
    let background: UInt32
    /// The request list and history column, and the Settings sidebar.
    let sidebar: UInt32
    /// Tab bars and toolbars inside the panes.
    let surface: UInt32
    /// Text areas and other inset fields, and the line-number gutter.
    let field: UInt32
    /// Hairlines around fields and cards.
    let border: UInt32
    /// Small chips and unselected pills.
    let chip: UInt32
    let foreground: UInt32
    let muted: UInt32
    /// The theme's own accent, used when the accent setting is Theme.
    let accent: UInt32
    let success: UInt32
    let warning: UInt32
    let info: UInt32
    let failure: UInt32
    /// The request phase in the Timing tab.
    let cyan: UInt32
    let key: UInt32
    let string: UInt32
    let number: UInt32
    let literal: UInt32
    let punctuation: UInt32
    let gutterBorder: UInt32
    let lineNumber: UInt32

    /// The bundled theme with this id, or the default (first) one for that appearance.
    static func light(id: String) -> ThemePalette { lightThemes.first { $0.id == id } ?? lightThemes[0] }
    static func dark(id: String) -> ThemePalette { darkThemes.first { $0.id == id } ?? darkThemes[0] }
}

/// Settings → Appearance's mode: follow macOS, or keep the app light or dark.
enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: Self { self }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    /// The appearance set on `NSApp`: nil follows macOS.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The accent color: PostWoman's pink by default, the current theme's own accent, or a fixed color.
enum AccentChoice: String, CaseIterable, Identifiable, Sendable {
    case pink, theme, violet, blue, teal, orange
    var id: Self { self }
    var title: String {
        switch self {
        case .pink: "Pink"
        case .theme: "Theme"
        case .violet: "Violet"
        case .blue: "Blue"
        case .teal: "Teal"
        case .orange: "Orange"
        }
    }
    func hex(in palette: ThemePalette) -> UInt32 {
        switch self {
        case .pink: 0xFF61FB
        case .theme: palette.accent
        case .violet: 0x9B7BFF
        case .blue: 0x3D8BFF
        case .teal: 0x1FBFA8
        case .orange: 0xFF8A3D
        }
    }
}

/// What AppKit-drawn views (code text, line numbers) read when they draw: the themes and accent in use.
struct ThemeSnapshot: Sendable, Equatable {
    var light: ThemePalette
    var dark: ThemePalette
    var accent: AccentChoice

    static let initial = ThemeSnapshot(light: ThemePalette.lightThemes[0], dark: ThemePalette.darkThemes[0], accent: .pink)

    func palette(for appearance: NSAppearance) -> ThemePalette {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
}

extension Notification.Name {
    /// Posted after the theme, accent or code font size changes, so AppKit views redraw.
    static let themeDidChange = Notification.Name("PostWoman.themeDidChange")
}

/// The appearance settings, saved in user defaults. SwiftUI views that read a `Theme` color read
/// this store, so they redraw when it changes.
@MainActor @Observable
final class ThemeStore {
    static let shared = ThemeStore(defaults: .standard, isShared: true)

    /// The shared store's themes, for dynamic `NSColor`s, which resolve while drawing on any thread.
    nonisolated static let current = OSAllocatedUnfairLock(initialState: ThemeSnapshot.initial)

    enum Key {
        static let mode = "appearanceMode"
        static let lightTheme = "lightTheme"
        static let darkTheme = "darkTheme"
        static let accent = "accentColor"
        static let codeFontSize = "codeFontSize"
    }

    static let codeFontSizeRange: ClosedRange<Double> = 10...20
    static let defaultCodeFontSize: Double = 12

    var mode: AppearanceMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Key.mode)
            applyAppearance()
        }
    }
    var lightThemeID: String {
        didSet {
            defaults.set(lightThemeID, forKey: Key.lightTheme)
            publish()
        }
    }
    var darkThemeID: String {
        didSet {
            defaults.set(darkThemeID, forKey: Key.darkTheme)
            publish()
        }
    }
    var accent: AccentChoice {
        didSet {
            defaults.set(accent.rawValue, forKey: Key.accent)
            publish()
        }
    }
    var codeFontSize: Double {
        didSet {
            let clamped = min(max(codeFontSize, Self.codeFontSizeRange.lowerBound), Self.codeFontSizeRange.upperBound)
            if clamped != codeFontSize {
                codeFontSize = clamped
                return
            }
            defaults.set(codeFontSize, forKey: Key.codeFontSize)
            publish()
        }
    }
    /// Bumped on every change, so AppKit views know to redraw.
    private(set) var revision = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isShared: Bool

    init(defaults: UserDefaults, isShared: Bool = false) {
        self.defaults = defaults
        self.isShared = isShared
        mode = defaults.string(forKey: Key.mode).flatMap(AppearanceMode.init(rawValue:)) ?? .system
        lightThemeID = ThemePalette.light(id: defaults.string(forKey: Key.lightTheme) ?? "").id
        darkThemeID = ThemePalette.dark(id: defaults.string(forKey: Key.darkTheme) ?? "").id
        accent = defaults.string(forKey: Key.accent).flatMap(AccentChoice.init(rawValue:)) ?? .pink
        let size = defaults.double(forKey: Key.codeFontSize)
        codeFontSize = Self.codeFontSizeRange.contains(size) ? size : Self.defaultCodeFontSize
        if isShared {
            let initial = snapshot
            Self.current.withLock { $0 = initial }
        }
    }

    var light: ThemePalette { ThemePalette.light(id: lightThemeID) }
    var dark: ThemePalette { ThemePalette.dark(id: darkThemeID) }
    var snapshot: ThemeSnapshot { ThemeSnapshot(light: light, dark: dark, accent: accent) }
    var codeFont: NSFont { .monospacedSystemFont(ofSize: codeFontSize, weight: .regular) }

    /// Sets the whole app's appearance from `mode`. Called at launch and on every change.
    func applyAppearance() {
        guard isShared else { return }
        NSApp?.appearance = mode.nsAppearance
    }

    private func publish() {
        revision += 1
        guard isShared else { return }
        let snapshot = snapshot
        Self.current.withLock { $0 = snapshot }
        NotificationCenter.default.post(name: .themeDidChange, object: nil)
    }
}
