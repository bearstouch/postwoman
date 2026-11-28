import Foundation

/// Postman collections (v2.0 and v2.1) and environment files. Folders are flattened into request names
/// ("Users / Get user"); collection variables become the Default environment.
enum PostmanImporter {
    static func isCollection(_ tree: JSONValue) -> Bool {
        if let schema = tree["info"]?["schema"]?.scalarText, schema.contains("getpostman.com") { return true }
        return tree["info"]?.objectFields != nil && tree["item"]?.arrayItems != nil || isVersion1(tree)
    }

    /// A v1 collection: `requests` and `order` at the top.
    static func isVersion1(_ tree: JSONValue) -> Bool { tree["requests"]?.arrayItems != nil && tree["order"]?.arrayItems != nil }

    static func isEnvironment(_ tree: JSONValue) -> Bool {
        guard let values = tree["values"]?.arrayItems else { return false }
        return tree["_postman_variable_scope"] != nil || (tree["name"] != nil && values.allSatisfy { $0["key"] != nil })
    }

    // MARK: - Collections

    static func collection(_ tree: JSONValue, fallbackName: String) -> ImportedFile {
        var notes: [String] = []
        var requests: [RequestDraft] = []
        walk(tree["item"]?.arrayItems ?? [], path: [], inheritedAuth: auth(tree["auth"], notes: &notes) ?? AuthDraft(), into: &requests, notes: &notes)
        if tree["event"]?.arrayItems?.isEmpty == false { notes.append(ImportSupport.scriptsNote) }
        let variables = (tree["variable"]?.arrayItems ?? []).compactMap(variable)
        if requests.contains(where: usesDynamicVariable) {
            notes.append("Postman's dynamic variables ({{$guid}}, {{$timestamp}}…) aren't resolved by Reqs: they are sent as written.")
        }
        let folder = ExportImportService.ExportableFolder(
            name: ImportSupport.name(tree["info"]?["name"], or: fallbackName), requests: requests.map(\.exportable),
            environments: [ExportImportService.ExportableEnvironment(name: CollectionEnvironment.defaultName, isDefault: true, color: "blue", variables: variables)])
        return ImportedFile(format: .postmanCollection, collections: [folder], notes: notes)
    }

    private static func walk(_ items: [JSONValue], path: [String], inheritedAuth: AuthDraft, into requests: inout [RequestDraft], notes: inout [String]) {
        for item in items {
            let name = ImportSupport.name(item["name"], or: "Untitled")
            if item["event"]?.arrayItems?.contains(where: { ($0["script"]?["exec"]?.arrayItems ?? []).contains { $0.scalarText?.isEmpty == false } }) == true {
                notes.append(ImportSupport.scriptsNote)
            }
            if let children = item["item"]?.arrayItems {
                let folderAuth = auth(item["auth"], notes: &notes) ?? inheritedAuth
                walk(children, path: path + [name], inheritedAuth: folderAuth, into: &requests, notes: &notes)
            } else if let request = item["request"] {
                requests.append(self.request(request, name: ImportSupport.path(path + [name]), inheritedAuth: inheritedAuth, notes: &notes))
            }
        }
    }

    private static func request(_ request: JSONValue, name: String, inheritedAuth: AuthDraft, notes: inout [String]) -> RequestDraft {
        var draft = RequestDraft(name: name)
        if case .string(let url) = request {
            (draft.url, draft.queryParams) = ImportSupport.splitQuery(url)
            return draft
        }
        draft.method = ImportSupport.method(request["method"]?.scalarText, notes: &notes)
        (draft.url, draft.queryParams) = url(request["url"])
        draft.headers = headers(request["header"])
        draft.auth = auth(request["auth"], notes: &notes) ?? inheritedAuth
        body(request["body"], into: &draft, notes: &notes)
        return draft
    }

