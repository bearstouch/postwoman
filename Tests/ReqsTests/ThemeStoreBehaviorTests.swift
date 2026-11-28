import AppKit
import XCTest

@testable import Reqs

/// The sRGB hex value a (possibly dynamic) color resolves to in an appearance.
private func resolvedHex(_ color: NSColor, in name: NSAppearance.Name) -> UInt32? {
    var hex: UInt32?
    NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
        guard let rgb = color.usingColorSpace(.sRGB) else { return }
        func byte(_ value: CGFloat) -> UInt32 { UInt32((value * 255).rounded()) }
        hex = byte(rgb.redComponent) << 16 | byte(rgb.greenComponent) << 8 | byte(rgb.blueComponent)
    }
    return hex
}

/// Counts notifications; they are posted synchronously on the posting thread.
private final class NotificationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

@MainActor
final class ThemeStoreBehaviorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "ThemeStoreBehaviorTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testChangesAreWrittenUnderTheirKeys() {
        let store = ThemeStore(defaults: defaults)
        store.mode = .light
        store.lightThemeID = "solarized-light"
        store.darkThemeID = "gruvbox-dark"
        store.accent = .teal
        store.codeFontSize = 17
        XCTAssertEqual(defaults.string(forKey: ThemeStore.Key.mode), "light")
        XCTAssertEqual(defaults.string(forKey: ThemeStore.Key.lightTheme), "solarized-light")
        XCTAssertEqual(defaults.string(forKey: ThemeStore.Key.darkTheme), "gruvbox-dark")
        XCTAssertEqual(defaults.string(forKey: ThemeStore.Key.accent), "teal")
        XCTAssertEqual(defaults.double(forKey: ThemeStore.Key.codeFontSize), 17)
    }

    func testNothingIsWrittenUntilSomethingChanges() {
        _ = ThemeStore(defaults: defaults)
        for key in [ThemeStore.Key.mode, ThemeStore.Key.lightTheme, ThemeStore.Key.darkTheme, ThemeStore.Key.accent, ThemeStore.Key.codeFontSize] {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
    }

    func testEveryThemeAccentOrFontChangeBumpsTheRevision() {
        let store = ThemeStore(defaults: defaults)
        XCTAssertEqual(store.revision, 0)
        store.lightThemeID = "nord-light"
        XCTAssertEqual(store.revision, 1)
        store.darkThemeID = "nord-dark"
        XCTAssertEqual(store.revision, 2)
        store.accent = .violet
        XCTAssertEqual(store.revision, 3)
        store.codeFontSize = 13
        XCTAssertEqual(store.revision, 4)
    }

    func testAClampedFontSizeIsSavedClamped() {
        let store = ThemeStore(defaults: defaults)
        store.codeFontSize = 99
        XCTAssertEqual(defaults.double(forKey: ThemeStore.Key.codeFontSize), ThemeStore.codeFontSizeRange.upperBound)
        XCTAssertEqual(ThemeStore(defaults: defaults).codeFontSize, ThemeStore.codeFontSizeRange.upperBound)
        store.codeFontSize = -5
        XCTAssertEqual(ThemeStore(defaults: defaults).codeFontSize, ThemeStore.codeFontSizeRange.lowerBound)
    }

    func testSavedFontSizesAtTheLimitsLoadAndOutsideFallBack() {
        defaults.set(10.0, forKey: ThemeStore.Key.codeFontSize)
        XCTAssertEqual(ThemeStore(defaults: defaults).codeFontSize, 10)
        defaults.set(20.0, forKey: ThemeStore.Key.codeFontSize)
        XCTAssertEqual(ThemeStore(defaults: defaults).codeFontSize, 20)
        defaults.set(9.5, forKey: ThemeStore.Key.codeFontSize)
        XCTAssertEqual(ThemeStore(defaults: defaults).codeFontSize, ThemeStore.defaultCodeFontSize)
        defaults.set("big", forKey: ThemeStore.Key.codeFontSize)
        XCTAssertEqual(ThemeStore(defaults: defaults).codeFontSize, ThemeStore.defaultCodeFontSize)
    }

    func testAThemeSavedForTheOtherAppearanceFallsBack() {
        defaults.set("dracula-dark", forKey: ThemeStore.Key.lightTheme)
        defaults.set("dracula-light", forKey: ThemeStore.Key.darkTheme)
        let store = ThemeStore(defaults: defaults)
        XCTAssertEqual(store.lightThemeID, "postwoman-light")
        XCTAssertEqual(store.darkThemeID, "postwoman-dark")
        XCTAssertFalse(store.light.isDark)
        XCTAssertTrue(store.dark.isDark)
    }

    func testEveryBundledThemeSurvivesARelaunch() {
        for (light, dark) in zip(ThemePalette.lightThemes, ThemePalette.darkThemes) {
            let store = ThemeStore(defaults: defaults)
            store.lightThemeID = light.id
            store.darkThemeID = dark.id
            let reloaded = ThemeStore(defaults: defaults)
            XCTAssertEqual(reloaded.light, light)
            XCTAssertEqual(reloaded.dark, dark)
        }
    }

    func testSnapshotAndCodeFontFollowTheChoices() {
        let store = ThemeStore(defaults: defaults)
        store.lightThemeID = "one-light"
        store.darkThemeID = "monokai-dark"
        store.accent = .orange
        store.codeFontSize = 16
        XCTAssertEqual(store.snapshot, ThemeSnapshot(light: ThemePalette.light(id: "one-light"), dark: ThemePalette.dark(id: "monokai-dark"), accent: .orange))
        XCTAssertEqual(store.codeFont.pointSize, 16)
        XCTAssertTrue(store.codeFont.isFixedPitch)
    }

    func testAPrivateStoreNeitherPublishesNorTouchesTheSharedThemes() {
        let before = ThemeStore.current.withLock { $0 }
        let notifications = NotificationCount()
        let observer = NotificationCenter.default.addObserver(forName: .themeDidChange, object: nil, queue: nil) { _ in notifications.add() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let appearance = NSApp?.appearance

        let store = ThemeStore(defaults: defaults)
        store.lightThemeID = "github-light"
        store.accent = .blue
        store.mode = .dark

        XCTAssertEqual(notifications.value, 0)
        XCTAssertEqual(ThemeStore.current.withLock { $0 }, before)
        XCTAssertEqual(NSApp?.appearance, appearance, "only the shared store sets the app's appearance")
    }

    func testInitialSnapshotIsTheDefaultPair() {
        XCTAssertEqual(ThemeSnapshot.initial.light.id, "postwoman-light")
        XCTAssertEqual(ThemeSnapshot.initial.dark.id, "postwoman-dark")
        XCTAssertEqual(ThemeSnapshot.initial.accent, .blue)
    }

    func testHighContrastAppearancesPickTheMatchingPalette() throws {
        let snapshot = ThemeSnapshot(light: ThemePalette.light(id: "nord-light"), dark: ThemePalette.dark(id: "nord-dark"), accent: .pink)
        let darkHC = try XCTUnwrap(NSAppearance(named: .accessibilityHighContrastDarkAqua))
        let lightHC = try XCTUnwrap(NSAppearance(named: .accessibilityHighContrastAqua))
        XCTAssertEqual(snapshot.palette(for: darkHC).id, "nord-dark")
        XCTAssertEqual(snapshot.palette(for: lightHC).id, "nord-light")
    }

    func testCodeColorsResolveFromTheSharedThemesForEachAppearance() {
        let saved = ThemeStore.current.withLock { $0 }
        defer { ThemeStore.current.withLock { $0 = saved } }
        let light = ThemePalette.light(id: "solarized-light")
        let dark = ThemePalette.dark(id: "dracula-dark")
        ThemeStore.current.withLock { $0 = ThemeSnapshot(light: light, dark: dark, accent: .pink) }

        XCTAssertEqual(resolvedHex(CodePalette.key, in: .aqua), light.key)
        XCTAssertEqual(resolvedHex(CodePalette.key, in: .darkAqua), dark.key)
        XCTAssertEqual(resolvedHex(CodePalette.text, in: .darkAqua), dark.foreground)
        XCTAssertEqual(resolvedHex(CodePalette.variable, in: .aqua), light.cyan)
        XCTAssertEqual(resolvedHex(CodePalette.gutterBackground, in: .aqua), light.field)
        XCTAssertEqual(resolvedHex(CodePalette.lineNumber, in: .darkAqua), dark.lineNumber)
        XCTAssertEqual(resolvedHex(CodePalette.border, in: .darkAqua), dark.border)

        let next = ThemePalette.dark(id: "monokai-dark")
        ThemeStore.current.withLock { $0.dark = next }
        XCTAssertEqual(resolvedHex(CodePalette.string, in: .darkAqua), next.string, "the same color object follows a theme change")
    }
}
