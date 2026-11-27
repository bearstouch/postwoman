import AppKit
import SwiftData
import SwiftUI
import XCTest

@testable import PostWoman

/// A collection like a user's: Default with a URL and a secret token, a Staging override (in use) with its own secret, and a
/// Production override that sets nothing.
@MainActor
private struct EnvironmentFixture {
    let container: ModelContainer
    let folder: Folder
    let staging: CollectionEnvironment
    let production: CollectionEnvironment
    var context: ModelContext { container.mainContext }
    var defaultEnvironment: CollectionEnvironment { folder.defaultEnvironment! }

    static let defaultSecret = "default-s3cret-value"
    static let stagingSecret = "staging-s3cret-value"
    static let inheritedSecret = "inherited-api-key"

    init() throws {
        container = try ViewHosting.container()
        folder = Folder(name: "Shop API")
        container.mainContext.insert(folder)
        folder.ensureDefaultEnvironment().variables = [
            Variable(key: "baseUrl", value: "https://shop.local"), Variable(key: "token", value: Self.defaultSecret, isSecret: true),
            Variable(key: "apiKey", value: Self.inheritedSecret, isSecret: true)
        ]
        staging = folder.addEnvironment(named: "Staging", color: .orange, variables: [Variable(key: "token", value: Self.stagingSecret, isSecret: true)])
        production = folder.addEnvironment(named: "Production", color: .red)
        folder.selectedEnvironment = staging
        try container.mainContext.save()
    }
}

/// Reads an accessibility tree with enabled state too (which `ViewHosting.Element` leaves out), through both the
/// NSAccessibility getters and the older attribute API that some AppKit-backed controls answer.
@MainActor
private enum AXTree {
    struct Node {
        let role: String
        let texts: [String]
        let help: String
        let isSelected: Bool
        let isEnabled: Bool
        var label: String { texts.first ?? "" }
    }

    static func nodes(in root: NSObject) -> [Node] {
        var found: [Node] = []
        var seen = Set<ObjectIdentifier>()
        func get(_ node: NSObject, _ getter: String) -> Any? {
            node.responds(to: NSSelectorFromString(getter)) ? node.perform(NSSelectorFromString(getter))?.takeUnretainedValue() : nil
        }
        func attribute(_ node: NSObject, _ name: String) -> Any? {
            guard node.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) else { return nil }
            return node.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: name)?.takeUnretainedValue()
        }
        func flag(_ node: NSObject, getter: String, key: String, attribute name: String) -> Bool? {
            if node.responds(to: NSSelectorFromString(getter)), let value = node.value(forKey: key) as? Bool { return value }
            return (attribute(node, name) as? NSNumber)?.boolValue
        }
        func visit(_ object: Any, depth: Int) {
            guard depth < 60, let node = object as? NSObject, seen.insert(ObjectIdentifier(node)).inserted else { return }
            let role = get(node, "accessibilityRole") as? String ?? attribute(node, "AXRole") as? String ?? ""
            var texts: [String] = []
            for text in [get(node, "accessibilityLabel"), get(node, "accessibilityTitle"), get(node, "accessibilityValue")]
                + [attribute(node, "AXDescription"), attribute(node, "AXTitle"), attribute(node, "AXValue")]
            {
                if let text = text as? String, !text.isEmpty, !texts.contains(text) { texts.append(text) }
            }
            let help = get(node, "accessibilityHelp") as? String ?? attribute(node, "AXHelp") as? String ?? ""
            found.append(
                Node(
                    role: role, texts: texts, help: help,
                    isSelected: flag(node, getter: "isAccessibilitySelected", key: "accessibilitySelected", attribute: "AXSelected") ?? false,
                    isEnabled: flag(node, getter: "isAccessibilityEnabled", key: "accessibilityEnabled", attribute: "AXEnabled") ?? true))
            for child in (get(node, "accessibilityChildren") as? [Any] ?? []) + (attribute(node, "AXChildren") as? [Any] ?? []) {
                visit(child, depth: depth + 1)
            }
        }
        visit(root, depth: 0)
        return found
    }

    static func buttons(in root: NSObject) -> [Node] { nodes(in: root).filter { $0.role == "AXButton" || $0.role == "AXMenuButton" } }
    static func text(in root: NSObject) -> [String] { nodes(in: root).flatMap(\.texts) }
    static func button(_ label: String, in root: NSObject) -> Node? { buttons(in: root).first { $0.label == label } }
}

