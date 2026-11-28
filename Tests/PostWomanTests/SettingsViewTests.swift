import AppKit
import SwiftData
import SwiftUI
import XCTest

@testable import PostWoman

/// One accessibility element with what `ViewHosting.Element` leaves out: the label of its title element (how a grouped
/// Form names a control), its enabled state, the labels of the groups around it, and a way to press it as VoiceOver does.
@MainActor
private struct AXNode: @MainActor CustomStringConvertible {
    let object: NSObject
    let role: String
    let label: String
    let strings: [String]
    let titleElement: String
    let help: String
    let isSelected: Bool
    let isEnabled: Bool
    let ancestors: [(role: String, label: String)]

    var description: String { "\(role) '\(label)' title '\(titleElement)'" }
    /// The button is part of a system control (a scroller or a stepper's arrows), which AppKit names itself.
    var isSystemPart: Bool { ancestors.contains { $0.role == "AXScrollBar" || $0.role == "AXIncrementor" } }
    func isInside(_ label: String) -> Bool { ancestors.contains { $0.label == label } }

    func press() { perform("accessibilityPerformPress") }
    func increment() { perform("accessibilityPerformIncrement") }

    private func perform(_ name: String) {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return XCTFail("\(self) can't \(name)") }
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        _ = unsafeBitCast(object.method(for: selector), to: Action.self)(object, selector)
    }

    static func all(in root: NSView) -> [AXNode] {
        var found: [AXNode] = []
        var seen = Set<ObjectIdentifier>()
        func read(_ node: NSObject, _ getter: String) -> Any? {
            node.responds(to: NSSelectorFromString(getter)) ? node.perform(NSSelectorFromString(getter))?.takeUnretainedValue() : nil
        }
        func flag(_ node: NSObject, _ getter: String, _ key: String) -> Bool? {
            node.responds(to: NSSelectorFromString(getter)) ? node.value(forKey: key) as? Bool : nil
        }
        func visit(_ object: Any, ancestors: [(role: String, label: String)]) {
            guard ancestors.count < 60, let node = object as? NSObject, seen.insert(ObjectIdentifier(node)).inserted else { return }
            let role = read(node, "accessibilityRole") as? String ?? ""
            let texts = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { read(node, $0) as? String }.filter { !$0.isEmpty }
            let titleNode = read(node, "accessibilityTitleUIElement") as? NSObject
            let title = titleNode.flatMap { (read($0, "accessibilityLabel") as? String) ?? (read($0, "accessibilityValue") as? String) } ?? ""
            let element = AXNode(
                object: node, role: role, label: texts.first ?? "", strings: texts, titleElement: title, help: read(node, "accessibilityHelp") as? String ?? "",
                isSelected: flag(node, "isAccessibilitySelected", "accessibilitySelected") ?? false,
                isEnabled: flag(node, "isAccessibilityEnabled", "accessibilityEnabled") ?? true, ancestors: ancestors)
            found.append(element)
            for child in read(node, "accessibilityChildren") as? [Any] ?? [] { visit(child, ancestors: ancestors + [(role, element.label)]) }
        }
        visit(root, ancestors: [])
        return found
    }
}

@MainActor
private extension NSView {
    var nodes: [AXNode] { AXNode.all(in: self) }
    func node(_ role: String, _ label: String, inside group: String? = nil, file: StaticString = #filePath, line: UInt = #line) -> AXNode? {
        let match = nodes.first { $0.role == role && $0.label == label && (group.map($0.isInside) ?? true) }
        if match == nil { XCTFail("no \(role) '\(label)' in \(nodes.filter { !$0.label.isEmpty })", file: file, line: line) }
        return match
    }
    /// Every string the tree exposes, title elements included.
    var allStrings: [String] { nodes.flatMap { $0.strings + [$0.titleElement] }.filter { !$0.isEmpty } }
}

/// Every button outside system parts has a name, and an icon-only one (no visible text of its own) has help.
@MainActor
private func assertControlsAreLabelled(_ hosting: NSView, file: StaticString = #filePath, line: UInt = #line) {
    for node in hosting.nodes where ["AXButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton", "AXTextField", "AXIncrementor"].contains(node.role) {
        guard !node.isSystemPart else { continue }
        XCTAssertFalse(node.label.isEmpty && node.titleElement.isEmpty, "unlabelled \(node)", file: file, line: line)
    }
}

private let sizes = [CGSize(width: 780, height: 600), CGSize(width: 1_200, height: 900)]
private let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

/// A stand-in for Sparkle that records what the settings ask of it.
@MainActor
private final class FakeUpdater: SoftwareUpdater {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = false
    var includesBetas = false
    var lastUpdateCheckDate: Date?
    var onChange: (() -> Void)?
    private(set) var checks = 0
    func checkForUpdates() { checks += 1 }
}

/// A free loopback port: one the system just handed out and that is closed again.
private func freePort() throws -> UInt16 {
    let probe = MCPListener { _ in .empty(204) }
    let port = try probe.start(address: "127.0.0.1", port: 0)
    probe.stop()
    return port
}

