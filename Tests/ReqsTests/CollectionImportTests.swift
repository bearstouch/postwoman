import SwiftData
import XCTest

@testable import Reqs

@MainActor
final class CollectionImportTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    private func folders() throws -> [Folder] { try context.fetch(FetchDescriptor<Folder>(sortBy: [SortDescriptor(\.sortOrder)])) }

    private let postmanEnvironment = Data(#"{"name": "Staging", "_postman_variable_scope": "environment", "values": [{"key": "a", "value": "1"}]}"#.utf8)
    private let postmanCollection = Data(#"{"info": {"name": "API"}, "item": [{"name": "Ping", "request": {"method": "GET", "url": "https://h/ping"}}]}"#.utf8)

    func testExportAllAndImportBringsBackEveryCollection() throws {
        let first = Folder(name: "One", sortOrder: 0)
        let second = Folder(name: "Two", sortOrder: 1)
        context.insert(first)
        context.insert(second)
        first.addEnvironment(named: "Prod", color: .red, variables: [Variable(key: "token", value: "hidden", isSecret: true), Variable(key: "host", value: "h")])
        let request = APIRequest(name: "Get", url: "https://h", folder: second)
        context.insert(request)

        let data = try ExportImportService.exportAll([second, first])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("hidden"), "secret values are exported empty")
        let file = try CollectionImport.read(data, fileName: "Reqs Collections.json")
        XCTAssertEqual(file.format, .reqsCollections)
        XCTAssertEqual(file.collections.map(\.name), ["One", "Two"], "sidebar order")

        let outcome = try CollectionImport.store([file], context: context, existing: [first, second], selected: nil)
        XCTAssertEqual(outcome.collections.map(\.name), ["One", "Two"])
        XCTAssertEqual(outcome.collections.map(\.sortOrder), [2, 3], "after the existing collections, which stay")
        XCTAssertEqual(try folders().count, 4)
        XCTAssertEqual(outcome.collections[0].overrideEnvironments.first?.variables.map(\.value), ["", "h"])
        XCTAssertEqual(outcome.collections[1].requests?.first?.url, "https://h")
    }

    func testSingleCollectionFilesStillImport() throws {
        let folder = Folder(name: "Solo")
        context.insert(folder)
        let file = try CollectionImport.read(try ExportImportService.exportFolder(folder), fileName: "Solo.json")
        XCTAssertEqual(file.format, .reqsCollection)
        XCTAssertEqual(file.collections.map(\.name), ["Solo"])
    }

    func testNewerReqsFilesAreStillRefused() {
        let data = Data(#"{"version": "2.0", "exportDate": "2026-01-01T00:00:00Z", "collections": []}"#.utf8)
        XCTAssertThrowsError(try CollectionImport.read(data, fileName: "new.json")) { error in
            XCTAssertEqual(error as? ExportImportService.ImportError, .newerVersion("2.0"))
        }
    }

    func testEnvironmentFileJoinsTheSelectedCollection() throws {
        let selected = Folder(name: "Mine")
        context.insert(selected)
        selected.ensureDefaultEnvironment()
        let file = try CollectionImport.read(postmanEnvironment, fileName: "staging.json")
        let outcome = try CollectionImport.store([file], context: context, existing: [selected], selected: selected)
        XCTAssertTrue(outcome.collections.isEmpty)
        XCTAssertTrue(outcome.environmentTarget === selected)
        XCTAssertEqual(selected.overrideEnvironments.map(\.name), ["Staging"])
        XCTAssertEqual(outcome.addedEnvironments, 1)
    }

    func testEnvironmentFileJoinsTheCollectionImportedWithIt() throws {
        let other = Folder(name: "Other")
        context.insert(other)
        let files = [try CollectionImport.read(postmanCollection, fileName: "api.json"), try CollectionImport.read(postmanEnvironment, fileName: "staging.json")]
        let outcome = try CollectionImport.store(files, context: context, existing: [other], selected: other)
        XCTAssertEqual(outcome.collections.first?.overrideEnvironments.map(\.name), ["Staging"])
        XCTAssertTrue(other.overrideEnvironments.isEmpty)
    }

    func testEnvironmentsWithNowhereToGoStoreNothing() throws {
        let files = [try CollectionImport.read(postmanEnvironment, fileName: "staging.json")]
        XCTAssertThrowsError(try CollectionImport.store(files, context: context, existing: [], selected: nil)) { error in
            XCTAssertEqual(error as? CollectionImport.Failure, .noCollectionForEnvironments)
        }
        XCTAssertTrue(try folders().isEmpty)
        // Two collections and an environment: which one it belongs to isn't known, so the selected one is needed.
        let twoCollections = [try CollectionImport.read(postmanCollection, fileName: "a.json"), try CollectionImport.read(postmanCollection, fileName: "b.json")] + files
        XCTAssertThrowsError(try CollectionImport.store(twoCollections, context: context, existing: [], selected: nil))
        XCTAssertTrue(try folders().isEmpty)
    }

    func testImportedRowsGetIdentitiesOfTheirOwn() throws {
        let files = [try CollectionImport.read(postmanCollection, fileName: "a.json"), try CollectionImport.read(postmanCollection, fileName: "a.json")]
        let outcome = try CollectionImport.store(files, context: context, existing: [], selected: nil)
        XCTAssertEqual(outcome.collections.count, 2)
        XCTAssertNotEqual(outcome.collections[0].id, outcome.collections[1].id)
        XCTAssertEqual(outcome.collections.map { $0.defaultEnvironment != nil }, [true, true])
    }

    func testUnknownAndBrokenFilesSayWhy() {
        XCTAssertThrowsError(try CollectionImport.read(Data(#"{"hello": "world"}"#.utf8), fileName: "x.json")) { error in
            XCTAssertEqual(error as? CollectionImport.Failure, .unrecognized("x.json"))
            XCTAssertTrue(error.localizedDescription.contains("Postman"))
        }
        XCTAssertThrowsError(try CollectionImport.read(Data("{\"info\": ".utf8), fileName: "bad.json")) { error in
            XCTAssertEqual(error as? CollectionImport.Failure, .unreadable("bad.json", "it isn't valid JSON."))
        }
        XCTAssertThrowsError(try CollectionImport.read(Data([0x00, 0xFF, 0xFE, 0x00]), fileName: "bin.json"))
        XCTAssertThrowsError(try CollectionImport.read(Data(count: CollectionImport.maximumFileSize + 1), fileName: "big.json")) { error in
            XCTAssertEqual(error as? CollectionImport.Failure, .tooLarge("big.json"))
        }
    }

    func testFileNameNamesACollectionWithoutOne() throws {
        let file = try CollectionImport.read(Data(#"{"info": {}, "item": []}"#.utf8), fileName: "My API.postman_collection.json")
        XCTAssertEqual(file.collections.first?.name, "My API.postman_collection")
    }

    func testFileMenuPostsImportAndExport() {
        let center = NotificationCenter()
        var names: [Notification.Name] = []
        let tokens = [Notification.Name.importCollections, .exportAllCollections].map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { names.append($0.name) }
        }
        center.post(name: .importCollections, object: nil)
        center.post(name: .exportAllCollections, object: nil)
        tokens.forEach(center.removeObserver)
        XCTAssertEqual(names, [.importCollections, .exportAllCollections])
    }

    func testInsomniaEnvironmentOnlyExportIsAnEnvironment() throws {
        let data = Data(#"{"_type": "export", "__export_format": 4, "resources": [{"_id": "env_1", "_type": "environment", "name": "Shared", "data": {"a": "1"}}]}"#.utf8)
        let file = try CollectionImport.read(data, fileName: "env.json")
        XCTAssertEqual(file.format, .insomniaEnvironment)
        XCTAssertEqual(file.environments.map(\.name), ["Shared"])
    }

}
