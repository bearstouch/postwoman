import Foundation
import SwiftData

/// A file to import, read into Reqs's export shapes before anything is stored, so a file that fails changes nothing.
struct ImportedFile {
    /// What the file was.
    var format: ImportFormat
    var collections: [ExportImportService.ExportableFolder] = []
    /// Environments that came without a collection (a Postman or Hoppscotch environment file): they join one.
    var environments: [ExportImportService.ExportableEnvironment] = []
    /// What couldn't be carried over, said once each ("Pre-request and test scripts aren't imported.").
    var notes: [String] = []
}

/// Reads collections and environments from Reqs, Postman, Hoppscotch, Insomnia and OpenAPI files, and stores them.
enum CollectionImport {
    enum Failure: LocalizedError, Equatable {
        case tooLarge(String)
        case notText(String)
        case unrecognized(String)
        case unsupported(String, String)
        case unreadable(String, String)
        /// Environments without a collection to join: none imported with them and none selected.
        case noCollectionForEnvironments

        var errorDescription: String? {
            switch self {
            case .tooLarge(let file): return "“\(file)” is larger than 50 MB, so it wasn't imported."
            case .notText(let file): return "“\(file)” isn't a text file, so it wasn't imported."
            case .unrecognized(let file):
                return
                    "“\(file)” isn't a collection or environment file Reqs knows. Reqs imports its own files, Postman collections (v2.0 and v2.1) and environments, Hoppscotch collections and environments, Insomnia exports (v4 JSON and v5 YAML) and OpenAPI 3 or Swagger 2 specs."
            case .unsupported(let file, let reason): return "“\(file)” wasn't imported: \(reason)"
            case .unreadable(let file, let reason): return "“\(file)” couldn't be read: \(reason)"
            case .noCollectionForEnvironments:
                return "Environment files are added to a collection. Select the collection in the sidebar, or import the environments together with their collection, then try again."
            }
        }
    }

    static let maximumFileSize = 50 * 1024 * 1024

    // MARK: - Reading

    /// The collections and environments in `data`, whatever app wrote it. `fileName` names the file in messages and is the
    /// collection's name when the file has none.
    static func read(_ data: Data, fileName: String) throws -> ImportedFile {
        guard data.count <= maximumFileSize else { throw Failure.tooLarge(fileName) }
        let baseName = (fileName as NSString).deletingPathExtension
        // A Reqs file first, with its own version check and messages.
        if let reqs = try readReqsFile(data) { return reqs }
        let tree = try parse(data, fileName: fileName)
        if PostmanImporter.isCollection(tree) {
            if PostmanImporter.isVersion1(tree) { throw Failure.unsupported(fileName, "it is a Postman v1 collection. Export it from Postman as Collection v2.1, then import that file.") }
            return try limited(PostmanImporter.collection(tree, fallbackName: baseName), fileName: fileName)
        }
        if PostmanImporter.isEnvironment(tree) { return PostmanImporter.environment(tree, fallbackName: baseName) }
        if InsomniaImporter.isExport(tree) { return try limited(InsomniaImporter.export(tree, fallbackName: baseName), fileName: fileName) }
        if HoppscotchImporter.isCollection(tree) { return try limited(HoppscotchImporter.collections(tree, fallbackName: baseName), fileName: fileName) }
        if HoppscotchImporter.isEnvironment(tree) { return HoppscotchImporter.environments(tree, fallbackName: baseName) }
        if OpenAPIImporter.isSpec(tree) { return try limited(OpenAPIImporter.collection(tree, fallbackName: baseName), fileName: fileName) }
        throw Failure.unrecognized(fileName)
    }

    /// The most requests one file may bring: more is a hostile or broken file, which would freeze the app while stored.
    static let maximumRequests = 20_000

    private static func limited(_ file: ImportedFile, fileName: String) throws -> ImportedFile {
        let count = file.collections.reduce(0) { $0 + $1.requests.count }
        guard count <= maximumRequests else {
            throw Failure.unsupported(fileName, "it has \(count) requests, more than the \(maximumRequests) Reqs imports from one file.")
        }
        return file
    }

    /// A Reqs collection or backup file, or nil when `data` is something else.
    private static func readReqsFile(_ data: Data) throws -> ImportedFile? {
        guard let header = try? JSONDecoder().decode(ReqsHeader.self, from: data) else { return nil }
        if header.folder != nil {
            return ImportedFile(format: .reqsCollection, collections: [try ExportImportService.decodeFolder(from: data)])
        }
        if header.collections != nil {
            return ImportedFile(format: .reqsCollections, collections: try ExportImportService.backupCollections(from: data))
        }
        return nil
    }

    /// The keys that mark a Reqs file: a string `version` and a `folder` or `collections`.
    private struct ReqsHeader: Decodable {
        let version: String
        let folder: JSONValue?
        let collections: JSONValue?
    }