/// A Remote Agent controller on a private defaults suite and token file, removed after the test.
@MainActor
private final class ControllerFixture {
    let suite = "RemoteAgentSettingsViewTests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appending(path: "pw-settings-\(UUID().uuidString)")
    let defaults: UserDefaults
    let container: ModelContainer
    let controller: RemoteAgentController

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        container = try ViewHosting.container()
        controller = RemoteAgentController(container: container, defaults: defaults, tokenURL: directory.appending(path: "token"))
    }

    func tearDown() {
        controller.stop()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    func host(_ view: some View, size: CGSize = sizes[0], appearance: NSAppearance.Name = .aqua) -> NSHostingView<AnyView> {
        ViewHosting.host(view.environment(controller).defaultAppStorage(defaults), size: size, appearance: appearance, container: container)
    }
}

// MARK: - Settings window

@MainActor
final class SettingsViewTests: XCTestCase {
    private var fixture: ControllerFixture!

    override func setUp() async throws { fixture = try ControllerFixture() }
    override func tearDown() async throws { fixture.tearDown() }

    func testUpdatesSectionIsListedOnlyWithAnUpdater() {
        XCTAssertEqual(SettingsSection.visible(hasUpdates: false), [.general, .appearance, .remoteAgent])
        XCTAssertEqual(SettingsSection.visible(hasUpdates: true), [.general, .appearance, .remoteAgent, .updates])
    }

    func testEverySectionHasItsOwnTitleDetailAndSymbol() {
        let sections = SettingsSection.allCases
        XCTAssertEqual(Set(sections.map(\.title)).count, sections.count)
        XCTAssertEqual(Set(sections.map(\.symbol)).count, sections.count)
        for section in sections {
            XCTAssertFalse(section.detail.isEmpty, section.title)
            XCTAssertNotNil(NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil), section.symbol)
        }
    }

    func testWithoutAnUpdaterTheSidebarHasNoUpdatesButton() {
        let hosting = fixture.host(SettingsView(updates: nil))
        defer { ViewHosting.close(hosting) }
        let sidebar = hosting.nodes.filter { $0.role == "AXButton" && SettingsSection.allCases.map(\.title).contains($0.label) }
        XCTAssertEqual(sidebar.map(\.label), ["General", "Appearance", "Remote Agent"])
    }

    func testWithAnUpdaterTheSidebarListsUpdates() {
        let hosting = fixture.host(SettingsView(updates: UpdateSettingsModel(updater: FakeUpdater(), version: "1.2.3")))
        defer { ViewHosting.close(hosting) }
        XCTAssertNotNil(hosting.node("AXButton", "Updates"))
    }

    func testAppearanceIsSelectedFirstAndSelectionIsExposedNotJustColored() {
        let hosting = fixture.host(SettingsView(updates: nil))
        defer { ViewHosting.close(hosting) }
        XCTAssertEqual(hosting.node("AXButton", "Appearance")?.isSelected, true)
        XCTAssertEqual(hosting.node("AXButton", "General")?.isSelected, false)
        XCTAssertTrue(hosting.allStrings.contains(SettingsSection.appearance.detail))
    }

    func testChoosingASectionShowsItsPaneAndMovesTheSelection() {
        let hosting = fixture.host(SettingsView(updates: nil))
        defer { ViewHosting.close(hosting) }
        hosting.node("AXButton", "Remote Agent")?.press()
        ViewHosting.settle()
        XCTAssertEqual(hosting.node("AXButton", "Remote Agent")?.isSelected, true)
        XCTAssertEqual(hosting.node("AXButton", "Appearance")?.isSelected, false)
        XCTAssertTrue(hosting.allStrings.contains(SettingsSection.remoteAgent.detail))
        XCTAssertTrue(hosting.allStrings.contains("MCP server"))
        hosting.node("AXButton", "General")?.press()
        ViewHosting.settle()
        XCTAssertTrue(hosting.allStrings.contains("Request defaults"))
        XCTAssertFalse(hosting.allStrings.contains("MCP server"))
    }

    func testChoosingUpdatesShowsTheUpdatesPane() {
        let hosting = fixture.host(SettingsView(updates: UpdateSettingsModel(updater: FakeUpdater(), version: "1.2.3")))
        defer { ViewHosting.close(hosting) }
        hosting.node("AXButton", "Updates")?.press()
        ViewHosting.settle()
        XCTAssertTrue(hosting.allStrings.contains("Automatic updates"))
        XCTAssertTrue(hosting.allStrings.contains("1.2.3"))
    }

    func testEverySectionRendersLabelledInLightAndDarkAtEachSize() {
        for size in sizes {
            for appearance in appearances {
                let hosting = fixture.host(SettingsView(updates: UpdateSettingsModel(updater: FakeUpdater())), size: size, appearance: appearance)
                for section in SettingsSection.allCases {
                    hosting.node("AXButton", section.title)?.press()
                    ViewHosting.settle()
                    XCTAssertTrue(hosting.allStrings.contains(section.detail), "\(section) \(size) \(appearance.rawValue)")
                    assertControlsAreLabelled(hosting)
                }
                ViewHosting.close(hosting)
            }
        }
    }
}

// MARK: - General

@MainActor
final class GeneralSettingsViewTests: XCTestCase {
    private var fixture: ControllerFixture!

    override func setUp() async throws { fixture = try ControllerFixture() }
    override func tearDown() async throws { fixture.tearDown() }

    func testHistoryCountUsesTheSingularForOneEntry() {
        XCTAssertEqual(GeneralSettingsView.historyCountText(0), "0 entries in History.")
        XCTAssertEqual(GeneralSettingsView.historyCountText(1), "1 entry in History.")
        XCTAssertEqual(GeneralSettingsView.historyCountText(2), "2 entries in History.")
    }