// MARK: - ManageEnvironmentsView

@MainActor
final class ManageEnvironmentsViewTests: XCTestCase {
    private static let size = CGSize(width: 900, height: 580)

    // MARK: Names and colors

    func testAUnusedNameIsKeptAsIs() throws {
        let fixture = try EnvironmentFixture()
        XCTAssertEqual(EnvironmentActions.uniqueName("QA", in: fixture.folder), "QA")
    }

    func testATakenNameGetsTheFirstFreeNumber() throws {
        let fixture = try EnvironmentFixture()
        XCTAssertEqual(EnvironmentActions.uniqueName("Staging", in: fixture.folder), "Staging 2")
        fixture.folder.addEnvironment(named: "Staging 2", color: .gray)
        XCTAssertEqual(EnvironmentActions.uniqueName("Staging", in: fixture.folder), "Staging 3")
        fixture.folder.addEnvironment(named: "Staging 4", color: .gray)
        XCTAssertEqual(EnvironmentActions.uniqueName("Staging", in: fixture.folder), "Staging 3", "Fills the first gap")
    }

    func testUniqueNamesCountDefaultToo() throws {
        let fixture = try EnvironmentFixture()
        XCTAssertEqual(EnvironmentActions.uniqueName("Default", in: fixture.folder), "Default 2")
    }

    func testUniqueNamesMatchExactlyNotIgnoringCaseOrSpaces() throws {
        let fixture = try EnvironmentFixture()
        XCTAssertEqual(EnvironmentActions.uniqueName("staging", in: fixture.folder), "staging")
        XCTAssertEqual(EnvironmentActions.uniqueName(" Staging ", in: fixture.folder), " Staging ")
    }

    func testAddedEnvironmentsTakeGreenOrangeRedInTurnThenGray() throws {
        let container = try ViewHosting.container()
        let folder = Folder(name: "API")
        container.mainContext.insert(folder)
        folder.ensureDefaultEnvironment()
        XCTAssertEqual(EnvironmentActions.colorForAdded(in: folder), .green, "Default's blue doesn't count")
        let colors = (0..<4).map { _ in EnvironmentActions.add(to: folder).color }
        XCTAssertEqual(colors, [.green, .orange, .red, .gray])
    }

    func testTheNewEnvironmentSheetSuggestsAColorNotInUse() throws {
        let fixture = try EnvironmentFixture()
        XCTAssertEqual(EnvironmentActions.colorForNew(in: fixture.folder), .green)
        fixture.folder.addEnvironment(named: "QA", color: .green)
        XCTAssertEqual(EnvironmentActions.colorForNew(in: fixture.folder), .pink)
        fixture.folder.addEnvironment(named: "Dev", color: .pink)
        XCTAssertEqual(EnvironmentActions.colorForNew(in: fixture.folder), .gray)
    }

    // MARK: Add, duplicate, delete

    func testAddMakesAnEmptyEnvironmentAtTheEndWithAUniqueName() throws {
        let fixture = try EnvironmentFixture()
        let first = EnvironmentActions.add(to: fixture.folder)
        let second = EnvironmentActions.add(to: fixture.folder)
        XCTAssertEqual([first.name, second.name], ["New Environment", "New Environment 2"])
        XCTAssertTrue(first.variables.isEmpty)
        XCTAssertFalse(first.isDefault)
        XCTAssertEqual(fixture.folder.overrideEnvironments.map(\.name), ["Staging", "Production", "New Environment", "New Environment 2"])
        XCTAssertEqual(fixture.folder.selectedEnvironment?.id, fixture.staging.id, "Adding doesn't change what requests use")
    }