    /// The file as a tree: JSON when it starts like JSON, else YAML.
    static func parse(_ data: Data, fileName: String) throws -> JSONValue {
        guard var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw Failure.notText(fileName) }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        guard !text.contains("\0") else { throw Failure.notText(fileName) }
        let start = text.first { !$0.isWhitespace }
        if start == "{" || start == "[" {
            if JSONValue.exceedsNesting(Data(text.utf8), limit: YAMLReader.maximumDepth) { throw Failure.unreadable(fileName, "it is nested too deeply.") }
            // No YAML fallback: a broken JSON export is reported as JSON at once (YAML flow files starting with { are rare).
            if let tree = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) { return tree }
            throw Failure.unreadable(fileName, "it isn't valid JSON.")
        }
        do {
            return try YAMLReader.parse(text)
        } catch {
            throw Failure.unreadable(fileName, error.localizedDescription)
        }
    }

    // MARK: - Storing

    /// What an import stored, for the summary and the sidebar selection.
    struct Outcome {
        var collections: [Folder] = []
        /// The collection that environment files joined, if any.
        var environmentTarget: Folder?
        var addedEnvironments = 0
        var notes: [String] = []
    }

    /// Where environments that came without a collection go: the one collection imported with them, else `selected`.
    static func environmentTarget(collectionCount: Int, selected: Folder?) -> EnvironmentTarget? {
        if collectionCount == 1 { return .imported }
        return selected.map(EnvironmentTarget.existing)
    }

    enum EnvironmentTarget {
        case imported
        case existing(Folder)
    }

    /// Stores `files`: each collection after the last of `existing`, and environments without a collection in the one
    /// collection imported with them, else in `selected`. Throws before storing anything when environments have nowhere to go.
    @MainActor
    static func store(_ files: [ImportedFile], context: ModelContext, existing: [Folder], selected: Folder?) throws -> Outcome {
        let collections = files.flatMap(\.collections)
        let environments = files.flatMap(\.environments)
        var target: EnvironmentTarget?
        if !environments.isEmpty {
            guard let found = environmentTarget(collectionCount: collections.count, selected: selected) else { throw Failure.noCollectionForEnvironments }
            target = found
        }
        var outcome = Outcome(notes: unique(files.flatMap(\.notes)))
        var order = Folder.nextSortOrder(after: existing)
        for collection in collections {
            outcome.collections.append(ExportImportService.insert(collection, context: context, sortOrder: order))
            order += 1
        }
        switch target {
        case .imported: outcome.environmentTarget = outcome.collections.first
        case .existing(let folder): outcome.environmentTarget = folder
        case nil: break
        }
        if let folder = outcome.environmentTarget {
            for environment in environments {
                folder.addEnvironment(
                    named: environment.name, color: EnvironmentColor(rawValue: environment.color) ?? .gray, variables: ExportImportService.fresh(environment.variables))
                outcome.addedEnvironments += 1
            }
        }
        return outcome
    }

    /// Imports `files` for the Import sheet: the user's pending edits are saved first, so a failed save rolls back only the
    /// import. The selected collection is passed by ID and looked up again: an agent may have deleted it while the sheet was
    /// open, and reading a deleted model traps.
    @MainActor
    static func commit(_ files: [ImportedFile], context: ModelContext, selectedID: PersistentIdentifier?) throws -> Outcome {
        try context.save()
        let existing = try context.fetch(FetchDescriptor<Folder>())
        let live = selectedID.flatMap { id in existing.first { $0.persistentModelID == id } }
        let outcome = try store(files, context: context, existing: existing, selected: live)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return outcome
    }

    private static func unique(_ notes: [String]) -> [String] {
        var seen = Set<String>()
        return notes.filter { seen.insert($0).inserted }
    }
}

// MARK: - Building requests

/// A request being converted, with Reqs's defaults; ``exportable`` is what gets stored.
struct RequestDraft {
    var name: String
    var url = ""
    var method: HTTPMethod = .get
    var headers: [KeyValuePair] = []
    var queryParams: [KeyValuePair] = []
    var bodyType: ContentType = .none
    var body = ""
    var auth = AuthDraft()

    /// The request as stored. An API key becomes a header or query parameter, unless the request already sets that name.
    var exportable: ExportImportService.ExportableRequest {
        var headers = headers
        var queryParams = queryParams
        if let key = auth.apiKey, !key.name.isEmpty {
            let pair = KeyValuePair(key: key.name, value: key.value)
            if key.inQuery {
                if !queryParams.contains(where: { $0.key == key.name }) { queryParams.append(pair) }
            } else if !hasHeader(key.name) {
                headers.append(pair)
            }
        }
        return ExportImportService.ExportableRequest(
            name: name, url: url, method: method, headers: headers, queryParams: queryParams, bodyType: bodyType, bodyContent: body,
            authenticationType: auth.type, authBearerToken: auth.token, authBasicUsername: auth.username, authBasicPassword: auth.password,
            authOAuthConfig: nil)
    }