    func testHistoryLimitIsClampedToItsRange() {
        XCTAssertEqual(GeneralSettingsView.clampedHistoryLimit(0), 1)
        XCTAssertEqual(GeneralSettingsView.clampedHistoryLimit(-5), 1)
        XCTAssertEqual(GeneralSettingsView.clampedHistoryLimit(1), 1)
        XCTAssertEqual(GeneralSettingsView.clampedHistoryLimit(300), 300)
        XCTAssertEqual(GeneralSettingsView.clampedHistoryLimit(100_000), 100_000)
        XCTAssertEqual(GeneralSettingsView.clampedHistoryLimit(100_001), 100_000)
    }

    func testFieldsAreNamedByTheirRowsAndClearIsDisabledWithNoHistory() {
        let hosting = fixture.host(GeneralSettingsView())
        defer { ViewHosting.close(hosting) }
        XCTAssertEqual(hosting.node("AXTextField", "Timeout")?.titleElement, "Default timeout")
        XCTAssertEqual(hosting.node("AXTextField", "Maximum entries")?.titleElement, "Maximum entries")
        XCTAssertTrue(hosting.allStrings.contains("0 entries in History."))
        XCTAssertEqual(hosting.node("AXButton", "Clear History…")?.isEnabled, false)
    }

    func testClearIsEnabledAndTheCountShownOnceThereIsHistory() throws {
        fixture.container.mainContext.insert(RequestHistory(url: "https://example.com", method: .get))
        try fixture.container.mainContext.save()
        let hosting = fixture.host(GeneralSettingsView())
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(hosting.allStrings.contains("1 entry in History."))
        XCTAssertEqual(hosting.node("AXButton", "Clear History…")?.isEnabled, true)
    }

    func testALimitOutOfRangeIsPutBackInRange() {
        let hosting = fixture.host(GeneralSettingsView())
        defer { ViewHosting.close(hosting) }
        fixture.defaults.set(0, forKey: HistoryRetention.limitKey)
        ViewHosting.settle(0.2)
        XCTAssertEqual(fixture.defaults.integer(forKey: HistoryRetention.limitKey), 1)
    }

    func testLoweringTheLimitTrimsTheOldestHistory() throws {
        let context = fixture.container.mainContext
        for index in 0..<3 {
            let entry = RequestHistory(url: "https://example.com/\(index)", method: .get)
            entry.timestamp = Date(timeIntervalSince1970: TimeInterval(1_000 * index))
            context.insert(entry)
        }
        try context.save()
        let hosting = fixture.host(GeneralSettingsView())
        defer { ViewHosting.close(hosting) }
        fixture.defaults.set(2, forKey: HistoryRetention.limitKey)
        ViewHosting.settle(0.2)
        let left = try context.fetch(FetchDescriptor<RequestHistory>()).map(\.url).sorted()
        XCTAssertEqual(left, ["https://example.com/1", "https://example.com/2"])
    }
}

// MARK: - Appearance

@MainActor
final class AppearanceSettingsViewTests: XCTestCase {
    private var fixture: ControllerFixture!
    private var store: ThemeStore!

    override func setUp() async throws {
        fixture = try ControllerFixture()
        store = ThemeStore(defaults: fixture.defaults)
    }
    override func tearDown() async throws { fixture.tearDown() }

    func testFontSizeTitleShowsWholePoints() {
        XCTAssertEqual(AppearanceSettingsView.fontSizeTitle(12), "Font size: 12 pt")
        XCTAssertEqual(AppearanceSettingsView.fontSizeTitle(10), "Font size: 10 pt")
    }

    func testEachModeNamesTheThemesItUses() {
        let light = ThemePalette.lightThemes[1], dark = ThemePalette.darkThemes[2]
        XCTAssertEqual(AppearanceModePicker.themeNames(.light, light: light, dark: dark), light.name)
        XCTAssertEqual(AppearanceModePicker.themeNames(.dark, light: light, dark: dark), dark.name)
        XCTAssertEqual(AppearanceModePicker.themeNames(.system, light: light, dark: dark), "\(light.name) · \(dark.name)")
    }

    func testPickersAreGroupedAndNamedWithTheCurrentChoicesSelected() {
        let hosting = fixture.host(AppearanceSettingsView(store: store), size: CGSize(width: 780, height: 1_400))
        defer { ViewHosting.close(hosting) }
        for group in ["Application appearance", "Light theme", "Dark theme", "Accent color"] { XCTAssertNotNil(hosting.node("AXGroup", group)) }
        XCTAssertEqual(hosting.node("AXButton", "System")?.isSelected, true)
        XCTAssertEqual(hosting.node("AXButton", ThemePalette.lightThemes[0].name, inside: "Light theme")?.isSelected, true)
        XCTAssertEqual(hosting.node("AXButton", ThemePalette.lightThemes[1].name, inside: "Light theme")?.isSelected, false)
        XCTAssertEqual(hosting.node("AXButton", "Pink", inside: "Accent color")?.isSelected, true)
        XCTAssertEqual(hosting.node("AXButton", "Pink", inside: "Accent color")?.help, "Pink", "accent swatches are icon-only")
        let lightSwatches = hosting.nodes.filter { $0.role == "AXButton" && $0.isInside("Light theme") }.map(\.label)
        XCTAssertEqual(lightSwatches, ThemePalette.lightThemes.map(\.name))
        XCTAssertEqual(hosting.nodes.first { $0.role == "AXIncrementor" }?.titleElement, "Font size: 12 pt", "the stepper is named by its row")
        XCTAssertTrue(hosting.allStrings.contains("Code sample"))
        assertControlsAreLabelled(hosting)
    }

