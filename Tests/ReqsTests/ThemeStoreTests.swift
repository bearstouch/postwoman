import AppKit
import XCTest

@testable import Reqs

final class ThemeStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ThemeStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testCatalogHasUniqueIDsAndMatchingAppearances() {
        let all = ThemePalette.lightThemes + ThemePalette.darkThemes
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertTrue(ThemePalette.lightThemes.allSatisfy { !$0.isDark })
        XCTAssertTrue(ThemePalette.darkThemes.allSatisfy(\.isDark))
        XCTAssertEqual(ThemePalette.lightThemes.first?.id, "postwoman-light")
        XCTAssertEqual(ThemePalette.darkThemes.first?.id, "postwoman-dark")
    }

    /// Body text and JSON colors stay readable on each theme's fields (WCAG AA for normal text).
    func testThemeTextIsReadable() {
        for theme in ThemePalette.lightThemes + ThemePalette.darkThemes {
            for (label, color) in [("foreground", theme.foreground), ("key", theme.key), ("string", theme.string)] {
                let ratio = contrast(color, theme.field)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(theme.id) \(label) on field: \(ratio)")
            }
            XCTAssertGreaterThanOrEqual(contrast(theme.foreground, theme.background), 4.5, theme.id)
        }
    }

    @MainActor
    func testDefaultsWhenNothingIsSaved() {
        let store = ThemeStore(defaults: defaults)
        XCTAssertEqual(store.mode, .system)
        XCTAssertEqual(store.light.id, "postwoman-light")
        XCTAssertEqual(store.dark.id, "postwoman-dark")
        XCTAssertEqual(store.accent, .blue)
        XCTAssertEqual(store.codeFontSize, ThemeStore.defaultCodeFontSize)
    }

    @MainActor
    func testChangesAreSavedAndReloaded() {
        let store = ThemeStore(defaults: defaults)
        store.mode = .dark
        store.lightThemeID = "nord-light"
        store.darkThemeID = "tokyo-dark"
        store.accent = .theme
        store.codeFontSize = 15

        let reloaded = ThemeStore(defaults: defaults)
        XCTAssertEqual(reloaded.mode, .dark)
        XCTAssertEqual(reloaded.light.name, "Nord")
        XCTAssertEqual(reloaded.dark.name, "Tokyo")
        XCTAssertEqual(reloaded.accent, .theme)
        XCTAssertEqual(reloaded.codeFontSize, 15)
    }

    @MainActor
    func testUnknownSavedValuesFallBackToDefaults() {
        defaults.set("sepia", forKey: ThemeStore.Key.mode)
        defaults.set("removed-theme", forKey: ThemeStore.Key.lightTheme)
        defaults.set("removed-theme", forKey: ThemeStore.Key.darkTheme)
        defaults.set("chartreuse", forKey: ThemeStore.Key.accent)
        defaults.set(99.0, forKey: ThemeStore.Key.codeFontSize)
        let store = ThemeStore(defaults: defaults)
        XCTAssertEqual(store.mode, .system)
        XCTAssertEqual(store.lightThemeID, "postwoman-light")
        XCTAssertEqual(store.darkThemeID, "postwoman-dark")
        XCTAssertEqual(store.accent, .blue)
        XCTAssertEqual(store.codeFontSize, ThemeStore.defaultCodeFontSize)
    }

    @MainActor
    func testAPinkAccentChosenBeforeTheRenameIsKept() {
        defaults.set("pink", forKey: ThemeStore.Key.accent)
        XCTAssertEqual(ThemeStore(defaults: defaults).accent, .pink)
    }

    @MainActor
    func testCodeFontSizeIsClamped() {
        let store = ThemeStore(defaults: defaults)
        store.codeFontSize = 40
        XCTAssertEqual(store.codeFontSize, ThemeStore.codeFontSizeRange.upperBound)
        store.codeFontSize = 2
        XCTAssertEqual(store.codeFontSize, ThemeStore.codeFontSizeRange.lowerBound)
    }

    func testThemeAccentUsesEachThemesOwnAccent() {
        let nord = ThemePalette.light(id: "nord-light")
        XCTAssertEqual(AccentChoice.theme.hex(in: nord), nord.accent)
        XCTAssertEqual(AccentChoice.pink.hex(in: nord), 0xFF61FB)
    }

    func testSnapshotPicksPaletteForAppearance() {
        let snapshot = ThemeSnapshot(
            light: ThemePalette.light(id: "github-light"), dark: ThemePalette.dark(id: "dracula-dark"), accent: .pink)
        XCTAssertEqual(snapshot.palette(for: NSAppearance(named: .aqua)!).id, "github-light")
        XCTAssertEqual(snapshot.palette(for: NSAppearance(named: .darkAqua)!).id, "dracula-dark")
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            func channel(_ shift: UInt32) -> Double {
                let c = Double((hex >> shift) & 0xFF) / 255
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        }
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
