import Foundation

/// Insomnia exports: v4 (JSON, `_type: export` with a flat `resources` list) and v5 (YAML, `type: collection.insomnia.rest/5.0`).
/// Each workspace becomes a collection: the base environment its Default, sub-environments the others. `{{ _.name }}`
/// becomes `{{name}}`, and nested environment data is flattened to dotted names (`{{ _.api.host }}` → `{{api.host}}`).
enum InsomniaImporter {
    static func isExport(_ tree: JSONValue) -> Bool {
        if tree["_type"]?.scalarText == "export", tree["resources"]?.arrayItems != nil { return true }
        return tree["type"]?.scalarText?.contains("insomnia.rest/") == true
    }

    static func export(_ tree: JSONValue, fallbackName: String) -> ImportedFile {
        if let resources = tree["resources"]?.arrayItems { return version4(resources, fallbackName: fallbackName) }
        return version5(tree, fallbackName: fallbackName)
    }

    // MARK: - v4

    private static func version4(_ resources: [JSONValue], fallbackName: String) -> ImportedFile {
        var notes: [String] = []
        var children: [String: [JSONValue]] = [:]
        for resource in resources {
            if let parent = resource["parentId"]?.scalarText { children[parent, default: []].append(resource) }
        }
        func sorted(_ items: [JSONValue]) -> [JSONValue] {
            items.enumerated().sorted { ($0.element["metaSortKey"]?.numberValue ?? Double($0.offset), $0.offset) < ($1.element["metaSortKey"]?.numberValue ?? Double($1.offset), $1.offset) }.map(\.element)
        }
        let workspaces = resources.filter { $0["_type"]?.scalarText == "workspace" }
        var folders: [ExportImportService.ExportableFolder] = []
        var standalone: [ExportImportService.ExportableEnvironment] = []
        for workspace in workspaces {
            guard let id = workspace["_id"]?.scalarText else { continue }
            let name = ImportSupport.name(workspace["name"], or: fallbackName)
            let base = (children[id] ?? []).first { $0["_type"]?.scalarText == "environment" }
            let subEnvironments = base.flatMap { $0["_id"]?.scalarText }.map { sorted((children[$0] ?? []).filter { $0["_type"]?.scalarText == "environment" }) } ?? []
            var requests: [RequestDraft] = []
            var defaults = variables(base?["data"])
            // Each folder once: a file whose folders are their own parents (or share an ID) would otherwise loop or multiply.
            var visited: Set<String> = [id]
            func walk(_ parent: String, path: [String], inheritedAuth: AuthDraft) {
                for item in sorted(children[parent] ?? []) {
                    switch item["_type"]?.scalarText {
                    case "request_group":
                        guard let groupID = item["_id"]?.scalarText, visited.insert(groupID).inserted else { continue }
                        // Folder variables apply to the folder's requests; with no folders in Reqs, they join Default.
                        for variable in variables(item["environment"]) where !defaults.contains(where: { $0.key == variable.key }) { defaults.append(variable) }
                        walk(groupID, path: path + [ImportSupport.name(item["name"], or: "Folder")], inheritedAuth: auth(item["authentication"], notes: &notes) ?? inheritedAuth)
                    case "request":
                        requests.append(request(item, path: path, inheritedAuth: inheritedAuth, notes: &notes))
                    case "grpc_request", "websocket_request", "socketio_request":
                        notes.append("gRPC, WebSocket and Socket.IO requests aren't imported: Reqs sends HTTP requests.")
                    default:
                        break
                    }
                }
            }
            walk(id, path: [], inheritedAuth: AuthDraft())
            let isDesign = workspace["scope"]?.scalarText == "design"
            if requests.isEmpty, isDesign, let spec = (children[id] ?? []).first(where: { $0["_type"]?.scalarText == "api_spec" }),
                let file = designDocument(spec["contents"], name: name)
            {
                folders += file.collections
                notes += file.notes
                continue
            }
            if requests.isEmpty && workspaces.count > 1 && base == nil { continue }
            let environments =
                [ExportImportService.ExportableEnvironment(name: CollectionEnvironment.defaultName, isDefault: true, color: "blue", variables: defaults)]
                + subEnvironments.enumerated().map { index, environment in
                    ExportImportService.ExportableEnvironment(
                        name: ImportSupport.name(environment["name"], or: "Environment \(index + 1)"), isDefault: false, color: ImportSupport.color(index),
                        variables: variables(environment["data"]))
                }
            folders.append(ExportImportService.ExportableFolder(name: name, requests: requests.map(\.exportable), environments: environments))
        }
        if workspaces.isEmpty {
            // An environment-only export: its environments join a collection.
            standalone = resources.filter { $0["_type"]?.scalarText == "environment" }.enumerated().map { index, environment in
                ExportImportService.ExportableEnvironment(
                    name: ImportSupport.name(environment["name"], or: "Environment \(index + 1)"), isDefault: false, color: ImportSupport.color(index),
                    variables: variables(environment["data"]))
            }
        }
        return finish(ImportedFile(format: folders.isEmpty && !standalone.isEmpty ? .insomniaEnvironment : .insomniaCollection, collections: folders, environments: standalone, notes: notes))
    }