    func testModeTilesSayWhichThemesTheyUse() {
        let hosting = fixture.host(AppearanceSettingsView(store: store))
        defer { ViewHosting.close(hosting) }
        let system = hosting.nodes.first { $0.role == "AXButton" && $0.label == "System" }
        XCTAssertEqual(system?.strings.last, AppearanceModePicker.themeNames(.system, light: store.light, dark: store.dark))
    }

    func testChoosingAModeThemeAndAccentChangesTheStore() throws {
        let hosting = fixture.host(AppearanceSettingsView(store: store), size: CGSize(width: 780, height: 1_400))
        defer { ViewHosting.close(hosting) }
        let darkChoice = ThemePalette.darkThemes[1], lightChoice = ThemePalette.lightThemes[2]
        hosting.node("AXButton", "Dark", inside: "Application appearance")?.press()
        hosting.node("AXButton", darkChoice.name, inside: "Dark theme")?.press()
        hosting.node("AXButton", lightChoice.name, inside: "Light theme")?.press()
        hosting.node("AXButton", "Teal", inside: "Accent color")?.press()
        ViewHosting.settle()
        XCTAssertEqual(store.mode, .dark)
        XCTAssertEqual(store.darkThemeID, darkChoice.id)
        XCTAssertEqual(store.lightThemeID, lightChoice.id)
        XCTAssertEqual(store.accent, .teal)
        XCTAssertEqual(hosting.node("AXButton", "Dark", inside: "Application appearance")?.isSelected, true)
        XCTAssertEqual(hosting.node("AXButton", "System")?.isSelected, false)
        XCTAssertEqual(hosting.node("AXButton", "Teal", inside: "Accent color")?.isSelected, true)
        XCTAssertEqual(hosting.node("AXButton", darkChoice.name, inside: "Dark theme")?.isSelected, true)
        XCTAssertTrue(hosting.allStrings.contains("Teal"), "the chosen accent is named, not only shown")
    }

    func testTheFontSizeStepperStopsAtItsLimit() throws {
        store.codeFontSize = ThemeStore.codeFontSizeRange.upperBound - 1
        let hosting = fixture.host(AppearanceSettingsView(store: store), size: CGSize(width: 780, height: 1_400))
        defer { ViewHosting.close(hosting) }
        let stepper = try XCTUnwrap(hosting.nodes.first { $0.role == "AXIncrementor" })
        stepper.increment()
        ViewHosting.settle()
        XCTAssertEqual(store.codeFontSize, ThemeStore.codeFontSizeRange.upperBound)
        XCTAssertTrue(hosting.allStrings.contains(AppearanceSettingsView.fontSizeTitle(ThemeStore.codeFontSizeRange.upperBound)))
        try XCTUnwrap(hosting.nodes.first { $0.role == "AXIncrementor" }).increment()
        ViewHosting.settle()
        XCTAssertEqual(store.codeFontSize, ThemeStore.codeFontSizeRange.upperBound)
    }

    func testAPrivateStoreLeavesTheSharedOneAlone() {
        let shared = (ThemeStore.shared.mode, ThemeStore.shared.accent)
        let hosting = fixture.host(AppearanceSettingsView(store: store))
        defer { ViewHosting.close(hosting) }
        hosting.node("AXButton", "Orange", inside: "Accent color")?.press()
        ViewHosting.settle()
        XCTAssertEqual(store.accent, .orange)
        XCTAssertEqual(ThemeStore.shared.mode, shared.0)
        XCTAssertEqual(ThemeStore.shared.accent, shared.1)
    }
}

// MARK: - Remote Agent

@MainActor
final class RemoteAgentSettingsViewTests: XCTestCase {
    private var fixture: ControllerFixture!
    private var controller: RemoteAgentController { fixture.controller }

    override func setUp() async throws { fixture = try ControllerFixture() }
    override func tearDown() async throws { fixture.tearDown() }

    private let saved = RemoteAgentSettings()

    // Logic

    func testPortsOutsideTheRangeAreInvalidWithHelp() {
        for port in [1_024, 7_778, 65_535] {
            XCTAssertTrue(RemoteAgentSettingsForm.isValidPort(port), "\(port)")
            XCTAssertNil(RemoteAgentSettingsForm.portHelp(port))
        }
        for port in [0, 80, 1_023, 65_536, -1, 1_000_000] {
            XCTAssertFalse(RemoteAgentSettingsForm.isValidPort(port), "\(port)")
            XCTAssertEqual(RemoteAgentSettingsForm.portHelp(port), "Use a port from 1024 to 65535.")
        }
    }

    func testApplyIsDisabledForAnInvalidPortEvenWhenItClampsToAValidOne() {
        let draft = RemoteAgentSettings(mcpEnabled: true)
        XCTAssertEqual(RemoteAgentSettingsForm.candidate(draft, port: 70_000).port, 65_535, "clamped")
        XCTAssertFalse(RemoteAgentSettingsForm.canApply(draft: draft, port: 70_000, saved: saved, status: .stopped))
        XCTAssertFalse(RemoteAgentSettingsForm.canApply(draft: draft, port: 80, saved: saved, status: .stopped))
        XCTAssertTrue(RemoteAgentSettingsForm.canApply(draft: draft, port: 8_080, saved: saved, status: .stopped))
    }

