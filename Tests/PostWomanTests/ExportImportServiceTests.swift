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
        let container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
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

    func testEveryMethodSurvivesExportAndImport() throws {
        let folder = Folder(name: "Methods")
        folder.requests = HTTPMethod.allCases.enumerated().map { index, method in
            let request = APIRequest(name: method.rawValue, url: "https://h", method: method, folder: folder)
            request.sortOrder = index
            return request
        }
        let container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let imported = try ExportImportService.importFolder(from: try ExportImportService.exportFolder(folder), context: ModelContext(container), existingFolderCount: 0)
        XCTAssertEqual((imported.requests ?? []).sorted { $0.sortOrder < $1.sortOrder }.map(\.method), HTTPMethod.allCases)
    }

    func testImportRejectsMalformedData() throws {
        let container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        XCTAssertThrowsError(try ExportImportService.importFolder(from: Data("{}".utf8), context: ModelContext(container), existingFolderCount: 0))
    }
}