    private static func request(_ item: JSONValue, path: [String], inheritedAuth: AuthDraft, notes: inout [String]) -> RequestDraft {
        var draft = RequestDraft(name: ImportSupport.path(path + [ImportSupport.name(item["name"], or: "Untitled")]))
        draft.method = ImportSupport.method(item["method"]?.scalarText, notes: &notes)
        let (url, query) = ImportSupport.splitQuery(variables(in: item["url"]?.scalarText ?? ""))
        draft.url = url
        draft.queryParams = query + pairs(item["parameters"])
        draft.headers = pairs(item["headers"])
        draft.auth = auth(item["authentication"], notes: &notes) ?? inheritedAuth
        if case .bearer = draft.auth.type, let prefix = item["authentication"]?["prefix"]?.scalarText, !prefix.isEmpty, prefix.caseInsensitiveCompare("Bearer") != .orderedSame {
            // Another prefix than Bearer can only be sent as a header of its own.
            draft.headers.append(KeyValuePair(key: "Authorization", value: "\(prefix) \(draft.auth.token ?? "")"))
            draft.auth = AuthDraft()
        }
        body(item["body"], into: &draft, notes: &notes)
        if !(item["preRequestScript"]?.scalarText ?? "").isEmpty || !(item["afterResponseScript"]?.scalarText ?? "").isEmpty
            || !(item["scripts"]?["preRequest"]?.scalarText ?? "").isEmpty || !(item["scripts"]?["afterResponse"]?.scalarText ?? "").isEmpty
        {
            notes.append(ImportSupport.scriptsNote)
        }
        return draft
    }

    private static func body(_ value: JSONValue?, into draft: inout RequestDraft, notes: inout [String]) {
        guard let value, let mime = value["mimeType"]?.scalarText, !mime.isEmpty else {
            if let text = value?["text"]?.scalarText, !text.isEmpty { draft.setBody(mimeType: "text/plain", text: variables(in: text)) }
            return
        }
        switch mime.lowercased() {
        case "multipart/form-data", "application/x-www-form-urlencoded":
            let fields = (value["params"]?.arrayItems ?? []).compactMap { field -> KeyValuePair? in
                guard let name = field["name"]?.scalarText else { return nil }
                if field["type"]?.scalarText == "file" {
                    notes.append(ImportSupport.fileFieldsNote)
                    return nil
                }
                return KeyValuePair(key: variables(in: name), value: variables(in: ImportSupport.text(field["value"])), isEnabled: field["disabled"]?.boolValue != true)
            }
            draft.bodyType = mime.lowercased() == "multipart/form-data" ? .formData : .urlEncoded
            draft.body = ImportSupport.formBody(fields)
        case "application/graphql":
            // Insomnia keeps a GraphQL body as the JSON it sends.
            draft.bodyType = .json
            draft.body = variables(in: value["text"]?.scalarText ?? "")
            notes.append("GraphQL bodies were imported as JSON ({\"query\": …, \"variables\": …}).")
        case "application/octet-stream":
            notes.append(ImportSupport.fileFieldsNote)
        default:
            draft.setBody(mimeType: mime, text: variables(in: value["text"]?.scalarText ?? ""))
        }
    }