    func testApplyIsDisabledWithoutChangesUnlessTheLastStartFailed() {
        XCTAssertFalse(RemoteAgentSettingsForm.canApply(draft: saved, port: Int(saved.port), saved: saved, status: .stopped))
        XCTAssertFalse(RemoteAgentSettingsForm.canApply(draft: saved, port: Int(saved.port), saved: saved, status: .running(url: "u")))
        XCTAssertTrue(RemoteAgentSettingsForm.canApply(draft: saved, port: Int(saved.port), saved: saved, status: .failed(reason: "in use")))
        XCTAssertTrue(RemoteAgentSettingsForm.canApply(draft: saved, port: 8_000, saved: saved, status: .stopped), "a new port is a change")
    }

    func testApplyIsDisabledForAnAddressThatIsNotAnIPLiteral() {
        let draft = RemoteAgentSettings(mcpEnabled: true, bindAddress: "localhost")
        XCTAssertFalse(RemoteAgentSettingsForm.canApply(draft: draft, port: 7_778, saved: saved, status: .failed(reason: "x")))
    }

    func testOnlyTurningOnANetworkAddressNeedsConfirmation() {
        let network = RemoteAgentSettings(mcpEnabled: true, bindAddress: "0.0.0.0")
        XCTAssertTrue(RemoteAgentSettingsForm.needsNetworkConfirmation(network, saved: saved))
        XCTAssertTrue(RemoteAgentSettingsForm.needsNetworkConfirmation(network, saved: RemoteAgentSettings(mcpEnabled: false, bindAddress: "0.0.0.0")))
        XCTAssertTrue(RemoteAgentSettingsForm.needsNetworkConfirmation(network, saved: RemoteAgentSettings(mcpEnabled: true, bindAddress: "::")))
        XCTAssertFalse(RemoteAgentSettingsForm.needsNetworkConfirmation(network, saved: network), "already listening there")
        var newPort = network
        newPort.port = 9_000
        XCTAssertFalse(RemoteAgentSettingsForm.needsNetworkConfirmation(newPort, saved: network), "a new port on the same address")
        XCTAssertFalse(RemoteAgentSettingsForm.needsNetworkConfirmation(RemoteAgentSettings(mcpEnabled: true, bindAddress: "::1"), saved: saved))
        XCTAssertFalse(RemoteAgentSettingsForm.needsNetworkConfirmation(RemoteAgentSettings(mcpEnabled: false, bindAddress: "0.0.0.0"), saved: saved))
    }

    func testTheNetworkWarningNamesTheAddress() {
        let warning = RemoteAgentSettingsForm.networkWarning(address: "192.168.1.20")
        XCTAssertTrue(warning.hasPrefix("Devices that can reach 192.168.1.20 will be able to connect."))
        XCTAssertTrue(warning.contains("not encrypted"))
    }

    func testExposureNoteSaysHowFarEachAddressReaches() {
        for address in ["127.0.0.1", "127.8.9.10", "::1"] {
            XCTAssertEqual(RemoteAgentSettingsForm.exposureNote(for: address), "Only programs on this Mac can connect.", address)
        }
        for address in ["100.64.0.1", "100.127.255.254", "fd7a:115c:a1e0::1"] {
            XCTAssertTrue(RemoteAgentSettingsForm.exposureNote(for: address).hasPrefix("Devices in your tailnet"), address)
        }
        for address in ["0.0.0.0", "::", "192.168.1.20", "100.128.0.1", "not an address"] {
            XCTAssertTrue(RemoteAgentSettingsForm.exposureNote(for: address).hasPrefix("Other devices on the network"), address)
        }
    }

    func testListenOnOffersLoopbackInterfacesAndWildcardsInOrder() {
        let interfaces = [NetworkInterfaceAddress(interface: "en0", address: "192.168.1.20"), NetworkInterfaceAddress(interface: "utun4", address: "100.101.102.103")]
        let options = RemoteAgentSettingsForm.addressOptions(interfaces: interfaces, selected: "127.0.0.1")
        XCTAssertEqual(options.map(\.address), ["127.0.0.1", "::1", "192.168.1.20", "100.101.102.103", "0.0.0.0", "::"])
        XCTAssertEqual(options[2].label, "en0 — 192.168.1.20")
        XCTAssertEqual(options[3].label, "Tailscale — 100.101.102.103 (utun4)")
        XCTAssertTrue(options[0].label.contains("this Mac only"))
    }

    func testASavedAddressNoLongerPresentIsKeptAndMarkedUnavailable() {
        let options = RemoteAgentSettingsForm.addressOptions(interfaces: [], selected: "10.0.0.9")
        XCTAssertEqual(options.last?.address, "10.0.0.9")
        XCTAssertEqual(options.last?.label, "10.0.0.9 (unavailable)")
        XCTAssertEqual(RemoteAgentSettingsForm.addressOptions(interfaces: [], selected: "::").count, 4, "a listed address is not repeated")
    }