    /// The URL without its query, and its parameters. Path variables (`:id`) take their value, else become `{{id}}`.
    private static func url(_ value: JSONValue?) -> (String, [KeyValuePair]) {
        guard let value else { return ("", []) }
        if let text = value.scalarText { return ImportSupport.splitQuery(text) }
        var raw = value["raw"]?.scalarText ?? ""
        if raw.isEmpty {
            let scheme = value["protocol"]?.scalarText.map { $0 + "://" } ?? ""
            let host = (value["host"]?.arrayItems?.compactMap(\.scalarText) ?? [value["host"]?.scalarText].compactMap { $0 }).joined(separator: ".")
            let port = value["port"]?.scalarText.map { ":" + $0 } ?? ""
            let segments = value["path"]?.arrayItems?.compactMap { $0.scalarText ?? $0["value"]?.scalarText } ?? [value["path"]?.scalarText].compactMap { $0 }
            raw = scheme + host + port + (segments.isEmpty ? "" : "/" + segments.joined(separator: "/"))
        }
        var (base, params) = ImportSupport.splitQuery(raw)
        if let query = value["query"]?.arrayItems {
            params = query.compactMap { pair in
                guard let key = pair["key"]?.scalarText else { return nil }
                // Postman keeps them as they appear in the URL, percent-encoded; Reqs encodes params when it sends them.
                let value = ImportSupport.text(pair["value"])
                return KeyValuePair(key: key.removingPercentEncoding ?? key, value: value.removingPercentEncoding ?? value, isEnabled: pair["disabled"]?.boolValue != true)
            }
        }
        for variable in value["variable"]?.arrayItems ?? [] {
            guard let key = variable["key"]?.scalarText, !key.isEmpty else { continue }
            let replacement = ImportSupport.text(variable["value"]).isEmpty ? "{{\(key)}}" : ImportSupport.text(variable["value"])
            base = replacingPathVariable(key, with: replacement, in: base)
        }
        return (base, params)
    }

    /// `/:key` path segments replaced by `replacement`.
    static func replacingPathVariable(_ key: String, with replacement: String, in url: String) -> String {
        var result = ""
        var rest = Substring(url)
        let marker = "/:" + key
        while let range = rest.range(of: marker) {
            let after = rest[range.upperBound...]
            if after.isEmpty || after.first == "/" || after.first == "?" || after.first == "#" || after.first == "." {
                result += rest[..<range.lowerBound] + "/" + replacement
            } else {
                result += rest[..<range.upperBound]
            }
            rest = after
        }
        return result + rest
    }

    private static func headers(_ value: JSONValue?) -> [KeyValuePair] {
        if let text = value?.scalarText {
            return text.split(whereSeparator: \.isNewline).compactMap { line in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return KeyValuePair(key: line[..<colon].trimmingCharacters(in: .whitespaces), value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
        }
        return (value?.arrayItems ?? []).compactMap { header in
            guard let key = header["key"]?.scalarText else { return nil }
            return KeyValuePair(key: key, value: ImportSupport.text(header["value"]), isEnabled: header["disabled"]?.boolValue != true)
        }
    }

    private static func body(_ value: JSONValue?, into draft: inout RequestDraft, notes: inout [String]) {
        guard let value, value["disabled"]?.boolValue != true else { return }
        switch value["mode"]?.scalarText {
        case "raw":
            let text = value["raw"]?.scalarText ?? ""
            let contentType = draft.headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame && $0.isEnabled }?.value
            switch value["options"]?["raw"]?["language"]?.scalarText {
            case "json": draft.bodyType = .json
            case "xml": draft.bodyType = .xml
            case "html", "javascript", "text": draft.bodyType = .text
            default: draft.bodyType = contentType.map { ImportSupport.bodyType(forMIMEType: $0.lowercased()) } ?? .text
            }
            if draft.bodyType == .none || draft.bodyType == .formData || draft.bodyType == .urlEncoded { draft.bodyType = .text }
            draft.body = text
        case "urlencoded":
            draft.bodyType = .urlEncoded
            draft.body = ImportSupport.formBody(fields(value["urlencoded"], notes: &notes))
        case "formdata":
            draft.bodyType = .formData
            draft.body = ImportSupport.formBody(fields(value["formdata"], notes: &notes))
        case "graphql":
            var payload: [String: JSONValue] = ["query": .string(value["graphql"]?["query"]?.scalarText ?? "")]
            if let variables = value["graphql"]?["variables"]?.scalarText, !variables.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                payload["variables"] = (try? JSONDecoder().decode(JSONValue.self, from: Data(variables.utf8))) ?? .string(variables)
            }
            draft.bodyType = .json
            draft.body = ImportSupport.prettyJSON(.object(payload))
            notes.append("GraphQL bodies were imported as JSON ({\"query\": …, \"variables\": …}).")
        case "file":
            notes.append(ImportSupport.fileFieldsNote)
        default:
            break
        }
    }