    func testDuplicateCopiesVariablesIncludingSecretsAsIndependentValues() throws {
        let fixture = try EnvironmentFixture()
        let copy = EnvironmentActions.duplicate(fixture.staging, in: fixture.folder)
        XCTAssertEqual(copy.name, "Staging Copy")
        XCTAssertEqual(copy.color, .orange)
        XCTAssertEqual(copy.variables.map(\.key), ["token"])
        XCTAssertEqual(copy.variables.first?.value, EnvironmentFixture.stagingSecret)
        XCTAssertEqual(copy.variables.first?.isSecret, true)
        XCTAssertNotEqual(copy.variables.first?.id, fixture.staging.variables.first?.id)
        copy.variables[0].value = "changed"
        XCTAssertEqual(fixture.staging.variables.first?.value, EnvironmentFixture.stagingSecret, "Editing the copy leaves the original")
        XCTAssertEqual(EnvironmentActions.duplicate(fixture.staging, in: fixture.folder).name, "Staging Copy 2")
    }

    func testDuplicatingDefaultMakesAGrayOverrideWithItsVariables() throws {
        let fixture = try EnvironmentFixture()
        let copy = EnvironmentActions.duplicate(fixture.defaultEnvironment, in: fixture.folder)
        XCTAssertEqual(copy.name, "New Environment")
        XCTAssertEqual(copy.color, .gray)
        XCTAssertFalse(copy.isDefault)
        XCTAssertEqual(copy.variables.map(\.key), ["baseUrl", "token", "apiKey"])
        XCTAssertEqual(fixture.folder.environments?.filter(\.isDefault).count, 1, "Still one Default")
    }

    func testDeletingTheEnvironmentInUseFallsBackToDefaultOnly() throws {
        let fixture = try EnvironmentFixture()
        let editing = EnvironmentActions.delete(fixture.staging, in: fixture.folder, context: fixture.context, editingID: fixture.staging.id)
        try fixture.context.save()
        XCTAssertNil(fixture.folder.selectedEnvironmentID)
        XCTAssertEqual(fixture.folder.activeEnvironmentName, "Default")
        XCTAssertEqual(editing, fixture.defaultEnvironment.id, "The editor moves to Default")
        XCTAssertEqual(fixture.folder.overrideEnvironments.map(\.name), ["Production"])
    }

    func testDeletingAnotherEnvironmentKeepsSelectionAndEditor() throws {
        let fixture = try EnvironmentFixture()
        let editing = EnvironmentActions.delete(fixture.production, in: fixture.folder, context: fixture.context, editingID: fixture.staging.id)
        try fixture.context.save()
        XCTAssertEqual(editing, fixture.staging.id)
        XCTAssertEqual(fixture.folder.selectedEnvironmentID, fixture.staging.id)
        XCTAssertEqual(fixture.folder.overrideEnvironments.map(\.name), ["Staging"])
    }

    func testDefaultIsNeverDeleted() throws {
        let fixture = try EnvironmentFixture()
        let defaultID = fixture.defaultEnvironment.id
        let editing = EnvironmentActions.delete(fixture.defaultEnvironment, in: fixture.folder, context: fixture.context, editingID: defaultID)
        try fixture.context.save()
        XCTAssertEqual(editing, defaultID)
        XCTAssertEqual(fixture.folder.defaultEnvironment?.id, defaultID)
        XCTAssertEqual(fixture.folder.defaultEnvironment?.variables.count, 3)
        XCTAssertEqual(fixture.folder.selectedEnvironmentID, fixture.staging.id, "Nothing else changes either")
        XCTAssertEqual(fixture.folder.environments?.count, 3)
    }

    // MARK: Rendering

    private func host(_ fixture: EnvironmentFixture, editing: CollectionEnvironment? = nil, appearance: NSAppearance.Name = .aqua) -> NSHostingView<AnyView> {
        ViewHosting.host(
            ManageEnvironmentsView(folder: fixture.folder, editing: editing?.id), size: Self.size, appearance: appearance, container: fixture.container)
    }