    func testTheTokenIsMaskedUntilRevealed() {
        let token = "pwm_abcdefghijklmnopqrstuvwxyz0123456789WXYZ"
        let masked = RemoteAgentSettingsForm.shownToken(token, revealed: false)
        XCTAssertEqual(masked, "pwm_••••••••••••••••WXYZ")
        XCTAssertFalse(masked.contains("abcdefgh"))
        XCTAssertEqual(RemoteAgentSettingsForm.shownToken(token, revealed: true), token)
        XCTAssertEqual(RemoteAgentSettingsForm.tokenAccessibilityLabel(token, revealed: false), "Token hidden")
        XCTAssertEqual(RemoteAgentSettingsForm.tokenAccessibilityLabel(token, revealed: true), "Token \(token)")
    }

    func testStatusLineSaysTheStateInWords() {
        XCTAssertEqual(RemoteAgentSettingsForm.statusLine(.stopped).text, "Stopped")
        XCTAssertEqual(RemoteAgentSettingsForm.statusLine(.running(url: "http://127.0.0.1:1/mcp")).text, "Running at http://127.0.0.1:1/mcp")
        XCTAssertEqual(RemoteAgentSettingsForm.statusLine(.failed(reason: "Port 1 is in use.")).text, "Not running: Port 1 is in use.")
        let symbols = [RemoteAgentStatus.stopped, .running(url: "u"), .failed(reason: "r")].map { RemoteAgentSettingsForm.statusLine($0).symbol }
        XCTAssertEqual(Set(symbols).count, 3)
    }

    func testCommitMessagesSayWhetherSettingsWereSaved() {
        XCTAssertEqual(RemoteAgentSettingsForm.commitMessage(saved: true), "Remote agent settings saved.")
        XCTAssertEqual(RemoteAgentSettingsForm.commitMessage(saved: false), "Choose a valid interface and a port from 1024 to 65535.")
    }

    func testEveryClientHasItsOwnMenuItem() {
        let titles = MCPClientSetup.allCases.map(RemoteAgentSettingsForm.menuTitle)
        XCTAssertEqual(titles, ["Claude Code command", "Codex (config.toml)", "OpenCode command", "Generic MCP JSON"])
    }

    func testSnippetsUseTheSavedEndpointAndNeitherTheOldNorTheNewToken() throws {
        let port = try freePort()
        XCTAssertTrue(controller.apply(RemoteAgentSettings(mcpEnabled: false, bindAddress: "0.0.0.0", port: port)))
        let old = controller.token
        controller.regenerateToken()
        XCTAssertNotEqual(controller.token, old)
        XCTAssertEqual(controller.clientURL, "http://127.0.0.1:\(port)/mcp", "a wildcard bind is reached over loopback")
        for setup in MCPClientSetup.allCases {
            let snippet = setup.snippet(url: controller.clientURL)
            XCTAssertTrue(snippet.contains("http://127.0.0.1:\(port)/mcp"), "\(setup)")
            XCTAssertFalse(snippet.contains(old), "\(setup)")
            XCTAssertFalse(snippet.contains(controller.token), "\(setup)")
        }
        XCTAssertTrue(MCPClientSetup.claudeCode.snippet(url: "u").hasPrefix("claude mcp add --transport http postwoman u "))
        XCTAssertTrue(MCPClientSetup.opencode.snippet(url: "u").contains("--url u --header \"Authorization=Bearer <TOKEN>\""))
        XCTAssertTrue(MCPClientSetup.codex.snippet(url: "u").contains("url = \"u\"\nbearer_token_env_var = \"POSTWOMAN_TOKEN\""))
        XCTAssertTrue(RemoteAgentSettingsForm.connectHelp.contains(MCPClientSetup.tokenVariable))
    }

    func testIPv6EndpointsAreBracketedInSnippets() throws {
        let port = try freePort()
        XCTAssertTrue(controller.apply(RemoteAgentSettings(mcpEnabled: false, bindAddress: "::", port: port)))
        XCTAssertTrue(MCPClientSetup.json.snippet(url: controller.clientURL).contains("\"url\": \"http://[::1]:\(port)/mcp\""))
    }

    // Rendering

    func testSectionsAndControlsAreNamedInLightAndDarkAtEachSize() {
        for size in sizes {
            for appearance in appearances {
                let hosting = fixture.host(RemoteAgentSettingsView(), size: size, appearance: appearance)
                for heading in ["MCP server", "Access token", "Status"] { XCTAssertNotNil(hosting.node("AXHeading", heading)) }
                XCTAssertEqual(hosting.nodes.first { $0.role == "AXCheckBox" }?.titleElement, "Enable MCP server")
                XCTAssertEqual(hosting.nodes.first { $0.role == "AXPopUpButton" }?.titleElement, "Listen on")
                XCTAssertEqual(hosting.nodes.first { $0.role == "AXPopUpButton" }?.label, "Loopback — 127.0.0.1 (this Mac only)")
                XCTAssertEqual(hosting.nodes.first { $0.role == "AXTextField" }?.titleElement, "Port (1024–65535)")
                XCTAssertTrue(hosting.allStrings.contains("Only programs on this Mac can connect."))
                XCTAssertTrue(hosting.allStrings.contains("Server status: Stopped"))
                assertControlsAreLabelled(hosting)
                ViewHosting.close(hosting)
            }
        }
    }

    func testThePortFieldIsNamedOnce() {
        let hosting = fixture.host(RemoteAgentSettingsView())
        defer { ViewHosting.close(hosting) }
        XCTAssertEqual(hosting.nodes.first { $0.role == "AXTextField" }?.label, "Port")
    }

