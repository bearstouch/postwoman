import Foundation

/// Hoppscotch collections (one, or the array its export writes) and environments. `<<variable>>` becomes `{{variable}}`;
/// request variables are written into the request; folders are flattened into request names, and pass their
/// authentication and headers down to the requests that inherit them.
enum HoppscotchImporter {
    static func isCollection(_ tree: JSONValue) -> Bool {
        let first = tree.arrayItems?.first ?? tree
        return first["requests"]?.arrayItems != nil && first["folders"]?.arrayItems != nil
    }

    static func isEnvironment(_ tree: JSONValue) -> Bool {
        let items = tree.arrayItems ?? [tree]
        return !items.isEmpty
            && items.allSatisfy { item in
                guard let variables = item["variables"]?.arrayItems else { return false }
                return item["folders"] == nil && variables.allSatisfy { $0["key"] != nil }
            }
    }

    // MARK: - Collections

    static func collections(_ tree: JSONValue, fallbackName: String) -> ImportedFile {
        var notes: [String] = []
        let roots = tree.arrayItems ?? [tree]
        let folders = roots.enumerated().map { index, root in
            var requests: [RequestDraft] = []
            let auth = self.auth(root["auth"], notes: &notes) ?? AuthDraft()
            walk(root, path: [], inherited: Inherited(auth: auth, headers: pairs(root["headers"])), into: &requests, notes: &notes)
            let name = ImportSupport.name(root["name"], or: roots.count == 1 ? fallbackName : "\(fallbackName) \(index + 1)")
            let variables = (root["variables"]?.arrayItems ?? []).compactMap(variable)
            return ExportImportService.ExportableFolder(
                name: name, requests: requests.map(\.exportable),
                environments: [ExportImportService.ExportableEnvironment(name: CollectionEnvironment.defaultName, isDefault: true, color: "blue", variables: variables)])
        }
        return ImportedFile(format: .hoppscotchCollection, collections: folders, notes: notes)
    }

    /// What a folder passes to the requests in it.
    private struct Inherited {
        var auth: AuthDraft
        var headers: [KeyValuePair]
    }

    /// The requests of `collection`, then those of its folders, in order.
    private static func walk(_ collection: JSONValue, path: [String], inherited: Inherited, into requests: inout [RequestDraft], notes: inout [String]) {
        for request in collection["requests"]?.arrayItems ?? [] {
            requests.append(self.request(request, path: path, inherited: inherited, notes: &notes))
        }
        for folder in collection["folders"]?.arrayItems ?? [] {
            var passed = inherited
            if let auth = auth(folder["auth"], notes: &notes) { passed.auth = auth }
            passed.headers += pairs(folder["headers"])
            walk(folder, path: path + [ImportSupport.name(folder["name"], or: "Folder")], inherited: passed, into: &requests, notes: &notes)
        }
    }

