import AppKit
import XCTest

@testable import Reqs

/// WCAG 2 relative luminance of an sRGB color.
private func relativeLuminance(_ hex: UInt32) -> Double {
    func channel(_ shift: UInt32) -> Double {
        let c = Double((hex >> shift) & 0xFF) / 255
        return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
}

/// WCAG 2 contrast ratio of two sRGB colors.
private func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
    let (la, lb) = (relativeLuminance(a), relativeLuminance(b))
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

/// Every color of a palette, by property name.
private func colors(of palette: ThemePalette) -> [(String, UInt32)] {
    Mirror(reflecting: palette).children.compactMap { child in
        guard let label = child.label, let value = child.value as? UInt32 else { return nil }
        return (label, value)
    }
}

final class ThemeCatalogTests: XCTestCase {
    private let all = ThemePalette.lightThemes + ThemePalette.darkThemes

    func testThemeNamesAreUniqueWithinEachAppearance() {
        for themes in [ThemePalette.lightThemes, ThemePalette.darkThemes] {
            XCTAssertEqual(Set(themes.map(\.name)).count, themes.count)
            XCTAssertTrue(themes.allSatisfy { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty })
        }
    }

    func testEveryFamilyHasALightAndADarkThemeInTheSameOrder() {
        XCTAssertEqual(ThemePalette.lightThemes.map(\.name), ThemePalette.darkThemes.map(\.name))
        for (light, dark) in zip(ThemePalette.lightThemes, ThemePalette.darkThemes) {
            XCTAssertTrue(light.id.hasSuffix("-light"), light.id)
            XCTAssertTrue(dark.id.hasSuffix("-dark"), dark.id)
            XCTAssertEqual(light.id.dropLast("-light".count), dark.id.dropLast("-dark".count))
        }
    }

    func testIDsAreLowercaseSlugsSafeToPersist() {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for theme in all {
            XCTAssertTrue(theme.id.unicodeScalars.allSatisfy(allowed.contains), theme.id)
        }
    }

    func testEveryColorIsAnOpaque24BitSRGBValue() {
        for theme in all {
            let values = colors(of: theme)
            XCTAssertEqual(values.count, 21, "\(theme.id): every color property is read")
            for (label, value) in values {
                XCTAssertLessThanOrEqual(value, 0xFFFFFF, "\(theme.id).\(label)")
            }
        }
    }

    /// The catalog promises syntax colors nudged to read at 4.5:1 on the field (WCAG AA for normal text).
    func testEverySyntaxColorIsReadableOnTheField() {
        for theme in all {
            let syntax = [("key", theme.key), ("string", theme.string), ("number", theme.number), ("literal", theme.literal), ("punctuation", theme.punctuation)]
            for (label, color) in syntax {
                let ratio = contrastRatio(color, theme.field)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(theme.id) \(label) on field: \(ratio)")
            }
            XCTAssertGreaterThanOrEqual(contrastRatio(theme.muted, theme.field), 4.5, "\(theme.id) muted on field")
        }
    }

    func testBodyTextIsReadableOnEverySurface() {
        for theme in all {
            for (label, surface) in [("sidebar", theme.sidebar), ("surface", theme.surface), ("field", theme.field), ("background", theme.background)] {
                let ratio = contrastRatio(theme.foreground, surface)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(theme.id) foreground on \(label): \(ratio)")
            }
        }
    }

    func testLightThemesAreLightAndDarkThemesAreDark() {
        for theme in all {
            let backgroundIsLighter = relativeLuminance(theme.background) > relativeLuminance(theme.foreground)
            XCTAssertEqual(backgroundIsLighter, !theme.isDark, theme.id)
        }
    }

    func testLookupFindsEveryBundledThemeByID() {
        for theme in ThemePalette.lightThemes { XCTAssertEqual(ThemePalette.light(id: theme.id), theme) }
        for theme in ThemePalette.darkThemes { XCTAssertEqual(ThemePalette.dark(id: theme.id), theme) }
    }

    func testLookupNeverCrossesAppearances() {
        XCTAssertEqual(ThemePalette.light(id: "dracula-dark").id, "postwoman-light")
        XCTAssertEqual(ThemePalette.dark(id: "dracula-light").id, "postwoman-dark")
        XCTAssertEqual(ThemePalette.light(id: "").id, "postwoman-light")
        XCTAssertEqual(ThemePalette.dark(id: "Nord-Dark").id, "postwoman-dark", "ids match exactly")
    }

    func testHexColorsConvertToSRGBComponents() throws {
        let color = try XCTUnwrap(NSColor(hex: 0xFF61FB, alpha: 0.5).usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, 1, accuracy: 0.0001)
        XCTAssertEqual(color.greenComponent, CGFloat(0x61) / 255, accuracy: 0.0001)
        XCTAssertEqual(color.blueComponent, CGFloat(0xFB) / 255, accuracy: 0.0001)
        XCTAssertEqual(color.alphaComponent, 0.5, accuracy: 0.0001)
        XCTAssertEqual(NSColor(hex: 0x000000).alphaComponent, 1)
    }

    func testAccentChoicesAreDistinctAndThemeFollowsEachPalette() {
        let fixed = AccentChoice.allCases.filter { $0 != .theme }.map { $0.hex(in: ThemePalette.lightThemes[0]) }
        XCTAssertEqual(Set(fixed).count, fixed.count)
        XCTAssertTrue(fixed.allSatisfy { $0 <= 0xFFFFFF })
        for theme in all {
            XCTAssertEqual(AccentChoice.theme.hex(in: theme), theme.accent, theme.id)
            XCTAssertEqual(AccentChoice.pink.hex(in: theme), 0xFF61FB, "fixed accents ignore the theme")
            XCTAssertEqual(AccentChoice.blue.hex(in: theme), theme.isDark ? 0x5B8CFF : 0x2A64F6, "blue is lighter on dark themes")
        }
    }

    func testPersistedRawValuesStayStable() {
        XCTAssertEqual(AppearanceMode.allCases.map(\.rawValue), ["system", "light", "dark"])
        XCTAssertEqual(AccentChoice.allCases.map(\.rawValue), ["blue", "pink", "theme", "violet", "teal", "orange"])
        XCTAssertEqual(
            [ThemeStore.Key.mode, ThemeStore.Key.lightTheme, ThemeStore.Key.darkTheme, ThemeStore.Key.accent, ThemeStore.Key.codeFontSize],
            ["appearanceMode", "lightTheme", "darkTheme", "accentColor", "codeFontSize"])
        XCTAssertEqual(AccentChoice.allCases.map(\.title), ["Blue", "Pink", "Theme", "Violet", "Teal", "Orange"])
        XCTAssertEqual(AppearanceMode.allCases.map(\.title), ["System", "Light", "Dark"])
    }

    func testAppearanceModesMapToAppKitAppearances() {
        XCTAssertNil(AppearanceMode.system.nsAppearance, "System follows macOS")
        XCTAssertEqual(AppearanceMode.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(AppearanceMode.dark.nsAppearance?.name, .darkAqua)
    }
}