    private static func fields(_ value: JSONValue?, notes: inout [String]) -> [KeyValuePair] {
        (value?.arrayItems ?? []).compactMap { field in
            guard let key = field["key"]?.scalarText else { return nil }
            if field["type"]?.scalarText == "file" {
                notes.append(ImportSupport.fileFieldsNote)
                return nil
            }
            return KeyValuePair(key: key, value: ImportSupport.text(field["value"]), isEnabled: field["disabled"]?.boolValue != true)
        }
    }

    // MARK: - Authentication

    /// The authentication `value` describes: nil when it sets none (its requests inherit); `.none` for "noauth".
    private static func auth(_ value: JSONValue?, notes: inout [String]) -> AuthDraft? {
        guard let value, let type = value["type"]?.scalarText else { return nil }
        let parameters = self.parameters(value[type])
        switch type {
        case "noauth": return AuthDraft()
        case "bearer": return .bearer(parameters["token"] ?? "")
        case "basic": return .basic(parameters["username"] ?? "", parameters["password"] ?? "")
        case "oauth2":
            notes.append(ImportSupport.oauthNote)
            let token = parameters["accessToken"] ?? ""
            return .bearer(token.isEmpty ? "{{accessToken}}" : token)
        case "apikey": return .apiKey(parameters["key"] ?? "", parameters["value"] ?? "", inQuery: parameters["in"] == "query")
        default:
            notes.append("\(type.capitalized) authentication isn't supported by Reqs, so those requests were imported without authentication.")
            return AuthDraft()
        }
    }

    /// An auth type's parameters: `[{key, value}]` in v2.1, an object in v2.0.
    private static func parameters(_ value: JSONValue?) -> [String: String] {
        if let fields = value?.objectFields { return fields.compactMapValues(\.scalarText) }
        var result: [String: String] = [:]
        for pair in value?.arrayItems ?? [] {
            if let key = pair["key"]?.scalarText { result[key] = ImportSupport.text(pair["value"]) }
        }
        return result
    }

    // MARK: - Variables and environments

    private static func variable(_ value: JSONValue) -> Variable? {
        guard let key = value["key"]?.scalarText ?? value["id"]?.scalarText, !key.isEmpty else { return nil }
        let enabled = value["disabled"]?.boolValue != true && value["enabled"]?.boolValue != false
        return Variable(key: key, value: ImportSupport.text(value["value"]), isEnabled: enabled, isSecret: value["type"]?.scalarText == "secret")
    }

    static func environment(_ tree: JSONValue, fallbackName: String) -> ImportedFile {
        let fallback = tree["_postman_variable_scope"]?.scalarText == "globals" ? "Globals" : fallbackName
        let environment = ExportImportService.ExportableEnvironment(
            name: ImportSupport.name(tree["name"], or: fallback), isDefault: false, color: ImportSupport.color(0),
            variables: (tree["values"]?.arrayItems ?? []).compactMap(variable))
        return ImportedFile(format: .postmanEnvironment, environments: [environment])
    }

    private static func usesDynamicVariable(_ draft: RequestDraft) -> Bool {
        let texts = [draft.url, draft.body, draft.auth.token ?? ""] + draft.headers.map(\.value) + draft.queryParams.map(\.value)
        return texts.contains { $0.contains("{{$") }
    }
}
