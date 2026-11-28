import AppKit
import SwiftData
import SwiftUI
import XCTest

@testable import Reqs

@MainActor
final class ImportViewTests: XCTestCase {
    private let postmanCollection = Data(#"{"info": {"name": "API"}, "item": [{"name": "A", "request": "https://h/a"}, {"name": "B", "request": "https://h/b"}]}"#.utf8)
    private let postmanEnvironment = Data(#"{"name": "Staging", "_postman_variable_scope": "environment", "values": [{"key": "a", "value": "1"}]}"#.utf8)
    private let withScripts = Data(#"{"info": {"name": "S"}, "item": [{"name": "A", "event": [{"script": {"exec": ["x"]}}], "request": "https://h"}]}"#.utf8)

    // MARK: Preview decisions

    func testDescribesWhatEachFileHolds() throws {
        XCTAssertEqual(ImportPreview.describe(try CollectionImport.read(postmanCollection, fileName: "a.json")), "Postman collection · 2 requests")
        XCTAssertEqual(ImportPreview.describe(try CollectionImport.read(postmanEnvironment, fileName: "e.json")), "Postman environment · 1 variable")
        let spec = Data("openapi: 3.0.0\ninfo: {title: T}\nservers: [{url: 'https://a'}, {url: 'https://b'}]\npaths:\n  /x:\n    get: {}\n".utf8)
        XCTAssertEqual(ImportPreview.describe(try CollectionImport.read(spec, fileName: "s.yaml")), "OpenAPI spec · 1 request, 1 environment")
    }

    func testImportIsOffUntilEveryFileCanBeImported() {
        var preview = ImportPreview()
        XCTAssertEqual(preview.blocker(selectedName: nil), "", "nothing chosen yet")
        preview.candidates = [.read(postmanCollection, name: "a.json")]
        XCTAssertNil(preview.blocker(selectedName: nil))
        preview.candidates.append(.read(Data("{nope".utf8), name: "bad.json"))
        XCTAssertEqual(preview.candidates[1].detail, "“bad.json” couldn't be read: it isn't valid JSON.")
        XCTAssertEqual(preview.blocker(selectedName: nil), "Remove the files that can't be imported, then try again.")
        preview.candidates.removeLast()
        XCTAssertNil(preview.blocker(selectedName: nil))
    }

    func testEnvironmentsNeedACollectionAndSayWhichOne() {
        var preview = ImportPreview(candidates: [.read(postmanEnvironment, name: "e.json")])
        XCTAssertNil(preview.environmentDestination(selectedName: nil))
        XCTAssertEqual(preview.blocker(selectedName: nil), CollectionImport.Failure.noCollectionForEnvironments.localizedDescription)
        XCTAssertEqual(preview.environmentDestination(selectedName: "Shop"), "Shop")
        XCTAssertNil(preview.blocker(selectedName: "Shop"))
        preview.candidates.insert(.read(postmanCollection, name: "a.json"), at: 0)
        XCTAssertEqual(preview.environmentDestination(selectedName: "Shop"), "API", "the collection imported with them")
    }

    func testNotesAreListedOnce() {
        let preview = ImportPreview(candidates: [.read(withScripts, name: "1.json"), .read(withScripts, name: "2.json")])
        XCTAssertEqual(preview.notes, [ImportSupport.scriptsNote])
    }

    // MARK: Committing

    func testCommitStoresSavesAndKeepsTheUsersPendingEdits() throws {
        let container = try ViewHosting.container()
        let context = container.mainContext
        let mine = Folder(name: "Mine")
        context.insert(mine)
        mine.name = "Mine, edited"
        let outcome = try CollectionImport.commit([try CollectionImport.read(postmanCollection, fileName: "a.json")], context: context, selectedID: mine.persistentModelID)
        XCTAssertFalse(context.hasChanges, "saved")
        XCTAssertEqual(outcome.collections.first?.sortOrder, 1)
        let names = try ModelContext(container).fetch(FetchDescriptor<Folder>()).map(\.name).sorted()
        XCTAssertEqual(names, ["API", "Mine, edited"])
    }

    func testCommitIgnoresASelectedCollectionThatWasDeleted() throws {
        let container = try ViewHosting.container()
        let context = container.mainContext
        let gone = Folder(name: "Gone")
        context.insert(gone)
        try context.save()
        let goneID = gone.persistentModelID
        context.delete(gone)
        try context.save()
        XCTAssertThrowsError(try CollectionImport.commit([try CollectionImport.read(postmanEnvironment, fileName: "e.json")], context: context, selectedID: goneID)) { error in
            XCTAssertEqual(error as? CollectionImport.Failure, .noCollectionForEnvironments)
        }
        XCTAssertTrue(try context.fetch(FetchDescriptor<CollectionEnvironment>()).isEmpty)
    }

    // MARK: Rendering

    func testShowsTheDropAreaSupportedAppsAndADisabledImport() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let hosting = ViewHosting.host(ImportView(selectedCollection: nil), size: CGSize(width: 560, height: 600), appearance: appearance, container: try ViewHosting.container())
            defer { ViewHosting.close(hosting) }
            let text = ViewHosting.text(in: hosting)
            XCTAssertTrue(text.contains("Choose a file or drop it here"), "\(appearance.rawValue): \(text)")
            XCTAssertTrue(text.contains { $0.contains("Supported:") && $0.contains("Postman") && $0.contains("Hoppscotch") && $0.contains("Insomnia") && $0.contains("OpenAPI") })
            let buttons = ViewHosting.buttonLabels(in: hosting)
            XCTAssertTrue(buttons.contains("Choose File…"))
            XCTAssertTrue(buttons.contains("Close"), "the icon-only close button has a label")
            XCTAssertTrue(buttons.contains("Import"))
            XCTAssertTrue(buttons.contains("Cancel"))
        }
    }
}