    /// The authentication `value` sets: nil when empty (the folder's applies); `.none` when disabled.
    private static func auth(_ value: JSONValue?, notes: inout [String]) -> AuthDraft? {
        guard let value, let type = value["type"]?.scalarText, type != "inherit" else { return nil }
        guard value["disabled"]?.boolValue != true else { return AuthDraft() }
        func text(_ key: String) -> String { variables(in: value[key]?.scalarText ?? "") }
        switch type {
        case "none", "noauth": return AuthDraft()
        case "bearer": return .bearer(text("token"))
        case "basic": return .basic(text("username"), text("password"))
        case "apikey":
            if text("addTo") == "cookie" { return .apiKey("Cookie", "\(text("key"))=\(text("value"))", inQuery: false) }
            return .apiKey(text("key"), text("value"), inQuery: text("addTo") == "queryParams")
        case "oauth2":
            notes.append(ImportSupport.oauthNote)
            let token = text("accessToken")
            return .bearer(token.isEmpty ? "{{accessToken}}" : token)
        default:
            notes.append("\(type.capitalized) authentication isn't supported by Reqs, so those requests were imported without authentication.")
            return AuthDraft()
        }
    }

    private static func pairs(_ value: JSONValue?) -> [KeyValuePair] {
        (value?.arrayItems ?? []).compactMap { pair in
            guard let name = pair["name"]?.scalarText, !name.isEmpty else { return nil }
            return KeyValuePair(key: variables(in: name), value: variables(in: ImportSupport.text(pair["value"])), isEnabled: pair["disabled"]?.boolValue != true)
        }
    }

    // MARK: - v5

    private static func version5(_ tree: JSONValue, fallbackName: String) -> ImportedFile {
        let type = tree["type"]?.scalarText ?? ""
        var notes: [String] = []
        let name = ImportSupport.name(tree["name"], or: fallbackName)
        let (defaults, others) = environments(tree["environments"])
        if type.hasPrefix("environment.") {
            let base = ExportImportService.ExportableEnvironment(name: ImportSupport.name(tree["environments"]?["name"], or: name), isDefault: false, color: ImportSupport.color(0), variables: defaults)
            return finish(ImportedFile(format: .insomniaEnvironment, environments: (defaults.isEmpty ? [] : [base]) + others))
        }
        var requests: [RequestDraft] = []
        var folderVariables = defaults
        func walk(_ items: [JSONValue], path: [String], inheritedAuth: AuthDraft, inheritedHeaders: [KeyValuePair]) {
            let ordered = items.enumerated().sorted { ($0.element["meta"]?["sortKey"]?.numberValue ?? Double($0.offset), $0.offset) < ($1.element["meta"]?["sortKey"]?.numberValue ?? Double($1.offset), $1.offset) }
            for item in ordered.map(\.element) {
                if let children = item["children"]?.arrayItems {
                    for variable in variables(item["environment"]) where !folderVariables.contains(where: { $0.key == variable.key }) { folderVariables.append(variable) }
                    walk(
                        children, path: path + [ImportSupport.name(item["name"], or: "Folder")],
                        inheritedAuth: auth(item["authentication"], notes: &notes) ?? inheritedAuth, inheritedHeaders: inheritedHeaders + pairs(item["headers"]))
                } else if item["url"] != nil {
                    var draft = request(item, path: path, inheritedAuth: inheritedAuth, notes: &notes)
                    // A folder's headers apply to its requests, unless a request sets the same one.
                    draft.headers = inheritedHeaders.filter { header in !draft.hasHeader(header.key) } + draft.headers
                    requests.append(draft)
                }
            }
        }
        walk(tree["collection"]?.arrayItems ?? [], path: [], inheritedAuth: AuthDraft(), inheritedHeaders: [])
        if requests.isEmpty, let file = designDocument(tree["spec"]?["contents"], name: name) { return finish(file) }
        let folder = ExportImportService.ExportableFolder(
            name: name, requests: requests.map(\.exportable),
            environments: [ExportImportService.ExportableEnvironment(name: CollectionEnvironment.defaultName, isDefault: true, color: "blue", variables: folderVariables)] + others)
        return finish(ImportedFile(format: .insomniaCollection, collections: [folder], notes: notes))
    }

