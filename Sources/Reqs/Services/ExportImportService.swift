import Foundation
import SwiftData
import AppKit

/// Service for exporting and importing folder collections as JSON files.
/// Enables sharing API request collections between users.
enum ExportImportService {

    /// The current export format version.
    static let formatVersion = "1.0"

    /// Why a file was not imported, beyond it not being a collection file at all.
    enum ImportError: LocalizedError, Equatable {
        /// The file's format major version is newer than ``formatVersion``: a newer app wrote it, and fields could be lost.
        case newerVersion(String)
        /// The file's version is not a dotted number, so which format it uses is unknown.
        case unknownVersion(String)

        var errorDescription: String? {
            switch self {
            case .newerVersion(let version):
                return "This file was made by a newer Reqs (version \(version)), so this one can't read all of it. Update Reqs, then import it again."
            case .unknownVersion(let version):
                return "This file's format version (\"\(version)\") isn't one Reqs knows, so it wasn't imported."
            }
        }
    }

    // MARK: - Codable Structures

    /// Root container for exported data.
    struct ExportContainer: Codable {
        let version: String
        let exportDate: Date
        let folder: ExportableFolder
    }

    /// Every collection at once (File → Export All Collections…), in the same shape as one collection's file.
    struct BackupContainer: Codable {
        let version: String
        let exportDate: Date
        let collections: [ExportableFolder]
    }

    /// Codable representation of a Folder.
    struct ExportableFolder: Codable {
        let name: String
        let requests: [ExportableRequest]
        /// The collection's environments, Default first. Absent in files from before environments.
        var environments: [ExportableEnvironment]? = nil
        /// The name of the environment its requests used, if not Default.
        var selectedEnvironment: String? = nil
    }

    /// Codable representation of a CollectionEnvironment. Secret values are exported empty.
    struct ExportableEnvironment: Codable, Equatable {
        let name: String
        let isDefault: Bool
        let color: String
        let variables: [Variable]
    }

    /// Codable representation of an APIRequest.
    struct ExportableRequest: Codable {
        let name: String
        let url: String
        let method: HTTPMethod
        let headers: [KeyValuePair]
        let queryParams: [KeyValuePair]
        let bodyType: ContentType
        let bodyContent: String
        let authenticationType: AuthenticationType
        let authBearerToken: String?
        let authBasicUsername: String?
        let authBasicPassword: String?
        let authOAuthConfig: OAuthConfig?
    }

    // MARK: - Export

    /// Exports a folder and all its requests to JSON data.
    /// - Parameter folder: The folder to export
    /// - Returns: JSON data representing the folder and its requests
    static func exportFolder(_ folder: Folder) throws -> Data {
        try encoder.encode(ExportContainer(version: formatVersion, exportDate: Date(), folder: exportable(folder)))
    }