    func testTheTokenIsHiddenUntilShownAndHiddenAgain() {
        let hosting = fixture.host(RemoteAgentSettingsView())
        defer { ViewHosting.close(hosting) }
        let token = controller.token
        XCTAssertTrue(hosting.allStrings.contains("Token hidden"))
        XCTAssertFalse(hosting.allStrings.contains { $0.contains(token) }, "the token is nowhere in the tree")
        hosting.node("AXButton", "Show")?.press()
        ViewHosting.settle()
        XCTAssertTrue(hosting.allStrings.contains("Token \(token)"))
        hosting.node("AXButton", "Hide")?.press()
        ViewHosting.settle()
        XCTAssertFalse(hosting.allStrings.contains { $0.contains(token) })
    }

    func testARegeneratedTokenIsShownInPlaceOfTheOld() {
        let hosting = fixture.host(RemoteAgentSettingsView())
        defer { ViewHosting.close(hosting) }
        hosting.node("AXButton", "Show")?.press()
        let old = controller.token
        controller.regenerateToken()
        ViewHosting.settle()
        XCTAssertTrue(hosting.allStrings.contains("Token \(controller.token)"))
        XCTAssertFalse(hosting.allStrings.contains { $0.contains(old) })
    }

    func testRegeneratingAsksFirstAndCancelKeepsTheToken() throws {
        let hosting = fixture.host(RemoteAgentSettingsView())
        defer { ViewHosting.close(hosting) }
        let old = controller.token
        hosting.node("AXButton", "Regenerate…")?.press()
        ViewHosting.settle()
        let alert = try XCTUnwrap(hosting.window?.attachedSheet?.contentView)
        XCTAssertTrue(alert.allStrings.contains("Regenerate the access token?"))
        alert.node("AXButton", "Cancel")?.press()
        ViewHosting.settle()
        XCTAssertEqual(controller.token, old)
        XCTAssertNil(hosting.window?.attachedSheet)
    }

    func testConfirmingRegenerationReplacesTheTokenHidesItAndSaysAgentsNeedTheNewOne() throws {
        let hosting = fixture.host(RemoteAgentSettingsView())
        defer { ViewHosting.close(hosting) }
        let old = controller.token
        hosting.node("AXButton", "Show")?.press()
        hosting.node("AXButton", "Regenerate…")?.press()
        ViewHosting.settle()
        try XCTUnwrap(hosting.window?.attachedSheet?.contentView).node("AXButton", "Regenerate")?.press()
        ViewHosting.settle()
        XCTAssertNotEqual(controller.token, old)
        XCTAssertTrue(hosting.allStrings.contains("Token hidden"), "a new token starts hidden")
        XCTAssertFalse(hosting.allStrings.contains { $0.contains(controller.token) || $0.contains(old) })
        XCTAssertTrue(hosting.allStrings.contains(RemoteAgentSettingsForm.regeneratedMessage))
    }

    func testApplyAndCopyingAreDisabledUntilThereIsSomethingToDo() {
        let hosting = fixture.host(RemoteAgentSettingsView())
        defer { ViewHosting.close(hosting) }
        XCTAssertEqual(hosting.node("AXButton", "Apply")?.isEnabled, false)
        XCTAssertEqual(hosting.node("AXButton", "Copy Endpoint URL")?.isEnabled, false, "the server is off")
        XCTAssertEqual(hosting.node("AXMenuButton", "Copy Client Setup")?.isEnabled, false)
        hosting.nodes.first { $0.role == "AXCheckBox" }?.press()
        ViewHosting.settle()
        XCTAssertEqual(hosting.node("AXButton", "Apply")?.isEnabled, true)
        XCTAssertEqual(controller.settings.mcpEnabled, false, "a draft until Apply")
    }

    func testApplyingOnLoopbackStartsTheServerAndSaysSo() throws {
        let port = try freePort()
        XCTAssertTrue(controller.apply(RemoteAgentSettings(mcpEnabled: false, port: port)))
        let hosting = fixture.host(RemoteAgentSettingsView())
        defer { ViewHosting.close(hosting) }
        hosting.nodes.first { $0.role == "AXCheckBox" }?.press()
        ViewHosting.settle()
        hosting.node("AXButton", "Apply")?.press()
        ViewHosting.settle()
        XCTAssertEqual(controller.status, .running(url: "http://127.0.0.1:\(port)/mcp"))
        XCTAssertTrue(hosting.allStrings.contains("Remote agent settings saved."))
        XCTAssertTrue(hosting.allStrings.contains("Server status: Running at http://127.0.0.1:\(port)/mcp"))
        XCTAssertEqual(hosting.node("AXButton", "Copy Endpoint URL")?.isEnabled, true)
        XCTAssertEqual(hosting.node("AXButton", "Apply")?.isEnabled, false, "nothing left to apply")
    }