    /// A v5 `environments` block: the base's variables, and its sub-environments.
    private static func environments(_ value: JSONValue?) -> ([Variable], [ExportImportService.ExportableEnvironment]) {
        guard let value else { return ([], []) }
        let subs = (value["subEnvironments"]?.arrayItems ?? []).enumerated().map { index, environment in
            ExportImportService.ExportableEnvironment(
                name: ImportSupport.name(environment["name"], or: "Environment \(index + 1)"), isDefault: false, color: ImportSupport.color(index),
                variables: variables(environment["data"]))
        }
        return (variables(value["data"]), subs)
    }

    /// The requests of a design document's OpenAPI spec, given as text (v4) or as the spec itself (v5).
    private static func designDocument(_ contents: JSONValue?, name: String) -> ImportedFile? {
        guard let contents else { return nil }
        var spec = contents
        if let text = contents.scalarText { spec = (try? CollectionImport.parse(Data(text.utf8), fileName: name)) ?? .null }
        guard OpenAPIImporter.isSpec(spec) else { return nil }
        return OpenAPIImporter.collection(spec, fallbackName: name)
    }

    // MARK: - Variables

    /// Environment data as variables: nested objects flattened to dotted names, other values as JSON text.
    static func variables(_ data: JSONValue?) -> [Variable] {
        guard let fields = data?.objectFields else { return [] }
        var result: [Variable] = []
        func add(_ fields: [String: JSONValue], prefix: String) {
            for key in fields.keys.sorted() {
                let name = prefix.isEmpty ? key : "\(prefix).\(key)"
                if let nested = fields[key]?.objectFields, !nested.isEmpty {
                    add(nested, prefix: name)
                } else {
                    result.append(Variable(key: name, value: variables(in: ImportSupport.text(fields[key]))))
                }
            }
        }
        add(fields, prefix: "")
        return result
    }

    /// `{{ _.name }}` and `{{ name }}` written as `{{name}}`.
    static func variables(in text: String) -> String {
        guard text.contains("{{") else { return text }
        return text.replacing(/\{\{\s*(?:_\.)?([A-Za-z0-9_\-\.\[\]'"]+?)\s*\}\}/) { "{{\($0.output.1)}}" }
    }

    /// Adds the template tag note when any request still has `{% … %}`.
    private static func finish(_ file: ImportedFile) -> ImportedFile {
        var file = file
        let texts = file.collections.flatMap(\.requests).flatMap { [$0.url, $0.bodyContent, $0.authBearerToken ?? ""] + $0.headers.map(\.value) + $0.queryParams.map(\.value) }
        if texts.contains(where: { $0.contains("{%") }) {
            file.notes.append("Insomnia template tags ({% response … %}, {% uuid %}…) aren't supported by Reqs: they are sent as written.")
        }
        return file
    }
}

extension JSONValue {
    /// A number, or a string that is one.
    var numberValue: Double? {
        switch self {
        case .number(let number): return number
        case .string(let text): return Double(text)
        default: return nil
        }
    }
}
