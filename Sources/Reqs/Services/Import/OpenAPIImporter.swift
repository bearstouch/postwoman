import Foundation

/// OpenAPI 3.x and Swagger 2.0 specs, as JSON or YAML: one request per operation, grouped by tag, at `{{baseUrl}}`.
///
/// The first server is Default's `baseUrl`, and each other server an environment with its own. Path parameters become
/// variables (`/users/{id}` → `/users/{{id}}`, with the example as the value); query and header parameters take their
/// examples, enabled when required; a JSON body is the example, or one built from the schema. Security schemes become
/// Bearer, Basic or API key authentication with secret variables (`{{bearerToken}}`) to fill in.
enum OpenAPIImporter {
    static func isSpec(_ tree: JSONValue) -> Bool {
        guard tree["paths"]?.objectFields != nil || tree["webhooks"] != nil || tree["components"] != nil else { return false }
        if let version = tree["openapi"]?.scalarText, version.hasPrefix("3") { return true }
        if let version = tree["swagger"]?.scalarText, version.hasPrefix("2") { return true }
        return false
    }

    static func collection(_ tree: JSONValue, fallbackName: String) -> ImportedFile {
        var spec = Spec(root: tree)
        let servers = spec.servers()
        let methods = HTTPMethod.allCases.map { $0.rawValue.lowercased() }
        let tagOrder = (tree["tags"]?.arrayItems ?? []).compactMap { $0["name"]?.scalarText }

        var operations: [(tag: String?, path: String, method: Int, draft: RequestDraft)] = []
        for path in (tree["paths"]?.objectFields ?? [:]).keys.sorted() {
            let item = spec.resolve(tree["paths"]?[path])
            if item["trace"] != nil { spec.notes.append("TRACE operations aren't imported: Reqs doesn't send TRACE requests.") }
            for (methodIndex, method) in methods.enumerated() {
                guard let operation = item[method]?.objectFields.map(JSONValue.object) else { continue }
                let tag = operation["tags"]?[0]?.scalarText
                operations.append((tag, path, methodIndex, spec.request(operation, method: method, path: path, pathItem: item, tag: tag)))
            }
        }
        if (tree["paths"]?.objectFields ?? [:]).isEmpty { spec.notes.append("The spec has no paths, so there were no requests to import.") }
        func rank(_ tag: String?) -> (Int, String) {
            guard let tag else { return (Int.max, "") }
            return (tagOrder.firstIndex(of: tag) ?? tagOrder.count, tag)
        }
        operations.sort { (rank($0.tag).0, rank($0.tag).1, $0.path, $0.method) < (rank($1.tag).0, rank($1.tag).1, $1.path, $1.method) }

        var defaults = [Variable(key: "baseUrl", value: servers.first?.url ?? "")]
        defaults += spec.variables
        let others = servers.dropFirst().enumerated().map { index, server in
            ExportImportService.ExportableEnvironment(name: server.name, isDefault: false, color: ImportSupport.color(index), variables: [Variable(key: "baseUrl", value: server.url)])
        }
        let folder = ExportImportService.ExportableFolder(
            name: ImportSupport.name(tree["info"]?["title"], or: fallbackName), requests: operations.map(\.draft.exportable),
            environments: [ExportImportService.ExportableEnvironment(name: CollectionEnvironment.defaultName, isDefault: true, color: "blue", variables: defaults)] + others)
        let format: ImportFormat = tree["swagger"] != nil ? .swagger : .openAPI
        return ImportedFile(format: format, collections: [folder], notes: spec.notes)
    }
}

/// One spec being read: `$ref` resolution, the variables requests use, and notes.
private struct Spec {
    let root: JSONValue
    var variables: [Variable] = []
    var notes: [String] = []
    /// Nodes left for the request body being built: schemas that refer to each other widely would otherwise build a body
    /// of hundreds of megabytes. Reset for each operation.
    private var sampleNodes = 0
    private static let sampleBudget = 2_000

    var isSwagger: Bool { root["swagger"] != nil }

    init(root: JSONValue) { self.root = root }

    // MARK: - References

    /// `value` with a local `$ref` followed (a few hops at most); an external one is noted and left as it is.
    mutating func resolve(_ value: JSONValue?) -> JSONValue {
        var value = value ?? .null
        for _ in 0..<16 {
            guard let reference = value["$ref"]?.scalarText else { return value }
            guard let target = lookUp(reference) else {
                notes.append("References to other files ($ref: \"\(reference.prefix(60))\") aren't followed; those parts were left out.")
                return .null
            }
            value = target
        }
        return value
    }

