import AppKit
import SwiftData
import SwiftUI
import XCTest

@testable import Reqs

/// Reads and presses what an accessibility client would in the code generator sheet.
@MainActor
private enum SheetAccess {
    static func nodes(in root: NSView) -> [NSObject] {
        var found: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: Any, depth: Int) {
            guard depth < 60, let node = object as? NSObject, seen.insert(ObjectIdentifier(node)).inserted else { return }
            found.append(node)
            for child in read(node, "accessibilityChildren") as? [Any] ?? [] { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return found
    }

    static func read(_ node: NSObject, _ getter: String) -> Any? {
        node.responds(to: NSSelectorFromString(getter)) ? node.perform(NSSelectorFromString(getter))?.takeUnretainedValue() : nil
    }

    static func press(_ label: String, in root: NSView) -> Bool {
        for node in nodes(in: root) where (read(node, "accessibilityRole") as? String) == NSAccessibility.Role.button.rawValue {
            guard ["accessibilityLabel", "accessibilityTitle"].contains(where: { read(node, $0) as? String == label }) else { continue }
            _ = node.perform(NSSelectorFromString("accessibilityPerformPress"))
            ViewHosting.settle()
            return true
        }
        return false
    }

    static func exposedStrings(in root: NSView) -> [String] {
        let getters = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityHelp"]
        return nodes(in: root).flatMap { node in getters.compactMap { read(node, $0) as? String } }
    }

    /// The generated code as shown: the longest text in the sheet.
    static func shownCode(in root: NSView) -> String { ViewHosting.text(in: root).max { $0.count < $1.count } ?? "" }
}

@MainActor
final class CodeGeneratorViewTests: XCTestCase {
    private let request: RequestSnapshot = {
        let model = APIRequest(name: "List Users", url: "https://{{host}}/users", method: .post)
        model.headers = [KeyValuePair(key: "Authorization", value: "Bearer {{token}}")]
        model.bodyType = .json
        model.bodyContent = #"{"a":1}"#
        return RequestSnapshot(model)
    }()
    private let resolver = VariableResolver(
        defaults: [Variable(key: "host", value: "api.example.com"), Variable(key: "token", value: "s3cret-token", isSecret: true)], selected: nil)

    func testEachLanguageGeneratesItsOwnCode() {
        let curl = CodeGeneratorView.code(for: request, in: .curl, resolver: nil, resolvesVariables: false)
        let swift = CodeGeneratorView.code(for: request, in: .swift, resolver: nil, resolvesVariables: false)
        let python = CodeGeneratorView.code(for: request, in: .python, resolver: nil, resolvesVariables: false)
        XCTAssertTrue(curl.hasPrefix("curl"), curl)
        XCTAssertTrue(swift.contains("URLRequest(url: url)"), swift)
        XCTAssertTrue(python.contains("import requests"), python)
        XCTAssertEqual(curl, CURLGenerator().generate(from: request))
        XCTAssertEqual(swift, SwiftGenerator().generate(from: request))
        XCTAssertEqual(python, PythonGenerator().generate(from: request))
    }

    func testResolvingFillsInVariablesButKeepsSecretsAsNames() {
        for language in CodeGeneratorView.CodeLanguage.allCases {
            let code = CodeGeneratorView.code(for: request, in: language, resolver: resolver, resolvesVariables: true)
            XCTAssertTrue(code.contains("https://api.example.com/users"), "\(language): \(code)")
            XCTAssertTrue(code.contains("Bearer {{token}}"), "\(language): \(code)")
            XCTAssertFalse(code.contains("s3cret-token"), "\(language) leaked the secret")
        }
    }

    func testWithoutResolvingOrAnEnvironmentVariablesStayAsWritten() {
        XCTAssertTrue(CodeGeneratorView.code(for: request, in: .curl, resolver: resolver, resolvesVariables: false).contains("https://{{host}}/users"))
        XCTAssertTrue(CodeGeneratorView.code(for: request, in: .curl, resolver: nil, resolvesVariables: true).contains("https://{{host}}/users"))
    }

    func testTheVariablesSwitchNeedsACollectionAndAnEnvironment() {
        XCTAssertTrue(CodeGeneratorView.showsVariablesSwitch(environmentLabel: "API · Default", resolver: resolver))
        XCTAssertFalse(CodeGeneratorView.showsVariablesSwitch(environmentLabel: nil, resolver: resolver))
        XCTAssertFalse(CodeGeneratorView.showsVariablesSwitch(environmentLabel: "API · Default", resolver: nil))
    }