    func testListsDefaultThenTheOverridesWithTheOneInUseMarkedInText() throws {
        let fixture = try EnvironmentFixture()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let hosting = host(fixture, appearance: appearance)
            defer { ViewHosting.close(hosting) }
            let rows = ViewHosting.buttonLabels(in: hosting).filter { ["Default", "Staging", "Production"].contains($0.components(separatedBy: ",").first) }
            XCTAssertEqual(rows, ["Default, 3", "Staging, IN USE, 1", "Production, 0"], "Name, in-use badge and variable count, in \(appearance.rawValue)")
            XCTAssertTrue(ViewHosting.text(in: hosting).contains("Shop API · Environments"))
        }
    }

    func testTheEditedEnvironmentIsExposedAsSelected() throws {
        let fixture = try EnvironmentFixture()
        let hosting = host(fixture, editing: fixture.production)
        defer { ViewHosting.close(hosting) }
        let selected = ViewHosting.elements(in: hosting).filter { $0.role == .button && $0.isSelected == true }.map(\.label)
        XCTAssertEqual(selected.filter { !EnvironmentColor.allCases.map(\.title).contains($0) }, ["Production, 0"])
        XCTAssertEqual(selected.filter { EnvironmentColor.allCases.map(\.title).contains($0) }, ["Red"], "Its color, by name")
    }

    func testOpensOnTheEnvironmentInUse() throws {
        let fixture = try EnvironmentFixture()
        let hosting = host(fixture)
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("VALUE IN STAGING"))
        XCTAssertTrue(ViewHosting.buttonLabels(in: hosting).contains("Stop Using"))
    }

    func testSecretValuesAreNeverExposed() throws {
        let fixture = try EnvironmentFixture()
        for environment in [fixture.defaultEnvironment, fixture.staging, fixture.production] {
            let hosting = host(fixture, editing: environment)
            defer { ViewHosting.close(hosting) }
            let elements = ViewHosting.elements(in: hosting)
            let exposed = elements.map(\.label) + elements.map(\.help)
            for secret in [EnvironmentFixture.defaultSecret, EnvironmentFixture.stagingSecret, EnvironmentFixture.inheritedSecret] {
                XCTAssertFalse(exposed.contains { $0.contains(secret) }, "\(secret) is exposed while editing \(environment.name)")
            }
        }
    }

    func testOverridesShowDefaultsReplacedAndInheritedValuesMaskedWhenSecret() throws {
        let fixture = try EnvironmentFixture()
        let hosting = host(fixture, editing: fixture.staging)
        defer { ViewHosting.close(hosting) }
        let text = ViewHosting.text(in: hosting)
        XCTAssertTrue(text.contains(VariableDescription.mask), "Default's secret token, which Staging replaces, is masked")
        XCTAssertTrue(text.contains("↳, baseUrl, Inherited ·, https://shop.local"), "A plain inherited value is shown")
        XCTAssertTrue(text.contains("↳, apiKey, Inherited ·, \(VariableDescription.mask)"), "A secret inherited value is masked")
        XCTAssertTrue(text.contains("DEFAULT VALUE"))
    }

    func testDefaultCannotBeDeletedOrRecoloredFromItsEditor() throws {
        let fixture = try EnvironmentFixture()
        let hosting = host(fixture, editing: fixture.defaultEnvironment)
        defer { ViewHosting.close(hosting) }
        XCTAssertEqual(AXTree.nodes(in: hosting).first { $0.help == "Delete Environment" }?.isEnabled, false)
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("Always applies"))
        XCTAssertFalse(ViewHosting.buttonLabels(in: hosting).contains("Green"), "No color choice for Default")
        XCTAssertFalse(ViewHosting.buttonLabels(in: hosting).contains("Use for Requests"))
    }

    func testAnOverrideNotInUseOffersToBeUsed() throws {
        let fixture = try EnvironmentFixture()
        let hosting = host(fixture, editing: fixture.production)
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(ViewHosting.buttonLabels(in: hosting).contains("Use for Requests"))
        XCTAssertEqual(AXTree.nodes(in: hosting).first { $0.help == "Delete Environment" }?.isEnabled, true)
    }

    func testTheListFollowsModelChanges() throws {
        let fixture = try EnvironmentFixture()
        let hosting = host(fixture)
        defer { ViewHosting.close(hosting) }
        _ = EnvironmentActions.add(to: fixture.folder)
        _ = EnvironmentActions.delete(fixture.production, in: fixture.folder, context: fixture.context, editingID: nil)
        try fixture.context.save()
        ViewHosting.settle()
        let labels = ViewHosting.buttonLabels(in: hosting)
        XCTAssertTrue(labels.contains("New Environment, 0"))
        XCTAssertFalse(labels.contains { $0.hasPrefix("Production") })
    }

    func testControlsAreNamedForVoiceOverNotByTheirIcons() throws {
        let fixture = try EnvironmentFixture()
        let hosting = host(fixture, editing: fixture.staging)
        defer { ViewHosting.close(hosting) }
        let elements = ViewHosting.elements(in: hosting)
        let buttons = ViewHosting.buttonLabels(in: hosting)
        for expected in ["New Environment", "Delete Environment", "Show Value", "Remove Variable"] {
            XCTAssertTrue(buttons.contains(expected), "No button named '\(expected)' in \(buttons)")
        }
        for icon in ["Add", "Remove", "Show", "Close"] { XCTAssertFalse(buttons.contains(icon), "A button is read as its icon, '\(icon)'") }
        let checkboxes = elements.filter { $0.role == .checkBox }.map(\.label)
        XCTAssertEqual(checkboxes, ["Enabled", "Secret"], "The variable's switches say what they switch")
    }

    func testRowHelpIsSaidOnce() throws {
        let fixture = try EnvironmentFixture()
        let hosting = host(fixture)
        defer { ViewHosting.close(hosting) }
        let help = ViewHosting.elements(in: hosting).filter { $0.label.hasPrefix("Default,") || $0.label.hasPrefix("Staging,") }.map(\.help)
        XCTAssertEqual(help, ["Default always applies. Other environments override it.", "Staging"])
    }

    func testIconOnlyButtonsHaveHelp() throws {
        let fixture = try EnvironmentFixture()
        let hosting = host(fixture, editing: fixture.staging)
        defer { ViewHosting.close(hosting) }
        let help = Set(ViewHosting.elements(in: hosting).map(\.help))
        for expected in ["New Environment", "Delete Environment", "Show Value", "Remove Variable", "Secret: masked, kept out of History and exports"] {
            XCTAssertTrue(help.contains(expected), "No button with help '\(expected)'")
        }
        XCTAssertTrue(ViewHosting.buttonLabels(in: hosting).allSatisfy { !$0.isEmpty }, "Every button has a label")
    }
}