    private static func request(_ value: JSONValue, path: [String], inherited: Inherited, notes: inout [String]) -> RequestDraft {
        // Request variables apply to this request only, so their values are written in.
        let requestVariables = (value["requestVariables"]?.arrayItems ?? []).compactMap { item -> (String, String)? in
            guard let key = item["key"]?.scalarText, !key.isEmpty, item["active"]?.boolValue != false else { return nil }
            return (key, ImportSupport.text(item["value"]))
        }
        func convert(_ text: String) -> String {
            var text = text
            for (key, value) in requestVariables { text = text.replacingOccurrences(of: "<<\(key)>>", with: value) }
            return variables(text)
        }
        func convert(_ pairs: [KeyValuePair]) -> [KeyValuePair] {
            pairs.map { KeyValuePair(key: convert($0.key), value: convert($0.value), isEnabled: $0.isEnabled) }
        }

        var draft = RequestDraft(name: ImportSupport.path(path + [ImportSupport.name(value["name"], or: "Untitled")]))
        draft.method = ImportSupport.method(value["method"]?.scalarText, notes: &notes)
        let (url, query) = ImportSupport.splitQuery(convert(value["endpoint"]?.scalarText ?? ""))
        draft.url = url
        draft.queryParams = query + convert(pairs(value["params"]))
        draft.headers = convert(inherited.headers.filter { header in !pairs(value["headers"]).contains { $0.key.caseInsensitiveCompare(header.key) == .orderedSame } } + pairs(value["headers"]))
        var auth = self.auth(value["auth"], notes: &notes) ?? inherited.auth
        auth.token = auth.token.map(convert)
        auth.username = auth.username.map(convert)
        auth.password = auth.password.map(convert)
        if let key = auth.apiKey { auth.apiKey = .init(name: convert(key.name), value: convert(key.value), inQuery: key.inQuery) }
        draft.auth = auth
        body(value["body"], into: &draft, convert: convert, notes: &notes)
        if !(value["preRequestScript"]?.scalarText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(value["testScript"]?.scalarText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            notes.append(ImportSupport.scriptsNote)
        }
        return draft
    }

    private static func body(_ value: JSONValue?, into draft: inout RequestDraft, convert: (String) -> String, notes: inout [String]) {
        guard let value, let contentType = value["contentType"]?.scalarText, !contentType.isEmpty else { return }
        switch contentType.lowercased() {
        case "multipart/form-data":
            let fields = (value["body"]?.arrayItems ?? []).compactMap { field -> KeyValuePair? in
                guard let key = field["key"]?.scalarText else { return nil }
                if field["isFile"]?.boolValue == true {
                    notes.append(ImportSupport.fileFieldsNote)
                    return nil
                }
                return KeyValuePair(key: convert(key), value: convert(ImportSupport.text(field["value"])), isEnabled: field["active"]?.boolValue != false)
            }
            draft.bodyType = .formData
            draft.body = ImportSupport.formBody(fields)
        case "application/x-www-form-urlencoded":
            draft.bodyType = .urlEncoded
            draft.body = ImportSupport.formBody(keyValueLines(convert(value["body"]?.scalarText ?? "")))
        case "application/octet-stream":
            draft.setFileBody(path: nil, notes: &notes)
        default:
            draft.setBody(mimeType: contentType, text: convert(value["body"]?.scalarText ?? ""))
        }
    }

    /// Hoppscotch's raw key-value text: one `key: value` per line; a line starting with `#` is disabled.
    static func keyValueLines(_ text: String) -> [KeyValuePair] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            var line = line.trimmingCharacters(in: .whitespaces)
            let disabled = line.hasPrefix("#")
            if disabled { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            guard let colon = line.firstIndex(of: ":") else { return line.isEmpty ? nil : KeyValuePair(key: line, value: "", isEnabled: !disabled) }
            return KeyValuePair(
                key: line[..<colon].trimmingCharacters(in: .whitespaces), value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces), isEnabled: !disabled)
        }
    }

    /// The authentication `value` sets; nil for "inherit" (or none written), so the folder's applies.
    private static func auth(_ value: JSONValue?, notes: inout [String]) -> AuthDraft? {
        guard let value, let type = value["authType"]?.scalarText, type != "inherit" else { return nil }
        guard value["authActive"]?.boolValue != false else { return AuthDraft() }
        func text(_ key: String) -> String { value[key]?.scalarText ?? "" }
        switch type {
        case "none": return AuthDraft()
        case "bearer": return .bearer(text("token"))
        case "basic": return .basic(text("username"), text("password"))
        case "api-key": return .apiKey(text("key"), text("value"), inQuery: text("addTo") == "QUERY_PARAMS" || text("addTo") == "Query params")
        case "oauth-2":
            notes.append(ImportSupport.oauthNote)
            let token = value["grantTypeInfo"]?["token"]?.scalarText ?? text("token")
            return .bearer(token.isEmpty ? "{{accessToken}}" : token)
        default:
            notes.append("\(type.capitalized) authentication isn't supported by Reqs, so those requests were imported without authentication.")
            return AuthDraft()
        }
    }

    private static func pairs(_ value: JSONValue?) -> [KeyValuePair] {
        (value?.arrayItems ?? []).compactMap { pair in
            guard let key = pair["key"]?.scalarText else { return nil }
            return KeyValuePair(key: key, value: ImportSupport.text(pair["value"]), isEnabled: pair["active"]?.boolValue != false)
        }
    }

    /// `<<name>>` written as `{{name}}`.
    static func variables(_ text: String) -> String {
        guard text.contains("<<") else { return text }
        return text.replacing(/<<\s*([A-Za-z0-9_.\-]+)\s*>>/) { "{{\($0.output.1)}}" }
    }

    // MARK: - Environments

    static func environments(_ tree: JSONValue, fallbackName: String) -> ImportedFile {
        let items = tree.arrayItems ?? [tree]
        let environments = items.enumerated().map { index, item in
            let fallback = item["name"] == nil && items.count == 1 ? "Globals" : items.count == 1 ? fallbackName : "\(fallbackName) \(index + 1)"
            return ExportImportService.ExportableEnvironment(
                name: ImportSupport.name(item["name"], or: fallback), isDefault: false, color: ImportSupport.color(index),
                variables: (item["variables"]?.arrayItems ?? []).compactMap(variable))
        }
        let notes =
            environments.contains { $0.variables.contains { $0.isSecret && $0.value.isEmpty } }
            ? ["Hoppscotch doesn't export secret values: fill them in under Manage Environments (⌘E)."] : []
        return ImportedFile(format: .hoppscotchEnvironment, environments: environments, notes: notes)
    }

    /// A variable: `value` in older files, `initialValue` and `currentValue` in newer ones (the shared value first).
    private static func variable(_ value: JSONValue) -> Variable? {
        guard let key = value["key"]?.scalarText, !key.isEmpty else { return nil }
        let candidates = [value["value"], value["initialValue"], value["currentValue"]].map { ImportSupport.text($0) }
        let text = candidates.first { !$0.isEmpty } ?? ""
        return Variable(key: key, value: variables(text), isSecret: value["secret"]?.boolValue == true)
    }
}