    /// Sets the body from a MIME type and its text. Types Reqs has no body type for are sent as plain text with their own
    /// Content-Type header, unless the request already names one.
    mutating func setBody(mimeType: String?, text: String) {
        let mime = (mimeType ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        bodyType = ImportSupport.bodyType(forMIMEType: mime)
        body = text
        if bodyType == .text, !mime.isEmpty, mime != "text/plain", !hasHeader("Content-Type") {
            headers.append(KeyValuePair(key: "Content-Type", value: mimeType ?? mime))
        }
    }

    func hasHeader(_ name: String) -> Bool { headers.contains { $0.key.caseInsensitiveCompare(name) == .orderedSame } }
}

/// A request's authentication in Reqs's terms, inherited by a folder's requests that set none. OAuth 2.0 becomes Bearer
/// (Reqs doesn't run OAuth flows), and an API key a header or query parameter.
struct AuthDraft: Equatable {
    var type: AuthenticationType = .none
    var token: String?
    var username: String?
    var password: String?
    var apiKey: APIKey?

    struct APIKey: Equatable {
        var name: String
        var value: String
        var inQuery: Bool
    }

    static func bearer(_ token: String) -> AuthDraft { AuthDraft(type: .bearer, token: token) }
    static func basic(_ username: String, _ password: String) -> AuthDraft { AuthDraft(type: .basic, username: username, password: password) }
    static func apiKey(_ name: String, _ value: String, inQuery: Bool) -> AuthDraft { AuthDraft(apiKey: APIKey(name: name, value: value, inQuery: inQuery)) }
}

/// Helpers every importer uses.
enum ImportSupport {
    static let oauthNote = "Reqs doesn't run OAuth 2.0 flows: OAuth 2.0 requests use Bearer authentication with the token the file had, or {{accessToken}} when it had none."
    static let scriptsNote = "Pre-request and test scripts aren't imported."
    static let fileFieldsNote = "File fields and binary bodies aren't imported: Reqs sends text bodies only."

    /// The method, or GET (with a note) for one Reqs doesn't have.
    static func method(_ text: String?, notes: inout [String]) -> HTTPMethod {
        let name = (text ?? "GET").trimmingCharacters(in: .whitespaces).uppercased()
        if let method = HTTPMethod(rawValue: name.isEmpty ? "GET" : name) { return method }
        notes.append("Requests with the \(name) method were imported as GET: Reqs supports \(HTTPMethod.allCases.map(\.rawValue).joined(separator: ", ")).")
        return .get
    }

    /// `url` without its query, and the query's parameters (decoded, as the Params tab shows them).
    static func splitQuery(_ url: String) -> (String, [KeyValuePair]) {
        guard let mark = url.firstIndex(of: "?") else { return (url, []) }
        var query = url[url.index(after: mark)...]
        if let hash = query.firstIndex(of: "#") { query = query[..<hash] }
        let pairs = query.split(separator: "&").map { pair -> KeyValuePair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decoded(_ text: Substring) -> String { text.removingPercentEncoding ?? String(text) }
            return KeyValuePair(key: decoded(parts[0]), value: parts.count > 1 ? decoded(parts[1]) : "")
        }
        return (String(url[..<mark]), pairs)
    }

    static func bodyType(forMIMEType mime: String) -> ContentType {
        if mime.isEmpty { return .none }
        if mime == "application/json" || mime.hasSuffix("+json") || mime == "text/json" { return .json }
        if mime == "application/xml" || mime == "text/xml" || mime.hasSuffix("+xml") { return .xml }
        if mime == "application/x-www-form-urlencoded" { return .urlEncoded }
        if mime == "multipart/form-data" { return .formData }
        return .text
    }

    /// Form fields as a Reqs form body (`a=1&b=2`). Disabled fields are left out, as the form editor does.
    static func formBody(_ pairs: [KeyValuePair]) -> String { FormBody.body(from: pairs) }

    /// Pretty-printed JSON with sorted keys and unescaped slashes, as a request body.
    static func prettyJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// A variable value as text: strings as written, other JSON as JSON.
    static func text(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        if let scalar = value.scalarText { return scalar }
        if value == .null { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// A display name: `parts` joined with " / ", blank ones left out.
    static func path(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " / ")
    }

    /// The color for the `index`th environment a file brings, so they are told apart in the menu.
    static func color(_ index: Int) -> String {
        let colors: [EnvironmentColor] = [.green, .orange, .red, .pink, .blue, .gray]
        return colors[index % colors.count].rawValue
    }

    /// The name, or `fallback` when it is blank.
    static func name(_ value: JSONValue?, or fallback: String) -> String {
        let name = value?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? fallback : name
    }
}