    /// Exports every collection, in sidebar order, to one file. Secret values are exported empty, as for one collection.
    static func exportAll(_ folders: [Folder]) throws -> Data {
        let ordered = folders.sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
        return try encoder.encode(BackupContainer(version: formatVersion, exportDate: Date(), collections: ordered.map(exportable)))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// A collection as it is written to a file.
    static func exportable(_ folder: Folder) -> ExportableFolder {
        let requests = (folder.requests ?? [])
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { request in
                ExportableRequest(
                    name: request.name,
                    url: request.url,
                    method: request.method,
                    headers: request.headers,
                    queryParams: request.queryParams,
                    bodyType: request.bodyType,
                    bodyContent: request.bodyContent,
                    authenticationType: request.authenticationType,
                    authBearerToken: request.authBearerToken,
                    authBasicUsername: request.authBasicUsername,
                    authBasicPassword: request.authBasicPassword,
                    authOAuthConfig: request.authOAuthConfig
                )
            }

        let environments = ([folder.defaultEnvironment].compactMap { $0 } + folder.overrideEnvironments).map { environment in
            ExportableEnvironment(
                name: environment.name, isDefault: environment.isDefault, color: environment.colorName,
                variables: environment.variables.map { variable in
                    var copy = variable
                    if copy.isSecret { copy.value = "" }
                    return copy
                })
        }

        return ExportableFolder(name: folder.name, requests: requests, environments: environments, selectedEnvironment: folder.selectedEnvironment?.name)
    }

    /// Shows a save panel and exports the folder to a JSON file.
    /// - Parameter folder: The folder to export
    @MainActor
    static func exportFolderWithDialog(_ folder: Folder) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "\(folder.name).json"
        savePanel.title = "Export Collection"
        savePanel.message = "Choose a location to save the collection"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            write({ try exportFolder(folder) }, to: url)
        }
    }

    /// Shows a save panel and exports every collection to one file, which Import reads back.
    @MainActor
    static func exportAllWithDialog(_ folders: [Folder]) {
        guard !folders.isEmpty else {
            showAlert("Nothing to Export", "There are no collections yet.", style: .informational)
            return
        }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "Reqs Collections.json"
        savePanel.title = "Export All Collections"
        savePanel.message = "Saves \(folders.count == 1 ? "the collection" : "all \(folders.count) collections") and their environments. Secret values are saved empty."
        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            write({ try exportAll(folders) }, to: url)
        }
    }

    @MainActor
    private static func write(_ data: () throws -> Data, to url: URL) {
        do {
            try data().write(to: url, options: .atomic)
        } catch {
            showAlert("Export Failed", error.localizedDescription, style: .critical)
        }
    }

    @MainActor
    static func showAlert(_ title: String, _ text: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = style
        alert.runModal()
    }

    // MARK: - Import

    /// Imports a folder from JSON data.
    /// - Parameters:
    ///   - data: The JSON data to import
    ///   - context: The SwiftData model context
    ///   - existingFolderCount: The imported collection's sortOrder: `Folder.nextSortOrder(after:)`, which is the count
    ///     of existing folders only while none was deleted
    /// - Returns: The newly created Folder
    static func importFolder(from data: Data, context: ModelContext, existingFolderCount: Int) throws -> Folder {
        insert(try decodeFolder(from: data), context: context, sortOrder: existingFolderCount)
    }

    /// The collection of a file written by ``exportFolder(_:)``.
    static func decodeFolder(from data: Data) throws -> ExportableFolder {
        try decode(ExportContainer.self, from: data).folder
    }

    /// The collections of a file written by ``exportAll(_:)``.
    static func backupCollections(from data: Data) throws -> [ExportableFolder] {
        try decode(BackupContainer.self, from: data).collections
    }

    /// A Reqs file, its version checked first, so a newer file is reported as newer even when the rest of it has a shape
    /// this app doesn't know.
    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try checkVersion(try decoder.decode(VersionHeader.self, from: data).version)
        return try decoder.decode(type, from: data)
    }

    /// Stores a collection read from a file (Reqs's own or converted from another app's) as a new collection at `sortOrder`.
    @discardableResult
    static func insert(_ file: ExportableFolder, context: ModelContext, sortOrder: Int) -> Folder {
        let folder = Folder(name: file.name, sortOrder: sortOrder)
        context.insert(folder)

        // Environments: Default's name and variables, then the others in order; files from before environments get an empty Default.
        // A blank Default name keeps "Default", as a rename to a blank name would.
        let defaultEnvironment = folder.ensureDefaultEnvironment()
        for exported in file.environments ?? [] {
            if exported.isDefault {
                if !exported.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { defaultEnvironment.name = exported.name }
                defaultEnvironment.variables = fresh(exported.variables)
            } else {
                let environment = folder.addEnvironment(
                    named: exported.name, color: EnvironmentColor(rawValue: exported.color) ?? .gray, variables: fresh(exported.variables))
                // The first of that name: names aren't unique, and the last match would pick another environment.
                if folder.selectedEnvironment == nil, exported.name == file.selectedEnvironment { folder.selectedEnvironment = environment }
            }
        }

        // Create all requests
        for (index, exportedRequest) in file.requests.enumerated() {
            let request = APIRequest(
                name: exportedRequest.name,
                url: exportedRequest.url,
                method: exportedRequest.method,
                folder: folder
            )
            request.sortOrder = index
            request.headers = fresh(exportedRequest.headers)
            request.queryParams = fresh(exportedRequest.queryParams)
            request.bodyType = exportedRequest.bodyType
            request.bodyContent = exportedRequest.bodyContent
            request.authenticationType = exportedRequest.authenticationType
            request.authBearerToken = exportedRequest.authBearerToken
            request.authBasicUsername = exportedRequest.authBasicUsername
            request.authBasicPassword = exportedRequest.authBasicPassword
            request.authOAuthConfig = exportedRequest.authOAuthConfig

            context.insert(request)
        }

        return folder
    }

    /// Just the `version` key of a file, read before the rest.
    private struct VersionHeader: Decodable {
        let version: String
    }

    /// The rows of a file with identities of their own: the file's IDs would be shared with the collection it was exported
    /// from (or with a second import of it), and a hand-edited file can repeat one, so deleting a row would delete its twin.
    static func fresh(_ variables: [Variable]) -> [Variable] {
        variables.map { Variable(key: $0.key, value: $0.value, isEnabled: $0.isEnabled, isSecret: $0.isSecret) }
    }

    private static func fresh(_ pairs: [KeyValuePair]) -> [KeyValuePair] {
        pairs.map { KeyValuePair(key: $0.key, value: $0.value, isEnabled: $0.isEnabled) }
    }

    /// Accepts a dotted number whose major part is at most ``formatVersion``'s (every file so far says "1.0").
    /// Minor versions only add optional fields, which older apps ignore.
    private static func checkVersion(_ version: String) throws {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else {
            throw ImportError.unknownVersion(version)
        }
        let current = Int(formatVersion.prefix { $0 != "." }) ?? 1
        // A major part too long for an Int is newer than any this app knows.
        guard let major = Int(parts[0]), major <= current else { throw ImportError.newerVersion(version) }
    }
}