    func testTheSheetShowsResolvedCURLFirstWithLabelledButtonsAndNoSecrets() throws {
        let (container, model, folder) = try store()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let hosting = ViewHosting.host(
                CodeGeneratorView(request: model, resolver: folder.variableResolver, environmentLabel: "Users API · Default"),
                size: CGSize(width: 700, height: 500), appearance: appearance, container: container)
            defer { ViewHosting.close(hosting) }
            let text = ViewHosting.text(in: hosting)
            XCTAssertTrue(text.contains("Generate Code"), "\(appearance)")
            XCTAssertTrue(text.contains("Resolve variables with Users API · Default"), "\(appearance)")
            XCTAssertTrue(text.contains("Secrets stay as {{name}}"), "\(appearance)")
            XCTAssertEqual(ViewHosting.buttonLabels(in: hosting), ["Done", "cURL", "Swift", "Python", "Copy"], "\(appearance)")
            let code = SheetAccess.shownCode(in: hosting)
            XCTAssertTrue(code.hasPrefix("curl"), code)
            XCTAssertTrue(code.contains("https://api.example.com/users"), code)
            XCTAssertFalse(SheetAccess.exposedStrings(in: hosting).contains { $0.contains("s3cret-token") }, "\(appearance)")
        }
    }

    func testARequestOutsideACollectionHasNoVariablesSwitch() throws {
        let container = try ViewHosting.container()
        let model = APIRequest(name: "Loose", url: "https://example.com")
        container.mainContext.insert(model)
        let hosting = ViewHosting.host(CodeGeneratorView(request: model), size: CGSize(width: 700, height: 500), container: container)
        defer { ViewHosting.close(hosting) }
        XCTAssertFalse(ViewHosting.text(in: hosting).contains { $0.hasPrefix("Resolve variables") })
        XCTAssertTrue(ViewHosting.text(in: hosting).contains { $0.hasPrefix("curl") && $0.contains("https://example.com") })
    }

    func testTheChosenLanguageIsExposedAsSelectedNotOnlyByColor() throws {
        let (container, model, folder) = try store()
        let hosting = ViewHosting.host(
            CodeGeneratorView(request: model, resolver: folder.variableResolver, environmentLabel: "Users API · Default"),
            size: CGSize(width: 700, height: 500), container: container)
        defer { ViewHosting.close(hosting) }
        func selected() -> [String] { ViewHosting.elements(in: hosting).filter { $0.role == .button && $0.isSelected == true }.map(\.label) }
        XCTAssertEqual(selected(), ["cURL"])
        XCTAssertTrue(SheetAccess.press("Python", in: hosting))
        XCTAssertEqual(selected(), ["Python"])
    }

    func testPickingALanguageShowsItsCode() throws {
        let (container, model, folder) = try store()
        let hosting = ViewHosting.host(
            CodeGeneratorView(request: model, resolver: folder.variableResolver, environmentLabel: "Users API · Default"),
            size: CGSize(width: 700, height: 500), container: container)
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(SheetAccess.press("Python", in: hosting))
        XCTAssertTrue(SheetAccess.shownCode(in: hosting).contains("import requests"))
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("python"), "The terminal bar names the language")
        XCTAssertTrue(SheetAccess.press("Swift", in: hosting))
        XCTAssertTrue(SheetAccess.shownCode(in: hosting).contains("URLRequest"))
        XCTAssertFalse(SheetAccess.exposedStrings(in: hosting).contains { $0.contains("s3cret-token") })
    }

    private func store() throws -> (ModelContainer, APIRequest, Folder) {
        let container = try ViewHosting.container()
        let folder = Folder(name: "Users API")
        container.mainContext.insert(folder)
        folder.ensureDefaultEnvironment().variables = [
            Variable(key: "host", value: "api.example.com"), Variable(key: "token", value: "s3cret-token", isSecret: true)
        ]
        let model = APIRequest(name: "List Users", url: "https://{{host}}/users", method: .post, folder: folder)
        container.mainContext.insert(model)
        model.headers = [KeyValuePair(key: "Authorization", value: "Bearer {{token}}")]
        return (container, model, folder)
    }
}