    /// The value a local JSON pointer (`#/components/schemas/User`) names.
    func lookUp(_ reference: String) -> JSONValue? {
        guard reference.hasPrefix("#") else { return nil }
        var value = root
        for token in reference.dropFirst().split(separator: "/") {
            let key = token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~").removingPercentEncoding ?? String(token)
            if let next = value[key] {
                value = next
            } else if let position = Int(key), let next = value[position] {
                value = next
            } else {
                return nil
            }
        }
        return value
    }

    // MARK: - Servers

    /// Each server's name and URL (variables at their defaults, no trailing slash); the first is Default's.
    mutating func servers() -> [(name: String, url: String)] {
        if isSwagger {
            let scheme = root["schemes"]?[0]?.scalarText ?? "https"
            let basePath = root["basePath"]?.scalarText ?? ""
            guard let host = root["host"]?.scalarText, !host.isEmpty else {
                notes.append("The spec names no host: set baseUrl in the Default environment (⌘E).")
                return [("Default", trimmed(basePath))]
            }
            return [("Default", trimmed("\(scheme)://\(host)\(basePath)"))]
        }
        let servers = (root["servers"]?.arrayItems ?? []).compactMap { server -> (String, String)? in
            guard var url = server["url"]?.scalarText else { return nil }
            for (name, variable) in server["variables"]?.objectFields ?? [:] {
                url = url.replacingOccurrences(of: "{\(name)}", with: variable["default"]?.scalarText ?? "")
            }
            let description = server["description"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (description.isEmpty ? url : description, trimmed(url))
        }
        if servers.isEmpty || servers.first?.1.hasPrefix("/") == true || servers.first?.1.isEmpty == true {
            notes.append("The spec has no absolute server URL: set baseUrl in the Default environment (⌘E).")
        }
        return servers
    }

    private func trimmed(_ url: String) -> String { url.hasSuffix("/") ? String(url.dropLast()) : url }

    // MARK: - Operations

    mutating func request(_ operation: JSONValue, method: String, path: String, pathItem: JSONValue, tag: String?) -> RequestDraft {
        let summary = (operation["summary"]?.scalarText ?? operation["operationId"]?.scalarText)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = summary.flatMap { $0.isEmpty ? nil : $0 } ?? "\(method.uppercased()) \(path)"
        var draft = RequestDraft(name: ImportSupport.path([tag ?? "", title]))
        sampleNodes = 0
        draft.method = ImportSupport.method(method, notes: &notes)
        draft.url = "{{baseUrl}}" + path.replacing(/\{([^{}\/]+)\}/) { "{{\($0.output.1)}}" }

        // Path-level parameters, overridden by the operation's of the same name and place.
        var parameters: [String: JSONValue] = [:]
        var order: [String] = []
        for parameter in (pathItem["parameters"]?.arrayItems ?? []) + (operation["parameters"]?.arrayItems ?? []) {
            let resolved = resolve(parameter)
            guard let name = resolved["name"]?.scalarText, let place = resolved["in"]?.scalarText else { continue }
            let key = place + ":" + name
            if parameters[key] == nil { order.append(key) }
            parameters[key] = resolved
        }
        var formFields: [KeyValuePair] = []
        for key in order {
            guard let parameter = parameters[key], let name = parameter["name"]?.scalarText else { continue }
            let value = example(of: parameter)
            let required = parameter["required"]?.boolValue == true
            switch parameter["in"]?.scalarText {
            case "path": addVariable(name, value: value)
            case "query": draft.queryParams.append(KeyValuePair(key: name, value: value, isEnabled: required))
            case "header":
                // OpenAPI ignores these as parameters: the body and authentication set them.
                guard !["accept", "content-type", "authorization"].contains(name.lowercased()) else { continue }
                draft.headers.append(KeyValuePair(key: name, value: value, isEnabled: required))
            case "cookie": notes.append("Cookie parameters aren't imported: add them as a Cookie header.")
            case "body":
                draft.bodyType = .json
                draft.body = ImportSupport.prettyJSON(sample(parameter["schema"]))
            case "formData":
                if parameter["type"]?.scalarText == "file" { notes.append(ImportSupport.fileFieldsNote) } else { formFields.append(KeyValuePair(key: name, value: value)) }
            default: break
            }
        }
        if isSwagger {
            let consumes = (operation["consumes"]?.arrayItems ?? root["consumes"]?.arrayItems ?? []).compactMap(\.scalarText)
            if !formFields.isEmpty {
                draft.bodyType = consumes.contains("multipart/form-data") ? .formData : .urlEncoded
                draft.body = ImportSupport.formBody(formFields)
            } else if draft.bodyType == .json, let mime = consumes.first, !consumes.contains(where: { ImportSupport.bodyType(forMIMEType: $0.lowercased()) == .json }) {
                draft.setBody(mimeType: mime, text: "")
            }
        } else {
            requestBody(resolve(operation["requestBody"]), into: &draft)
        }
        authentication(operation["security"] ?? root["security"], into: &draft)
        return draft
    }

    /// An OpenAPI 3 request body: the JSON (or form, XML, text) media type, with its example or a sample of its schema.
    private mutating func requestBody(_ body: JSONValue, into draft: inout RequestDraft) {
        guard let content = body["content"]?.objectFields, !content.isEmpty else { return }
        let types = content.keys.sorted()
        let preferred: [(String) -> Bool] = [
            { ImportSupport.bodyType(forMIMEType: $0) == .json }, { $0 == "application/x-www-form-urlencoded" }, { $0 == "multipart/form-data" },
            { ImportSupport.bodyType(forMIMEType: $0) == .xml }, { $0.hasPrefix("text/") }
        ]
        let mime = preferred.lazy.compactMap { test in types.first { test($0.lowercased()) } }.first ?? types[0]
        let media = resolve(content[mime])
        let example = media["example"] ?? media["examples"]?.objectFields.flatMap { fields in fields.keys.sorted().first.map { resolve(fields[$0])["value"] ?? .null } }
        let value = example ?? sample(media["schema"])
        switch ImportSupport.bodyType(forMIMEType: mime.lowercased()) {
        case .json:
            draft.setBody(mimeType: mime, text: value.scalarText.flatMap { $0.isEmpty ? nil : $0 } ?? ImportSupport.prettyJSON(value))
            if mime.lowercased() != "application/json", !draft.hasHeader("Content-Type") { draft.headers.append(KeyValuePair(key: "Content-Type", value: mime)) }
        case .urlEncoded, .formData:
            let schema = resolve(media["schema"])
            let fields = (value.objectFields ?? [:]).keys.sorted().compactMap { key -> KeyValuePair? in
                let property = resolve(schema["properties"]?[key])
                if property["format"]?.scalarText == "binary" || property["type"]?.scalarText == "file" {
                    notes.append(ImportSupport.fileFieldsNote)
                    return nil
                }
                return KeyValuePair(key: key, value: ImportSupport.text(value[key]))
            }
            draft.setBody(mimeType: mime, text: ImportSupport.formBody(fields))
        case .xml:
            draft.setBody(mimeType: mime, text: value.scalarText ?? "")
            if mime.lowercased() != "application/xml", !draft.hasHeader("Content-Type") { draft.headers.append(KeyValuePair(key: "Content-Type", value: mime)) }
        default:
            if mime.lowercased() == "application/octet-stream" || mime.hasPrefix("image/") {
                notes.append(ImportSupport.fileFieldsNote)
                return
            }
            draft.setBody(mimeType: mime, text: value.scalarText ?? "")
        }
    }

    /// The operation's first security requirement, as Reqs authentication with secret variables to fill in.
    private mutating func authentication(_ security: JSONValue?, into draft: inout RequestDraft) {
        guard let requirement = security?.arrayItems?.first(where: { !($0.objectFields ?? [:]).isEmpty }), let name = requirement.objectFields?.keys.sorted().first else { return }
        let schemes = isSwagger ? root["securityDefinitions"] : root["components"]?["securitySchemes"]
        let scheme = resolve(schemes?[name])
        switch (scheme["type"]?.scalarText, scheme["scheme"]?.scalarText?.lowercased()) {
        case ("http", "bearer"):
            addVariable("bearerToken", secret: true)
            draft.auth = .bearer("{{bearerToken}}")
        case ("http", "basic"), ("basic", _):
            addVariable("username")
            addVariable("password", secret: true)
            draft.auth = .basic("{{username}}", "{{password}}")
        case ("apiKey", _):
            guard let keyName = scheme["name"]?.scalarText else { return }
            if scheme["in"]?.scalarText == "cookie" {
                notes.append("API keys sent in a cookie aren't imported: add them as a Cookie header.")
                return
            }
            addVariable(name, secret: true)
            draft.auth = .apiKey(keyName, "{{\(name)}}", inQuery: scheme["in"]?.scalarText == "query")
        case ("oauth2", _), ("openIdConnect", _):
            notes.append(ImportSupport.oauthNote)
            addVariable("accessToken", secret: true)
            draft.auth = .bearer("{{accessToken}}")
        default:
            notes.append("Some security schemes (\(scheme["type"]?.scalarText ?? name)) aren't supported by Reqs, so those requests were imported without authentication.")
        }
    }

    private mutating func addVariable(_ key: String, value: String = "", secret: Bool = false) {
        guard !variables.contains(where: { $0.key == key }) else { return }
        variables.append(Variable(key: key, value: value, isSecret: secret))
    }

    // MARK: - Examples

    /// A parameter's example: its own, the first of its examples, else its schema's example, default or first enum value.
    private mutating func example(of parameter: JSONValue) -> String {
        if let example = parameter["example"] ?? parameter["x-example"] { return ImportSupport.text(example) }
        if let examples = parameter["examples"]?.objectFields, let first = examples.keys.sorted().first {
            return ImportSupport.text(resolve(examples[first])["value"])
        }
        let schema = isSwagger ? parameter : resolve(parameter["schema"])
        for key in ["example", "default"] { if let value = schema[key] { return ImportSupport.text(value) } }
        if let first = schema["enum"]?[0] { return ImportSupport.text(first) }
        return ""
    }

    /// A value matching `schema`: its example, default or first enum value, else one built from its type, properties and items.
    mutating func sample(_ schema: JSONValue?, depth: Int = 0, references: Set<String> = []) -> JSONValue {
        guard let schema else { return .null }
        // Every value counts, cut-off ones too, so a wide object stops listing properties once the budget is spent.
        sampleNodes += 1
        guard depth < 10, sampleNodes <= Self.sampleBudget else { return .null }
        if let reference = schema["$ref"]?.scalarText {
            guard !references.contains(reference) else { return .null }
            return sample(resolve(schema), depth: depth + 1, references: references.union([reference]))
        }
        if let example = schema["example"] { return example }
        if let first = schema["examples"]?[0] { return first }
        if let value = schema["default"] ?? schema["const"] { return value }
        if let first = schema["enum"]?[0] { return first }
        if let parts = schema["allOf"]?.arrayItems {
            var merged: [String: JSONValue] = [:]
            for part in parts { merged.merge(sample(part, depth: depth + 1, references: references).objectFields ?? [:]) { _, new in new } }
            return .object(merged)
        }
        if let first = (schema["oneOf"] ?? schema["anyOf"])?[0] { return sample(first, depth: depth + 1, references: references) }
        let types = schema["type"]?.arrayItems?.compactMap(\.scalarText) ?? [schema["type"]?.scalarText].compactMap { $0 }
        let type = types.first { $0 != "null" } ?? (schema["properties"] != nil ? "object" : schema["items"] != nil ? "array" : nil)
        switch type {
        case "object":
            var object: [String: JSONValue] = [:]
            for (key, property) in (schema["properties"]?.objectFields ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard sampleNodes < Self.sampleBudget else { break }
                let resolved = resolve(property)
                guard resolved["readOnly"]?.boolValue != true else { continue }
                object[key] = sample(property, depth: depth + 1, references: references)
            }
            return .object(object)
        case "array": return .array(schema["items"].map { [sample($0, depth: depth + 1, references: references)] } ?? [])
        case "integer", "number": return .number(0)
        case "boolean": return .bool(false)
        case "string":
            switch schema["format"]?.scalarText {
            case "date-time": return .string("2026-01-01T00:00:00Z")
            case "date": return .string("2026-01-01")
            case "email": return .string("user@example.com")
            case "uuid": return .string("00000000-0000-0000-0000-000000000000")
            case "uri", "url": return .string("https://example.com")
            default: return .string("string")
            }
        default: return .null
        }
    }
}