// MARK: - NewEnvironmentView

@MainActor
final class NewEnvironmentViewTests: XCTestCase {
    func testCopySourcesAreDefaultThenTheOverrides() throws {
        let fixture = try EnvironmentFixture()
        XCTAssertEqual(EnvironmentActions.copySources(in: fixture.folder).map(\.name), ["Default", "Staging", "Production"])
    }

    func testABlankNameCreatesNothing() throws {
        let fixture = try EnvironmentFixture()
        for name in ["", "   ", "\n\t"] {
            XCTAssertNil(EnvironmentActions.create(named: name, color: .green, copyFrom: nil, in: fixture.folder, selectsNow: true))
        }
        XCTAssertEqual(fixture.folder.environments?.count, 3)
        XCTAssertEqual(fixture.folder.selectedEnvironmentID, fixture.staging.id, "The selection is untouched")
    }

    func testCreateTrimsTheNameAndCanStartEmpty() throws {
        let fixture = try EnvironmentFixture()
        let created = try XCTUnwrap(EnvironmentActions.create(named: "  QA \n", color: .pink, copyFrom: nil, in: fixture.folder, selectsNow: false))
        XCTAssertEqual(created.name, "QA")
        XCTAssertEqual(created.color, .pink)
        XCTAssertTrue(created.variables.isEmpty)
        XCTAssertEqual(fixture.folder.selectedEnvironmentID, fixture.staging.id, "Not used unless asked")
        XCTAssertEqual(fixture.folder.overrideEnvironments.last?.id, created.id)
    }

    func testCreateCanCopyAnotherEnvironmentAndUseItNow() throws {
        let fixture = try EnvironmentFixture()
        let created = try XCTUnwrap(
            EnvironmentActions.create(named: "Local", color: .green, copyFrom: fixture.defaultEnvironment.id, in: fixture.folder, selectsNow: true))
        XCTAssertEqual(created.variables.map(\.key), ["baseUrl", "token", "apiKey"])
        XCTAssertEqual(created.variables.map(\.isSecret), [false, true, true])
        XCTAssertEqual(fixture.folder.selectedEnvironmentID, created.id)
        XCTAssertEqual(fixture.folder.activeEnvironmentName, "Local")
    }

