import SwiftData
import XCTest

@testable import PostWoman

final class ExportImportServiceTests: XCTestCase {
    func testExportedFolderImportsWithRequestsInOrder() throws {
        let folder = Folder(name: "Users")
        let second = APIRequest(name: "Create", url: "https://api.example.com/users", method: .post, folder: folder)
        second.sortOrder = 1
        second.bodyType = .json
        second.bodyContent = #"{"name":"Ada"}"#
        let first = APIRequest(name: "List", url: "https://api.example.com/users", folder: folder)
        first.headers = [KeyValuePair(key: "Accept", value: "application/json")]
        first.authenticationType = .bearer
        first.authBearerToken = "token"
        folder.requests = [second, first]

        let data = try ExportImportService.exportFolder(folder)
        let container = try ModelContainer(for: Folder.self, APIRequest.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let imported = try ExportImportService.importFolder(from: data, context: context, existingFolderCount: 3)

        XCTAssertEqual(imported.name, "Users")
        XCTAssertEqual(imported.sortOrder, 3)
        let requests = (imported.requests ?? []).sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(requests.map(\.name), ["List", "Create"])
        XCTAssertEqual(requests[0].headers.map(\.key), ["Accept"])
        XCTAssertEqual(requests[0].authenticationType, .bearer)
        XCTAssertEqual(requests[0].authBearerToken, "token")
        XCTAssertEqual(requests[1].method, .post)
        XCTAssertEqual(requests[1].bodyContent, #"{"name":"Ada"}"#)
    }

    func testImportRejectsMalformedData() throws {
        let container = try ModelContainer(for: Folder.self, APIRequest.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        XCTAssertThrowsError(try ExportImportService.importFolder(from: Data("{}".utf8), context: ModelContext(container), existingFolderCount: 0))
    }
}
