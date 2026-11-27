import Foundation
import SwiftData
import AppKit

/// Service for exporting and importing folder collections as JSON files.
/// Enables sharing API request collections between users.
enum ExportImportService {

    /// The current export format version.
    static let formatVersion = "1.0"

    // MARK: - Codable Structures

    /// Root container for exported data.
    struct ExportContainer: Codable {
        let version: String
        let exportDate: Date
        let folder: ExportableFolder
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

        let exportableFolder = ExportableFolder(
            name: folder.name,
            requests: requests,
            environments: environments,
            selectedEnvironment: folder.selectedEnvironment?.name
        )

        let container = ExportContainer(
            version: formatVersion,
            exportDate: Date(),
            folder: exportableFolder
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        return try encoder.encode(container)
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

            do {
                let data = try exportFolder(folder)
                try data.write(to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Export Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }

    // MARK: - Import

    /// Imports a folder from JSON data.
    /// - Parameters:
    ///   - data: The JSON data to import
    ///   - context: The SwiftData model context
    ///   - existingFolderCount: The count of existing folders (for sortOrder)
    /// - Returns: The newly created Folder
    static func importFolder(from data: Data, context: ModelContext, existingFolderCount: Int) throws -> Folder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let container = try decoder.decode(ExportContainer.self, from: data)

        // Create the folder
        let folder = Folder(
            name: container.folder.name,
            sortOrder: existingFolderCount
        )
        context.insert(folder)

        // Environments: Default's variables, then the others in order; files from before environments get an empty Default.
        let defaultEnvironment = folder.ensureDefaultEnvironment()
        for exported in container.folder.environments ?? [] {
            if exported.isDefault {
                defaultEnvironment.variables = exported.variables
            } else {
                let environment = folder.addEnvironment(
                    named: exported.name, color: EnvironmentColor(rawValue: exported.color) ?? .gray, variables: exported.variables)
                if exported.name == container.folder.selectedEnvironment { folder.selectedEnvironment = environment }
            }
        }

        // Create all requests
        for (index, exportedRequest) in container.folder.requests.enumerated() {
            let request = APIRequest(
                name: exportedRequest.name,
                url: exportedRequest.url,
                method: exportedRequest.method,
                folder: folder
            )
            request.sortOrder = index
            request.headers = exportedRequest.headers
            request.queryParams = exportedRequest.queryParams
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

    /// Shows an open panel and imports a folder from a JSON file.
    /// - Parameters:
    ///   - context: The SwiftData model context
    ///   - existingFolderCount: The count of existing folders
    ///   - completion: Called with the imported folder on success
    @MainActor
    static func importFolderWithDialog(
        context: ModelContext,
        existingFolderCount: Int,
        completion: @escaping (Folder?) -> Void
    ) {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.title = "Import Collection"
        openPanel.message = "Select a collection file to import"

        openPanel.begin { response in
            guard response == .OK, let url = openPanel.url else {
                completion(nil)
                return
            }

            do {
                let data = try Data(contentsOf: url)
                let folder = try importFolder(from: data, context: context, existingFolderCount: existingFolderCount)
                completion(folder)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Import Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.runModal()
                completion(nil)
            }
        }
    }
}