    func testCopyingAnUnknownEnvironmentStartsEmpty() throws {
        let fixture = try EnvironmentFixture()
        let created = EnvironmentActions.create(named: "QA", color: .green, copyFrom: UUID(), in: fixture.folder, selectsNow: false)
        XCTAssertEqual(created?.variables, [])
    }

    func testTheSheetNamesTheCollectionAndCannotCreateWithoutAName() throws {
        let fixture = try EnvironmentFixture()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let hosting = ViewHosting.host(
                NewEnvironmentView(folder: fixture.folder), size: CGSize(width: 460, height: 420), appearance: appearance, container: fixture.container)
            defer { ViewHosting.close(hosting) }
            let text = ViewHosting.text(in: hosting)
            XCTAssertTrue(text.contains("New Environment"))
            XCTAssertTrue(text.contains("Use it for Shop API now"))
            XCTAssertTrue(text.contains("No overrides: everything comes from Default"))
            XCTAssertEqual(AXTree.button("Create", in: hosting)?.isEnabled, false)
            XCTAssertEqual(AXTree.button("Cancel", in: hosting)?.isEnabled, true)
            XCTAssertTrue(ViewHosting.elements(in: hosting).contains { $0.role == .textField && $0.label == "Name" }, "The name field is named")
        }
    }
}

// MARK: - EnvironmentMenu

@MainActor
final class EnvironmentMenuTests: XCTestCase {
    private func menu(_ folder: Folder?, container: ModelContainer, appearance: NSAppearance.Name = .aqua) -> NSHostingView<AnyView> {
        ViewHosting.host(EnvironmentMenu(folder: folder), size: CGSize(width: 220, height: 30), appearance: appearance, container: container)
    }

    func testShowsTheEnvironmentInUseByName() throws {
        let fixture = try EnvironmentFixture()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let hosting = menu(fixture.folder, container: fixture.container, appearance: appearance)
            defer { ViewHosting.close(hosting) }
            let button = try XCTUnwrap(AXTree.nodes(in: hosting).first { $0.role == "AXMenuButton" })
            XCTAssertEqual(button.label, "Staging")
            XCTAssertTrue(button.isEnabled)
            XCTAssertEqual(button.help, "Environment for Shop API's requests. Default always applies; the one you pick overrides it.")
        }
    }

    func testShowsDefaultsOwnNameWhenNoOtherIsInUse() throws {
        let fixture = try EnvironmentFixture()
        fixture.folder.selectedEnvironmentID = nil
        fixture.defaultEnvironment.name = "Local"
        let hosting = menu(fixture.folder, container: fixture.container)
        defer { ViewHosting.close(hosting) }
        let button = try XCTUnwrap(AXTree.nodes(in: hosting).first { $0.role == "AXMenuButton" })
        XCTAssertEqual(button.label, "Local")
        XCTAssertTrue(button.help.contains("Local always applies"))
    }

    func testIsDisabledAndSaysWhyOutsideACollection() throws {
        let container = try ViewHosting.container()
        let hosting = menu(nil, container: container)
        defer { ViewHosting.close(hosting) }
        let button = try XCTUnwrap(AXTree.nodes(in: hosting).first { $0.role == "AXMenuButton" })
        XCTAssertEqual(button.label, "No Environment")
        XCTAssertFalse(button.isEnabled)
        XCTAssertEqual(button.help, "Requests outside a collection have no environment.")
    }

    func testFollowsTheSelectionWhenItChanges() throws {
        let fixture = try EnvironmentFixture()
        let hosting = menu(fixture.folder, container: fixture.container)
        defer { ViewHosting.close(hosting) }
        EnvironmentActions.select(index: 2, in: fixture.folder)
        ViewHosting.settle()
        XCTAssertEqual(AXTree.nodes(in: hosting).first { $0.role == "AXMenuButton" }?.label, "Production")
    }
}