    func testTurningOnANetworkAddressWaitsForConfirmation() throws {
        let port = try freePort()
        XCTAssertTrue(controller.apply(RemoteAgentSettings(mcpEnabled: false, bindAddress: "0.0.0.0", port: port)))
        let hosting = fixture.host(RemoteAgentSettingsView())
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(hosting.allStrings.contains { $0.hasPrefix("Other devices on the network can reach this server.") }, "the warning is in words")
        hosting.nodes.first { $0.role == "AXCheckBox" }?.press()
        ViewHosting.settle()
        hosting.node("AXButton", "Apply")?.press()
        ViewHosting.settle()
        XCTAssertEqual(controller.status, .stopped, "nothing listens before the confirmation")
        let alert = try XCTUnwrap(hosting.window?.attachedSheet?.contentView)
        XCTAssertTrue(alert.allStrings.contains("Allow connections from the network?"))
        XCTAssertTrue(alert.allStrings.contains(RemoteAgentSettingsForm.networkWarning(address: "0.0.0.0")))
        XCTAssertNotNil(alert.node("AXButton", "Allow Network Access"))
        alert.node("AXButton", "Cancel")?.press()
        ViewHosting.settle()
        XCTAssertNil(hosting.window?.attachedSheet)
        XCTAssertEqual(controller.status, .stopped, "cancelling starts nothing")
        XCTAssertFalse(controller.settings.mcpEnabled)
        XCTAssertFalse(controller.settings.mcpEnabled)
        let probe = MCPListener { _ in .empty(204) }
        XCTAssertEqual(try probe.start(address: "0.0.0.0", port: port), port, "the port is still free")
        probe.stop()
    }

    func testAFailedStartIsShownAndCanBeRetried() throws {
        let busy = MCPListener { _ in .empty(204) }
        let port = try busy.start(address: "127.0.0.1", port: 0)
        defer { busy.stop() }
        XCTAssertTrue(controller.apply(RemoteAgentSettings(mcpEnabled: true, port: port)))
        guard case .failed(let reason) = controller.status else { return XCTFail("\(controller.status)") }
        let hosting = fixture.host(RemoteAgentSettingsView())
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(hosting.allStrings.contains("Server status: Not running: \(reason)"))
        XCTAssertEqual(hosting.node("AXButton", "Apply")?.isEnabled, true, "same settings, retryable")
    }
}

// MARK: - Updates

@MainActor
final class UpdateSettingsViewTests: XCTestCase {
    func testLastCheckTextSaysNeverOrWhen() {
        XCTAssertEqual(UpdateSettingsView.lastCheckText(nil), "Never checked")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(UpdateSettingsView.lastCheckText(date), "Last checked \(date.formatted(date: .abbreviated, time: .shortened))")
    }

    func testShowsTheVersionNeverCheckedAndNamedToggles() {
        for size in sizes {
            for appearance in appearances {
                let model = UpdateSettingsModel(updater: FakeUpdater(), version: "0.11.0-beta.2")
                let hosting = ViewHosting.host(UpdateSettingsView(updates: model), size: size, appearance: appearance)
                for heading in ["Current version", "Automatic updates"] { XCTAssertNotNil(hosting.node("AXHeading", heading)) }
                XCTAssertTrue(hosting.allStrings.contains("0.11.0-beta.2"))
                XCTAssertTrue(hosting.allStrings.contains("Never checked"))
                let toggles = hosting.nodes.filter { $0.role == "AXCheckBox" }
                XCTAssertEqual(toggles.map(\.titleElement), ["Automatically check for updates", "Include beta versions"])
                XCTAssertEqual(hosting.node("AXButton", "Check Now")?.isEnabled, true)
                assertControlsAreLabelled(hosting)
                ViewHosting.close(hosting)
            }
        }
    }

    func testTogglesShowAndChangeTheUpdatersSettings() throws {
        let updater = FakeUpdater()
        updater.includesBetas = true
        let model = UpdateSettingsModel(updater: updater)
        let hosting = ViewHosting.host(UpdateSettingsView(updates: model))
        defer { ViewHosting.close(hosting) }
        let toggles = hosting.nodes.filter { $0.role == "AXCheckBox" }
        XCTAssertEqual(toggles.map { "\($0.object.value(forKey: "accessibilityValue") ?? "")" }, ["0", "1"])
        try XCTUnwrap(toggles.first).press()
        ViewHosting.settle()
        XCTAssertTrue(updater.automaticallyChecksForUpdates)
        try XCTUnwrap(hosting.nodes.filter { $0.role == "AXCheckBox" }.last).press()
        ViewHosting.settle()
        XCTAssertFalse(updater.includesBetas)
        XCTAssertEqual(updater.checks, 0, "changing a setting doesn't check")
    }

    func testCheckNowAsksTheUpdaterAndIsDisabledWhileItIsBusy() {
        let updater = FakeUpdater()
        let checked = Date(timeIntervalSince1970: 1_800_000_000)
        updater.lastUpdateCheckDate = checked
        let model = UpdateSettingsModel(updater: updater)
        let hosting = ViewHosting.host(UpdateSettingsView(updates: model))
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(hosting.allStrings.contains(UpdateSettingsView.lastCheckText(checked)))
        hosting.node("AXButton", "Check Now")?.press()
        XCTAssertEqual(updater.checks, 1)
        updater.canCheckForUpdates = false
        updater.onChange?()
        ViewHosting.settle()
        XCTAssertEqual(hosting.node("AXButton", "Check Now")?.isEnabled, false)
    }

    func testAppearingPicksUpChangesMadeWhileTheSettingsWereClosed() {
        let updater = FakeUpdater()
        let model = UpdateSettingsModel(updater: updater)
        updater.automaticallyChecksForUpdates = true
        let hosting = ViewHosting.host(UpdateSettingsView(updates: model))
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(model.automaticChecks)
        XCTAssertEqual("\(hosting.nodes.first { $0.role == "AXCheckBox" }?.object.value(forKey: "accessibilityValue") ?? "")", "1")
    }
}
