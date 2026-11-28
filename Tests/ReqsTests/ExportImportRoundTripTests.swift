import SwiftData
import XCTest

@testable import Reqs

@MainActor
final class ExportImportRoundTripTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() async throws {
        container = nil
    }

    private let oauth = OAuthConfig(
        authorizationURL: "https://auth.example.com/authorize", tokenURL: "https://auth.example.com/token", clientID: "client", clientSecret: "{{clientSecret}}",
        scope: "read write", redirectURI: "reqs://callback")

    /// A collection with every request field set, a renamed Default with a secret, and two overrides (one selected).
    private func makeFullCollection() -> Folder {
        let folder = Folder(name: "Payments 💳")
        context.insert(folder)
        let defaults = folder.ensureDefaultEnvironment()
        defaults.name = "Local"
        defaults.variables = [
            Variable(key: "baseUrl", value: "http://localhost:8080"), Variable(key: "apiKey", value: "sk_live_123", isSecret: true),
            Variable(key: "old", value: "kept", isEnabled: false)
        ]
        let staging = folder.addEnvironment(
            named: "Staging", color: .orange, variables: [Variable(key: "baseUrl", value: "https://staging.example.com"), Variable(key: "pw", value: "hunter2", isSecret: true)])
        folder.addEnvironment(named: "Production", color: .red, variables: [Variable(key: "baseUrl", value: "https://example.com")])
        folder.selectedEnvironment = staging

        let methods: [HTTPMethod] = [.get, .post, .put, .delete]
        let bodies: [ContentType] = [.none, .json, .formData, .urlEncoded, .xml, .text]
        let auths: [AuthenticationType] = [.none, .bearer, .basic, .oauth2]
        for index in 0..<6 {
            let request = APIRequest(name: "Request \(index) – ü", url: "{{baseUrl}}/items/\(index)?q=a%20b", method: methods[index % methods.count], folder: folder)
            request.sortOrder = 5 - index
            request.headers = [KeyValuePair(key: "X-Api-Key", value: "{{apiKey}}"), KeyValuePair(key: "X-Off", value: "1", isEnabled: false)]
            request.queryParams = [KeyValuePair(key: "page", value: "\(index)"), KeyValuePair(key: "debug", value: "true", isEnabled: false)]
            request.bodyType = bodies[index]
            request.bodyContent = bodies[index] == .none ? "" : #"{"n":\#(index),"s":"line\nbreak \"quoted\""}"#
            request.authenticationType = auths[index % auths.count]
            request.authBearerToken = "{{token}}"
            request.authBasicUsername = "ada"
            request.authBasicPassword = "{{pw}}"
            request.authOAuthConfig = index == 3 ? oauth : nil
            context.insert(request)
        }
        return folder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func sortedRequests(_ folder: Folder) -> [APIRequest] { (folder.requests ?? []).sorted { $0.sortOrder < $1.sortOrder } }

    private func storeCounts() throws -> [Int] {
        [
            try context.fetchCount(FetchDescriptor<Folder>()), try context.fetchCount(FetchDescriptor<APIRequest>()),
            try context.fetchCount(FetchDescriptor<CollectionEnvironment>())
        ]
    }

    // MARK: Round trip

    func testEveryRequestFieldSurvivesARoundTripInDisplayOrder() throws {
        let original = makeFullCollection()
        let data = try ExportImportService.exportFolder(original)
        let imported = try ExportImportService.importFolder(from: data, context: context, existingFolderCount: 7)
        XCTAssertNotIdentical(imported, original)
        XCTAssertNotEqual(imported.id, original.id)
        XCTAssertEqual(imported.name, "Payments 💳")
        XCTAssertEqual(imported.sortOrder, 7)

        let before = sortedRequests(original)
        let after = sortedRequests(imported)
        XCTAssertEqual(after.map(\.name), before.map(\.name), "Requests keep the order they were shown in")
        XCTAssertEqual(after.map(\.sortOrder), Array(0..<6), "Sort orders are renumbered from 0")
        for (old, new) in zip(before, after) {
            XCTAssertNotEqual(new.id, old.id)
            XCTAssertIdentical(new.folder, imported)
            // Every field, with rows compared by what they say: each imported row has an ID of its own.
            var expected = RequestSnapshot(old), actual = RequestSnapshot(new)
            func rows(_ pairs: [KeyValuePair]) -> [String] { pairs.map { "\($0.key)=\($0.value) \($0.isEnabled)" } }
            XCTAssertEqual(rows(actual.headers), rows(expected.headers), old.name)
            XCTAssertEqual(rows(actual.queryParams), rows(expected.queryParams), old.name)
            (expected.headers, expected.queryParams, actual.headers, actual.queryParams) = ([], [], [], [])
            XCTAssertEqual(actual, expected, old.name)
            XCTAssertEqual(new.authOAuthConfig, old.authOAuthConfig, old.name)
        }
        XCTAssertEqual(after[2].authOAuthConfig, oauth)
        // A File body exports its name only: testAnExportKeepsTheFileNameButNeverTheFile.
        XCTAssertEqual(Set(after.map(\.bodyType)), Set(ContentType.allCases).subtracting([.file]))
        XCTAssertEqual(Set(after.map(\.authenticationType)), Set(AuthenticationType.allCases))
    }

    func testEnvironmentsSurviveARoundTripWithSecretsEmptied() throws {
        let original = makeFullCollection()
        let imported = try ExportImportService.importFolder(from: try ExportImportService.exportFolder(original), context: context, existingFolderCount: 0)

        let defaults = try XCTUnwrap(imported.defaultEnvironment)
        XCTAssertEqual(defaults.variables.map(\.key), ["baseUrl", "apiKey", "old"])
        XCTAssertEqual(defaults.variables.map(\.value), ["http://localhost:8080", "", "kept"])
        XCTAssertEqual(defaults.variables.map(\.isSecret), [false, true, false])
        XCTAssertEqual(defaults.variables.map(\.isEnabled), [true, true, false], "Disabled variables are kept")
        XCTAssertEqual(defaults.color, .blue)

        XCTAssertEqual(imported.overrideEnvironments.map(\.name), ["Staging", "Production"])
        XCTAssertEqual(imported.overrideEnvironments.map(\.color), [.orange, .red])
        XCTAssertEqual(imported.overrideEnvironments.map(\.sortOrder), [0, 1])
        XCTAssertEqual(imported.overrideEnvironments[0].variables.map(\.value), ["https://staging.example.com", ""])
        XCTAssertEqual(imported.selectedEnvironment?.name, "Staging")
        XCTAssertEqual(imported.environments?.filter(\.isDefault).count, 1, "Exactly one Default")
        XCTAssertEqual(imported.variableResolver.resolve("{{baseUrl}}/{{apiKey}}"), "https://staging.example.com/", "An emptied secret resolves to nothing")
        let importedIDs = Set((imported.environments ?? []).map(\.id))
        XCTAssertTrue(importedIDs.isDisjoint(with: (original.environments ?? []).map(\.id)), "Imported environments are new models")
    }

    func testNoSecretValueAppearsAnywhereInTheExportedFile() throws {
        let data = try ExportImportService.exportFolder(makeFullCollection())
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["sk_live_123", "hunter2"] { XCTAssertFalse(text.contains(secret), secret) }
        XCTAssertTrue(text.contains("localhost:8080"), "Plain values are exported")
        XCTAssertTrue(text.contains("\"isSecret\" : true"), "The secret flag is kept so the importer knows to fill it in")
    }

    func testExportingDoesNotChangeTheCollection() throws {
        let folder = makeFullCollection()
        try context.save()
        _ = try ExportImportService.exportFolder(folder)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(folder.defaultEnvironment?.variables.first { $0.key == "apiKey" }?.value, "sk_live_123", "Only the copy is emptied")
        XCTAssertEqual(folder.overrideEnvironments[0].variables.last?.value, "hunter2")
    }

    func testExportedFileShape() throws {
        let data = try ExportImportService.exportFolder(makeFullCollection())
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "exportDate", "folder"])
        XCTAssertEqual(json["version"] as? String, "1.0")
        XCTAssertNotNil(ISO8601DateFormatter().date(from: try XCTUnwrap(json["exportDate"] as? String)), "Dates are ISO 8601")
        let folder = try XCTUnwrap(json["folder"] as? [String: Any])
        XCTAssertEqual(folder["selectedEnvironment"] as? String, "Staging")
        let environments = try XCTUnwrap(folder["environments"] as? [[String: Any]])
        XCTAssertEqual(environments.map { $0["name"] as? String }, ["Local", "Staging", "Production"], "Default first")
        XCTAssertEqual(environments.map { $0["isDefault"] as? Bool }, [true, false, false])
        XCTAssertEqual((folder["requests"] as? [Any])?.count, 6)
    }

    func testExportingIsDeterministicApartFromTheDate() throws {
        let folder = makeFullCollection()
        func withoutDate(_ data: Data) throws -> NSDictionary {
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data, options: .mutableContainers) as? NSMutableDictionary)
            json.removeObject(forKey: "exportDate")
            return json
        }
        XCTAssertEqual(try withoutDate(try ExportImportService.exportFolder(folder)), try withoutDate(try ExportImportService.exportFolder(folder)))
    }

    func testAnEmptyCollectionRoundTrips() throws {
        let folder = Folder(name: "Empty")
        context.insert(folder)
        let imported = try ExportImportService.importFolder(from: try ExportImportService.exportFolder(folder), context: context, existingFolderCount: 1)
        XCTAssertEqual(imported.name, "Empty")
        XCTAssertEqual(imported.requests?.count ?? 0, 0)
        XCTAssertNotNil(imported.defaultEnvironment, "An imported collection always has a Default")
        XCTAssertEqual(imported.overrideEnvironments, [])
        XCTAssertNil(imported.selectedEnvironmentID)
    }

    func testTheFirstOfTwoEnvironmentsWithTheSameNameStaysSelected() throws {
        let folder = Folder(name: "Twins")
        context.insert(folder)
        folder.ensureDefaultEnvironment()
        let first = folder.addEnvironment(named: "Staging", color: .orange, variables: [Variable(key: "host", value: "first.example.com")])
        folder.addEnvironment(named: "Staging", color: .red, variables: [Variable(key: "host", value: "second.example.com")])
        folder.selectedEnvironment = first
        let imported = try ExportImportService.importFolder(from: try ExportImportService.exportFolder(folder), context: context, existingFolderCount: 1)
        XCTAssertEqual(imported.selectedEnvironment?.variables.map(\.value), ["first.example.com"], "Requests resolve with the same environment as before")
    }

    func testImportedRowsGetIdentitiesOfTheirOwn() throws {
        let original = makeFullCollection()
        let data = try ExportImportService.exportFolder(original)
        let first = try ExportImportService.importFolder(from: data, context: context, existingFolderCount: 1)
        let second = try ExportImportService.importFolder(from: data, context: context, existingFolderCount: 2)
        func ids(_ folder: Folder) -> [UUID] {
            (folder.environments ?? []).flatMap { $0.variables.map(\.id) } + (folder.requests ?? []).flatMap { $0.headers.map(\.id) + $0.queryParams.map(\.id) }
        }
        let all = ids(original) + ids(first) + ids(second)
        XCTAssertFalse(ids(original).isEmpty)
        XCTAssertEqual(Set(all).count, all.count, "No variable, header or parameter shares an ID with the source or with another import")
    }

    func testAFileThatRepeatsARowIDStillImportsDistinctRows() throws {
        let id = UUID().uuidString
        let file = """
            {"version":"1.0","exportDate":"2026-01-01T00:00:00Z","folder":{"name":"Edited","requests":[],"environments":[{"name":"Default","isDefault":true,"color":"gray",
            "variables":[{"id":"\(id)","key":"a","value":"1","isEnabled":true,"isSecret":false},{"id":"\(id)","key":"b","value":"2","isEnabled":true,"isSecret":false}]}]}}
            """
        let imported = try ExportImportService.importFolder(from: Data(file.utf8), context: context, existingFolderCount: 0)
        let variables = try XCTUnwrap(imported.defaultEnvironment?.variables)
        XCTAssertEqual(variables.map(\.key), ["a", "b"])
        XCTAssertNotEqual(variables[0].id, variables[1].id, "Deleting one row in the editor must not delete the other")
    }

    func testAStaleSelectionIsNotExported() throws {
        let folder = makeFullCollection()
        let staging = try XCTUnwrap(folder.selectedEnvironment)
        context.delete(staging)
        try context.save()
        let data = try ExportImportService.exportFolder(folder)
        let container = try decoder().decode(ExportImportService.ExportContainer.self, from: data)
        XCTAssertNil(container.folder.selectedEnvironment)
        XCTAssertEqual(container.folder.environments?.map(\.name), ["Local", "Production"])
        XCTAssertNil(try ExportImportService.importFolder(from: data, context: context, existingFolderCount: 0).selectedEnvironment)
    }

    func testARenamedDefaultKeepsItsNameThroughARoundTrip() throws {
        let imported = try ExportImportService.importFolder(from: try ExportImportService.exportFolder(makeFullCollection()), context: context, existingFolderCount: 0)
        XCTAssertEqual(imported.defaultEnvironment?.name, "Local")
        XCTAssertEqual(imported.defaultEnvironmentName, "Local")
        XCTAssertEqual(imported.environments?.filter(\.isDefault).count, 1)
    }

    // MARK: Importing hand-written and older files

    private func file(environments: String? = nil, selected: String? = nil, requests: String = "[]", version: String = "1.0") -> Data {
        var folder = #""name":"Hand written","requests":\#(requests)"#
        if let environments { folder += #","environments":\#(environments)"# }
        if let selected { folder += #","selectedEnvironment":"\#(selected)""# }
        return Data(#"{"version":"\#(version)","exportDate":"2026-01-01T00:00:00Z","folder":{\#(folder)}}"#.utf8)
    }

    private func environment(_ name: String, isDefault: Bool = false, color: String = "green", variables: String = "[]") -> String {
        #"{"name":"\#(name)","isDefault":\#(isDefault),"color":"\#(color)","variables":\#(variables)}"#
    }

    func testUnknownColorsImportAsGray() throws {
        let data = file(environments: "[\(environment("Default", isDefault: true)), \(environment("Odd", color: "chartreuse")), \(environment("Ok", color: "pink"))]")
        let imported = try ExportImportService.importFolder(from: data, context: context, existingFolderCount: 0)
        XCTAssertEqual(imported.overrideEnvironments.map(\.color), [.gray, .pink])
    }

    func testASelectionThatNamesNoOverrideImportsAsDefaultOnly() throws {
        for selected in ["Default", "Missing", ""] {
            let data = file(environments: "[\(environment("Default", isDefault: true)), \(environment("Staging"))]", selected: selected)
            let imported = try ExportImportService.importFolder(from: data, context: context, existingFolderCount: 0)
            XCTAssertNil(imported.selectedEnvironment, selected)
            XCTAssertEqual(imported.activeEnvironmentName, "Default", selected)
        }
    }

    func testABlankDefaultNameImportsAsDefault() throws {
        for name in ["", "   ", "\\n\\t"] {
            let data = file(environments: "[\(environment(name, isDefault: true)), \(environment("Staging"))]")
            let imported = try ExportImportService.importFolder(from: data, context: context, existingFolderCount: 0)
            XCTAssertEqual(imported.defaultEnvironment?.name, "Default", name.debugDescription)
            XCTAssertEqual(imported.overrideEnvironments.map(\.name), ["Staging"], name.debugDescription)
        }
    }

    func testADefaultNameFromAHandWrittenFileIsKept() throws {
        let data = file(environments: "[\(environment("Dev box", isDefault: true))]")
        let imported = try ExportImportService.importFolder(from: data, context: context, existingFolderCount: 0)
        XCTAssertEqual(imported.defaultEnvironmentName, "Dev box")
        XCTAssertEqual(imported.activeEnvironmentName, "Dev box")
    }

    func testAFileWithoutADefaultStillGetsOne() throws {
        let variables = #"[{"id":"7E1C5B7A-1D2B-4C3D-9E8F-000000000001","key":"host","value":"staging","isEnabled":true,"isSecret":false}]"#
        let data = file(environments: "[\(environment("Staging", variables: variables))]", selected: "Staging")
        let imported = try ExportImportService.importFolder(from: data, context: context, existingFolderCount: 0)
        XCTAssertEqual(imported.defaultEnvironment?.variables, [])
        XCTAssertEqual(imported.selectedEnvironment?.name, "Staging")
        XCTAssertEqual(imported.variableResolver.resolve("{{host}}"), "staging")
    }

    func testUnknownKeysAreIgnored() throws {
        let data = Data(
            #"{"version":"1.0","exportDate":"2026-01-01T00:00:00Z","app":"other","folder":{"name":"Extra","requests":[],"subfolders":[],"color":"red"}}"#.utf8)
        XCTAssertEqual(try ExportImportService.importFolder(from: data, context: context, existingFolderCount: 0).name, "Extra")
    }

    func testImportingTheSameFileTwiceMakesTwoIndependentCollections() throws {
        let data = try ExportImportService.exportFolder(makeFullCollection())
        let first = try ExportImportService.importFolder(from: data, context: context, existingFolderCount: 1)
        let second = try ExportImportService.importFolder(from: data, context: context, existingFolderCount: 2)
        try context.save()
        XCTAssertEqual(first.name, second.name, "Names may repeat; nothing is merged or overwritten")
        XCTAssertEqual([first.sortOrder, second.sortOrder], [1, 2])
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(Set((first.requests ?? []).map(\.id)).isDisjoint(with: (second.requests ?? []).map(\.id)))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Folder>()), 3)

        first.defaultEnvironment?.variables[0].value = "changed"
        first.selectedEnvironment = nil
        XCTAssertEqual(second.defaultEnvironment?.variables[0].value, "http://localhost:8080")
        XCTAssertEqual(second.selectedEnvironment?.name, "Staging")
    }

    // MARK: Rejected input

    func testMalformedInputIsRejectedWithoutChangingTheStore() throws {
        let existing = makeFullCollection()
        try context.save()
        let countsBefore = try storeCounts()
        let request = #"{"name":"R","url":"u","method":"GET","headers":[],"queryParams":[],"bodyType":"None","bodyContent":"","authenticationType":"None"}"#
        let cases: [(String, Data)] = [
            ("empty", Data()),
            ("whitespace", Data("  \n".utf8)),
            ("not JSON", Data("collection".utf8)),
            ("binary", Data([0xFF, 0xFE, 0x00, 0x01])),
            ("empty object", Data("{}".utf8)),
            ("array", Data("[]".utf8)),
            ("null", Data("null".utf8)),
            ("truncated", try ExportImportService.exportFolder(existing).prefix(120)),
            ("no folder", Data(#"{"version":"1.0","exportDate":"2026-01-01T00:00:00Z"}"#.utf8)),
            ("null folder", Data(#"{"version":"1.0","exportDate":"2026-01-01T00:00:00Z","folder":null}"#.utf8)),
            ("no version", Data(#"{"exportDate":"2026-01-01T00:00:00Z","folder":{"name":"X","requests":[]}}"#.utf8)),
            ("bad date", Data(#"{"version":"1.0","exportDate":"yesterday","folder":{"name":"X","requests":[]}}"#.utf8)),
            ("no requests", Data(#"{"version":"1.0","exportDate":"2026-01-01T00:00:00Z","folder":{"name":"X"}}"#.utf8)),
            ("name not a string", Data(#"{"version":"1.0","exportDate":"2026-01-01T00:00:00Z","folder":{"name":5,"requests":[]}}"#.utf8)),
            ("unknown method", file(requests: "[\(request.replacingOccurrences(of: "\"GET\"", with: "\"TRACE\""))]")),
            ("unknown body type", file(requests: "[\(request.replacingOccurrences(of: "\"bodyType\":\"None\"", with: "\"bodyType\":\"YAML\""))]")),
            ("unknown auth", file(requests: "[\(request.replacingOccurrences(of: "\"authenticationType\":\"None\"", with: "\"authenticationType\":\"Digest\""))]")),
            ("environment without variables", file(environments: #"[{"name":"S","isDefault":false,"color":"red"}]"#)),
            ("variable without a value", file(environments: "[\(environment("S", variables: #"[{"id":"7E1C5B7A-1D2B-4C3D-9E8F-000000000001","key":"k"}]"#))]"))
        ]
        for (name, data) in cases {
            XCTAssertThrowsError(try ExportImportService.importFolder(from: data, context: context, existingFolderCount: 1), name)
            XCTAssertEqual(try storeCounts(), countsBefore, "\(name) left the store as it was")
        }
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(existing.overrideEnvironments.map(\.name), ["Staging", "Production"])
        XCTAssertEqual(existing.selectedEnvironment?.name, "Staging")
    }

    func testAFileFromANewerFormatIsRejectedWithoutChangingTheStore() throws {
        _ = makeFullCollection()
        try context.save()
        let countsBefore = try storeCounts()
        let newerShape = Data(#"{"version":"3.1","exportDate":"2026-01-01T00:00:00Z","collections":[]}"#.utf8)
        for (version, data) in [("99.0", file(version: "99.0")), ("2.0", file(version: "2.0")), ("2", file(version: "2")), ("99999999999999999999.0", file(version: "99999999999999999999.0")), ("3.1", newerShape)] {
            XCTAssertThrowsError(try ExportImportService.importFolder(from: data, context: context, existingFolderCount: 1), version) { error in
                XCTAssertEqual(error as? ExportImportService.ImportError, .newerVersion(version), version)
                XCTAssertTrue(error.localizedDescription.hasPrefix("This file was made by a newer Reqs (version \(version))"), error.localizedDescription)
            }
            XCTAssertEqual(try storeCounts(), countsBefore, "\(version) left the store as it was")
        }
        XCTAssertFalse(context.hasChanges)
    }

    func testAFileWithAnUnreadableVersionIsRejected() throws {
        for version in ["", "abc", "v1.0", "-1.0", " 1.0"] {
            XCTAssertThrowsError(try ExportImportService.importFolder(from: file(version: version), context: context, existingFolderCount: 0), version) { error in
                XCTAssertEqual(error as? ExportImportService.ImportError, .unknownVersion(version), version)
            }
        }
        XCTAssertEqual(try storeCounts(), [0, 0, 0])
    }

    func testFilesFromThisFormatVersionImport() throws {
        XCTAssertEqual(ExportImportService.formatVersion, "1.0")
        for version in ["1.0", "1", "1.9", "1.0.1", "0.9"] {
            XCTAssertEqual(try ExportImportService.importFolder(from: file(version: version), context: context, existingFolderCount: 0).name, "Hand written", version)
        }
    }

    func testAValidRequestAfterAMalformedOneStillRejectsTheWholeFile() throws {
        let good = #"{"name":"Good","url":"u","method":"GET","headers":[],"queryParams":[],"bodyType":"None","bodyContent":"","authenticationType":"None"}"#
        let bad = good.replacingOccurrences(of: "\"GET\"", with: "\"TRACE\"")
        XCTAssertThrowsError(try ExportImportService.importFolder(from: file(requests: "[\(good),\(bad)]"), context: context, existingFolderCount: 0))
        XCTAssertEqual(try storeCounts(), [0, 0, 0], "Nothing is half imported")
    }

    func testARequestWithoutOptionalCredentialsImports() throws {
        let minimal = #"{"name":"Min","url":"https://x","method":"DELETE","headers":[],"queryParams":[],"bodyType":"XML","bodyContent":"<a/>","authenticationType":"None"}"#
        let imported = try ExportImportService.importFolder(from: file(requests: "[\(minimal)]"), context: context, existingFolderCount: 0)
        let request = try XCTUnwrap(imported.requests?.first)
        XCTAssertEqual(request.method, .delete)
        XCTAssertEqual(request.bodyType, .xml)
        XCTAssertNil(request.authBearerToken)
        XCTAssertNil(request.authBasicUsername)
        XCTAssertNil(request.authBasicPassword)
        XCTAssertNil(request.authOAuthConfig)
    }
}
