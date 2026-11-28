import Foundation
import SwiftData

extension Notification.Name {
    /// Posted on the main actor just before an agent deletes collections, requests, environments or history entries.
    /// `userInfo["ids"]` is the `Set<UUID>` of every model about to go, so views drop selections of them.
    static let remoteAgentWillDelete = Notification.Name("PostWoman.remoteAgentWillDelete")
}

/// Runs MCP tools against the app's SwiftData store. Main-actor isolated: SwiftData models belong to
/// the main context, the same one the windows show, so agent changes appear at once.
@MainActor
final class MCPToolHandler {
    static let defaultMaxBodyBytes = 262_144
    /// A streamed response is stopped after this long, so the agent gets an answer (with what arrived) before its client gives up.
    static let maxStreamSeconds: Double = 90
    /// The most stream events a response lists.
    static let maxStreamEvents = 500

    /// How long a stream may keep arriving; tests shorten it.
    var streamDeadline = MCPToolHandler.maxStreamSeconds

    /// Whether the response being received turned out to be a stream (only a stream reports progress).
    private final class StreamProgress {
        var started = false
    }

    private let container: ModelContainer
    private let client: HTTPClient
    /// Where the History limit is read from.
    private let defaults: UserDefaults

    init(container: ModelContainer, client: HTTPClient = HTTPClient(), defaults: UserDefaults = .standard) {
        self.container = container; self.client = client; self.defaults = defaults
    }

    private var context: ModelContext { container.mainContext }

    func call(_ name: String, _ arguments: [String: JSONValue]) async -> Result<JSONValue, MCPToolError> {
        guard let tool = MCPTools.byName[name] else { return .failure(.invalidParams("Unknown tool \(name).")) }
        // The windows edit this same context and leave saving to autosave. Saving first makes a failed tool's rollback undo
        // only what the tool did, not what the user typed a moment ago (and paging then sees every entry: `fetchOffset`).
        if context.hasChanges { try? context.save() }
        do {
            let args = try Arguments(arguments, tool: tool)
            let value = try await run(tool.name, args)
            if context.hasChanges { try context.save() }
            return .success(value)
        } catch let error as MCPToolError {
            context.rollback()
            return .failure(error)
        } catch {
            context.rollback()
            return .failure(.internalError(error.localizedDescription))
        }
    }

    private func run(_ name: String, _ args: Arguments) async throws -> JSONValue {
        switch name {
        case "collection_list":
            return .object(["collections": .array(try folders().map { Self.summary($0) })])
        case "collection_get":
            let folder = try folder(args.uuid("id")!)
            var value = Self.summary(folder)
            if try args.bool("includeRequests") ?? true, case .object(var object) = value {
                object["requests"] = .array(Self.sorted(folder.requests).map { Self.json($0) })
                value = .object(object)
            }
            return value
        case "collection_create":
            let folder = Folder(name: try args.nonEmptyString("name")!, sortOrder: try args.int("sortOrder") ?? folders().count)
            context.insert(folder)
            folder.ensureDefaultEnvironment()
            return Self.summary(folder)
        case "collection_update":
            let folder = try folder(args.uuid("id")!)
            if let name = try args.nonEmptyString("name") { folder.name = name }
            if let order = try args.int("sortOrder") { folder.sortOrder = order }
            folder.updatedAt = Date()
            return Self.summary(folder)
        case "collection_delete":
            let folder = try folder(args.uuid("id")!)
            let requests = folder.requests ?? []
            announceDeletion([folder.id] + requests.map(\.id) + (folder.environments ?? []).map(\.id))
            let result: JSONValue = .object(["deleted": .string(folder.id.uuidString), "deletedRequests": .number(Double(requests.count))])
            context.delete(folder)
            return result
        case "request_list":
            let collection = try args.uuid("collectionId").map(folder)
            let requests = try collection.map { Self.sorted($0.requests) } ?? folders().flatMap { Self.sorted($0.requests) }
            return .object(["requests": .array(requests.map { Self.summary($0) })])
        case "request_get":
            return Self.json(try request(args.uuid("id")!))
        case "request_create":
            let folder = try args.uuid("collectionId").map(folder) ?? (try defaultFolder())
            let request = APIRequest(name: "New Request", folder: folder)
            request.sortOrder = folder.nextRequestSortOrder(excluding: request)
            try Self.apply(args, to: request)
            context.insert(request)
            return Self.json(request)
        case "request_update":
            let request = try request(args.uuid("id")!)
            if let target = try args.uuid("collectionId").map(folder), target.id != request.folder?.id {
                request.sortOrder = target.nextRequestSortOrder(excluding: request)
                request.folder = target
            }
            try Self.apply(args, to: request)
            request.updatedAt = Date()
            return Self.json(request)
        case "request_delete":
            let request = try request(args.uuid("id")!)
            announceDeletion([request.id])
            let id = request.id
            context.delete(request)
            return .object(["deleted": .string(id.uuidString)])
        case "request_execute":
            return try await execute(args)
        case "environment_list":
            let folder = try folder(args.uuid("collectionId")!)
            folder.ensureDefaultEnvironment()
            let environments = [folder.defaultEnvironment].compactMap { $0 } + folder.overrideEnvironments
            return .object([
                "collectionId": .string(folder.id.uuidString), "selectedEnvironmentId": .from(folder.selectedEnvironment?.id.uuidString),
                "environments": .array(environments.map { Self.json($0) })
            ])
        case "environment_get":
            return Self.json(try environment(args.uuid("id")!))
        case "environment_create":
            let folder = try folder(args.uuid("collectionId")!)
            let color = try args.environmentColor() ?? .green
            let environment = folder.addEnvironment(named: try args.nonEmptyString("name")!, color: color)
            if let variables = try args.variables() { environment.variables = Self.merge(variables, into: []) }
            if try args.bool("select") == true { folder.selectedEnvironment = environment }
            return Self.json(environment)
        case "environment_update":
            let environment = try environment(args.uuid("id")!)
            if let name = try args.nonEmptyString("name") { environment.name = name }
            if let color = try args.environmentColor() { environment.color = color }
            if let variables = try args.variables() { environment.variables = Self.merge(variables, into: environment.variables) }
            environment.updatedAt = Date()
            return Self.json(environment)
        case "environment_delete":
            let environment = try environment(args.uuid("id")!)
            guard !environment.isDefault else {
                throw MCPToolError(code: "NOT_ALLOWED", message: "A collection's Default environment can't be deleted.")
            }
            if let folder = environment.folder, folder.selectedEnvironmentID == environment.id { folder.selectedEnvironmentID = nil }
            announceDeletion([environment.id])
            let id = environment.id
            context.delete(environment)
            return .object(["deleted": .string(id.uuidString)])
        case "environment_select":
            let folder = try folder(args.uuid("collectionId")!)
            folder.ensureDefaultEnvironment()
            folder.selectedEnvironment = try chosenEnvironment(args, in: folder)
            return .object([
                "collectionId": .string(folder.id.uuidString), "selectedEnvironmentId": .from(folder.selectedEnvironment?.id.uuidString),
                "environment": .string(folder.activeEnvironmentName)
            ])
        case "history_list":
            return try historyList(args)
        case "history_get":
            return Self.json(try history(args.uuid("id")!), maxBodyBytes: try args.int("maxBodyBytes") ?? Self.defaultMaxBodyBytes)
        case "history_create":
            let entry = RequestHistory(url: try args.nonEmptyString("url")!, method: .get)
            entry.savedRequestID = try args.uuid("requestId")
            if let timestamp = try args.date("timestamp") { entry.timestamp = timestamp }
            try Self.apply(args, to: entry)
            // Retention keeps the newest entries, so one older than all of a full History would be deleted at once.
            let limit = HistoryRetention.limit(in: defaults)
            var oldestKept = FetchDescriptor<RequestHistory>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
            oldestKept.fetchOffset = limit - 1
            oldestKept.fetchLimit = 1
            if let oldest = try context.fetch(oldestKept).first, entry.timestamp <= oldest.timestamp {
                throw MCPToolError(
                    code: "NOT_ALLOWED",
                    message: "History keeps the \(limit) most recent entries, and this one is older than all of them. Raise the limit in Settings → General to add it.")
            }
            context.insert(entry)
            HistoryRetention.trim(context, limit: limit)
            return Self.json(entry, maxBodyBytes: Self.defaultMaxBodyBytes)
        case "history_update":
            let entry = try history(args.uuid("id")!)
            try Self.apply(args, to: entry)
            return Self.json(entry, maxBodyBytes: Self.defaultMaxBodyBytes)
        case "history_delete":
            let entry = try history(args.uuid("id")!)
            announceDeletion([entry.id])
            let id = entry.id
            context.delete(entry)
            return .object(["deleted": .string(id.uuidString)])
        case "history_clear":
            var entries = try context.fetch(FetchDescriptor<RequestHistory>())
            if let requestID = try args.uuid("requestId") { entries = entries.filter { $0.savedRequestID == requestID } }
            announceDeletion(entries.map(\.id))
            for entry in entries { context.delete(entry) }
            return .object(["deleted": .number(Double(entries.count))])
        default:
            throw MCPToolError.invalidParams("Unknown tool \(name).")
        }
    }

    // MARK: - Execute

    private func execute(_ args: Arguments) async throws -> JSONValue {
        let maxBody = try args.int("maxBodyBytes") ?? Self.defaultMaxBodyBytes
        let request: APIRequest
        switch (try args.uuid("id"), try args.object("request")) {
        case (let id?, nil): request = try self.request(id)
        case (nil, let inline?):
            // Not inserted: an ad-hoc request is sent and recorded in History, never saved.
            request = APIRequest(name: "", url: "")
            try Self.apply(inline, to: request)
            if request.name.isEmpty { request.name = request.url }
        case (nil, nil): throw MCPToolError.invalidParams("Pass id (a saved request) or request (an ad-hoc one).")
        case (_?, _?): throw MCPToolError.invalidParams("Pass id or request, not both.")
        }
        guard !request.url.isEmpty else { throw MCPToolError.invalidParams("The request has no URL.", field: "url") }

        // The collection's environment fills in {{variables}}: the saved request's own collection, or collectionId for an ad-hoc one.
        let collection: Folder?
        if try args.object("request") != nil {
            collection = try args.uuid("collectionId").map(folder)
        } else {
            if try args.uuid("collectionId") != nil {
                throw MCPToolError.invalidParams("A saved request resolves with its own collection; collectionId is for ad-hoc requests.", field: "collectionId")
            }
            collection = request.folder
        }
        let resolver: VariableResolver
        var environmentName: String?
        if let collection {
            collection.ensureDefaultEnvironment()
            let environment = try args.string("environmentId") == nil ? collection.selectedEnvironment : try chosenEnvironment(args, in: collection)
            resolver = collection.resolver(with: environment)
            environmentName = environment?.name ?? collection.defaultEnvironmentName
        } else {
            // "default" in any case, as with a collection (chosenEnvironment).
            if let choice = try args.string("environmentId"), choice.lowercased() != "default" {
                throw MCPToolError.invalidParams("The request is in no collection, so it has no environments. Pass collectionId.", field: "environmentId")
            }
            resolver = .empty
        }
        let template = RequestSnapshot(request)
        let sent = template.resolved(with: resolver)
        let recorded = template.resolved(with: resolver, redactSecrets: true)
        let unresolved = template.missingVariables(with: resolver)

        let history = RequestHistory(request: request, sent: recorded, environmentName: environmentName)
        if try args.object("request") != nil { history.savedRequestID = nil }
        let record = try args.bool("recordHistory") ?? true
        do {
            let response = try await executeWithDeadline(sent)
            history.record(response)
            if record {
                context.insert(history)
                HistoryRetention.trim(context, limit: HistoryRetention.limit(in: defaults))
            }
            var result: [String: JSONValue] = [
                "response": Self.json(response, maxBodyBytes: maxBody), "resolvedUrl": .string(recorded.url),
                "environment": .from(environmentName), "unresolvedVariables": .array(unresolved.map(JSONValue.string))
            ]
            if record { result["historyId"] = .string(history.id.uuidString) }
            return .object(result)
        } catch {
            history.record(error)
            if record {
                context.insert(history)
                HistoryRetention.trim(context, limit: HistoryRetention.limit(in: defaults))
            }
            // Saved before the rollback that follows this error: the History entry, and whatever the user did during the send.
            try? context.save()
            throw MCPToolError(
                code: "REQUEST_FAILED", message: error.localizedDescription,
                details: record ? .object(["historyId": .string(history.id.uuidString)]) : nil)
        }
    }

    /// Sends `request`, stopping a stream still arriving after `streamDeadline` (it returns what came, `end: stopped`).
    /// Any other response has as long as the timeout chosen in Settings allows, and at most its upper bound in all.
    private func executeWithDeadline(_ request: RequestSnapshot) async throws -> HTTPResponse {
        let client = self.client
        let progress = StreamProgress()
        let work = Task { @MainActor in try await client.execute(request: request) { _ in progress.started = true } }
        let streamDeadline = streamDeadline
        let deadline = Task { @MainActor in
            try await Task.sleep(for: .seconds(streamDeadline))
            if !progress.started { try await Task.sleep(for: .seconds(max(RequestTimeout.range.upperBound - streamDeadline, 0))) }
            work.cancel()
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func historyList(_ args: Arguments) throws -> JSONValue {
        let limit = try args.int("limit") ?? 50, offset = try args.int("offset") ?? 0
        var descriptor = FetchDescriptor<RequestHistory>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        let requestID = try args.uuid("requestId")
        if let requestID { descriptor.predicate = #Predicate { $0.savedRequestID == requestID } }
        let total = try context.fetchCount(descriptor)
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        let entries = try context.fetch(descriptor)
        var result: [String: JSONValue] = ["entries": .array(entries.map { Self.summary($0) }), "total": .number(Double(total))]
        if offset + entries.count < total { result["nextOffset"] = .number(Double(offset + entries.count)) }
        return .object(result)
    }

    // MARK: - Lookup

    private func folders() throws -> [Folder] { try context.fetch(FetchDescriptor<Folder>(sortBy: [SortDescriptor(\.sortOrder)])) }

    private func folder(_ id: UUID) throws -> Folder {
        guard let folder = try context.fetch(FetchDescriptor<Folder>(predicate: #Predicate { $0.id == id })).first else { throw MCPToolError.notFound("collection", id) }
        return folder
    }

    private func request(_ id: UUID) throws -> APIRequest {
        guard let request = try context.fetch(FetchDescriptor<APIRequest>(predicate: #Predicate { $0.id == id })).first else { throw MCPToolError.notFound("request", id) }
        return request
    }

    private func history(_ id: UUID) throws -> RequestHistory {
        guard let entry = try context.fetch(FetchDescriptor<RequestHistory>(predicate: #Predicate { $0.id == id })).first else {
            throw MCPToolError.notFound("history entry", id)
        }
        return entry
    }

    /// As the New Request command: the first collection, or a new "Default Collection".
    private func defaultFolder() throws -> Folder {
        if let first = try folders().first { return first }
        let folder = Folder(name: "Default Collection")
        context.insert(folder)
        folder.ensureDefaultEnvironment()
        return folder
    }

    private func environment(_ id: UUID) throws -> CollectionEnvironment {
        guard let environment = try context.fetch(FetchDescriptor<CollectionEnvironment>(predicate: #Predicate { $0.id == id })).first else {
            throw MCPToolError.notFound("environment", id)
        }
        return environment
    }

    /// `environmentId`: one of the collection's environments, or "default" (or nothing) for Default only, which is nil.
    private func chosenEnvironment(_ args: Arguments, in folder: Folder) throws -> CollectionEnvironment? {
        guard let choice = try args.string("environmentId"), choice.lowercased() != "default" else { return nil }
        guard let id = UUID(uuidString: choice) else { throw MCPToolError.invalidParams("environmentId must be an environment ID or \"default\".", field: "environmentId") }
        guard let environment = (folder.environments ?? []).first(where: { $0.id == id }) else {
            throw MCPToolError(
                code: "NOT_FOUND", message: "\(folder.name) has no environment with the ID \(choice).", details: .object(["id": .string(choice)]))
        }
        return environment.isDefault ? nil : environment
    }

    /// The variables an agent passed, keeping the saved value of a secret it sent without one (secrets are write-only).
    private static func merge(_ incoming: [Arguments.VariableInput], into existing: [Variable]) -> [Variable] {
        incoming.map { input in
            // Keys arrive trimmed, and the app stores them as typed (it resolves them trimmed too).
            let saved = existing.first { $0.key.trimmingCharacters(in: .whitespaces) == input.key }
            let isSecret = input.isSecret ?? saved?.isSecret ?? false
            let value = input.value ?? (isSecret ? saved?.value : nil) ?? ""
            return Variable(key: input.key, value: value, isEnabled: input.isEnabled, isSecret: isSecret)
        }
    }

    private func announceDeletion(_ ids: [UUID]) {
        NotificationCenter.default.post(name: .remoteAgentWillDelete, object: nil, userInfo: ["ids": Set(ids)])
    }

    private static func sorted(_ requests: [APIRequest]?) -> [APIRequest] { (requests ?? []).sorted { $0.sortOrder < $1.sortOrder } }

    // MARK: - Writing fields

    private static func apply(_ args: Arguments, to request: APIRequest) throws {
        if let name = try args.nonEmptyString("name") { request.name = name }
        if let url = try args.string("url") { request.url = url }
        if let method = try args.method() { request.method = method }
        if let headers = try args.pairs("headers") { request.headers = headers }
        if let params = try args.pairs("queryParams") { request.queryParams = params }
        if let body = try args.string("body") {
            request.bodyContent = body
            // A body with no type would never be sent; JSON is the editor's usual choice.
            if request.bodyType == .none, try args.string("bodyType") == nil, !body.isEmpty { request.bodyType = .json }
        }
        if let type = try args.bodyType() { request.bodyType = type }
        if let auth = try args.object("auth") {
            if let type = try auth.authType() { request.authenticationType = type }
            if let token = try auth.string("token") { request.authBearerToken = token }
            if let username = try auth.string("username") { request.authBasicUsername = username }
            if let password = try auth.string("password") { request.authBasicPassword = password }
            if let oauth = try auth.object("oauth2") {
                var config = request.authOAuthConfig ?? OAuthConfig()
                if let value = try oauth.string("authorizationURL") { config.authorizationURL = value }
                if let value = try oauth.string("tokenURL") { config.tokenURL = value }
                if let value = try oauth.string("clientID") { config.clientID = value }
                if let value = try oauth.string("clientSecret") { config.clientSecret = value }
                if let value = try oauth.string("scope") { config.scope = value }
                if let value = try oauth.string("redirectURI") { config.redirectURI = value }
                request.authOAuthConfig = config
            }
        }
    }

    private static func apply(_ args: Arguments, to entry: RequestHistory) throws {
        if let name = try args.nonEmptyString("name") { entry.requestName = name }
        if let url = try args.nonEmptyString("url") { entry.url = url }
        if let method = try args.method() { entry.method = method }
        if let headers = try args.pairs("headers") { entry.requestHeaders = headers }
        if let params = try args.pairs("queryParams") { entry.queryParams = params }
        if let body = try args.string("body") { entry.requestBody = body.isEmpty ? nil : body }
        if let type = try args.bodyType() { entry.bodyType = type }
        // History keeps no OAuth configuration, so auth.oauth2 is an unknown argument here, as in the schema.
        if let auth = try args.object("auth", allowed: MCPTools.historyAuthFields) {
            if let type = try auth.authType() { entry.authenticationType = type }
            if let token = try auth.string("token") { entry.authBearerToken = token }
            if let username = try auth.string("username") { entry.authBasicUsername = username }
            if let password = try auth.string("password") { entry.authBasicPassword = password }
        }
        if let response = try args.object("response") {
            let body = try response.string("body")
            entry.record(
                HTTPResponse(
                    statusCode: try response.int("status")!, headers: try response.pairs("headers") ?? [], body: body,
                    responseTime: try response.double("timeMs") ?? 0, contentType: try response.string("contentType"), bodySize: body?.utf8.count))
        }
        if let message = try args.string("errorMessage") {
            entry.errorMessage = message.isEmpty ? nil : message
            // With the error cleared, success is again what the status says.
            entry.wasSuccessful = message.isEmpty && entry.statusCode.map { (200..<300).contains($0) } ?? false
        }
    }

    // MARK: - Reading fields

    private static func summary(_ folder: Folder) -> JSONValue {
        let environments = [folder.defaultEnvironment].compactMap { $0 } + folder.overrideEnvironments
        return .object([
            "id": .string(folder.id.uuidString), "name": .string(folder.name), "sortOrder": .number(Double(folder.sortOrder)),
            "requestCount": .number(Double(folder.requests?.count ?? 0)), "createdAt": .from(folder.createdAt), "updatedAt": .from(folder.updatedAt),
            "environments": .array(
                environments.map { .object(["id": .string($0.id.uuidString), "name": .string($0.name), "isDefault": .bool($0.isDefault)]) }),
            "selectedEnvironmentId": .from(folder.selectedEnvironment?.id.uuidString)
        ])
    }

    /// An environment and its variables. Secret values are write-only: `value` is null and `valueSet` says whether one is saved.
    static func json(_ environment: CollectionEnvironment) -> JSONValue {
        let inUse = environment.isDefault ? true : environment.folder?.selectedEnvironmentID == environment.id
        return .object([
            "id": .string(environment.id.uuidString), "name": .string(environment.name), "color": .string(environment.color.rawValue),
            "isDefault": .bool(environment.isDefault), "inUse": .bool(inUse), "collectionId": .from(environment.folder?.id.uuidString),
            "variables": .array(
                environment.variables.map { variable in
                    .object([
                        "key": .string(variable.key), "value": variable.isSecret ? .null : .string(variable.value), "valueSet": .bool(!variable.value.isEmpty),
                        "enabled": .bool(variable.isEnabled), "secret": .bool(variable.isSecret)
                    ])
                }),
            "updatedAt": .from(environment.updatedAt)
        ])
    }

    private static func summary(_ request: APIRequest) -> JSONValue {
        .object([
            "id": .string(request.id.uuidString), "name": .string(request.name), "method": .string(request.method.rawValue), "url": .string(request.url),
            "collectionId": .from(request.folder?.id.uuidString)
        ])
    }

    static func json(_ request: APIRequest) -> JSONValue {
        var auth = Self.auth(request.authenticationType, token: request.authBearerToken, username: request.authBasicUsername, password: request.authBasicPassword)
        if let config = request.authOAuthConfig, case .object(var object) = auth {
            object["oauth2"] = .object([
                "authorizationURL": .string(config.authorizationURL), "tokenURL": .string(config.tokenURL), "clientID": .string(config.clientID),
                "clientSecretSet": .bool(!config.clientSecret.isEmpty), "scope": .string(config.scope), "redirectURI": .string(config.redirectURI)
            ])
            auth = .object(object)
        }
        return .object([
            "id": .string(request.id.uuidString), "name": .string(request.name), "collectionId": .from(request.folder?.id.uuidString),
            "method": .string(request.method.rawValue), "url": .string(request.url), "headers": pairs(request.headers), "queryParams": pairs(request.queryParams),
            "bodyType": .string(MCPBodyType(request.bodyType).rawValue), "body": .string(request.bodyContent), "auth": auth,
            "sortOrder": .number(Double(request.sortOrder)), "createdAt": .from(request.createdAt), "updatedAt": .from(request.updatedAt)
        ])
    }

    private static func summary(_ entry: RequestHistory) -> JSONValue {
        .object([
            "id": .string(entry.id.uuidString), "timestamp": .from(entry.timestamp), "requestName": .from(entry.requestName),
            "method": .string(entry.method.rawValue), "url": .string(entry.url), "status": .from(entry.statusCode), "wasSuccessful": .bool(entry.wasSuccessful),
            "timeMs": .from(entry.responseTime), "errorMessage": .from(entry.errorMessage), "requestId": .from(entry.savedRequestID?.uuidString)
        ])
    }

    static func json(_ entry: RequestHistory, maxBodyBytes: Int) -> JSONValue {
        let request: JSONValue = .object([
            "name": .from(entry.requestName), "method": .string(entry.method.rawValue), "url": .string(entry.url), "headers": pairs(entry.requestHeaders),
            "queryParams": pairs(entry.queryParams ?? []), "bodyType": .from(entry.bodyType.map { MCPBodyType($0).rawValue }), "body": .from(entry.requestBody),
            "auth": auth(entry.authenticationType ?? .none, token: entry.authBearerToken, username: entry.authBasicUsername, password: entry.authBasicPassword)
        ])
        var value: [String: JSONValue] = [
            "id": .string(entry.id.uuidString), "timestamp": .from(entry.timestamp), "requestId": .from(entry.savedRequestID?.uuidString),
            "wasSuccessful": .bool(entry.wasSuccessful), "errorMessage": .from(entry.errorMessage), "request": request
        ]
        if entry.statusCode != nil, let response = entry.response { value["response"] = json(response, maxBodyBytes: maxBodyBytes) }
        return .object(value)
    }

    static func json(_ response: HTTPResponse, maxBodyBytes: Int) -> JSONValue {
        var value: [String: JSONValue] = [
            "status": .number(Double(response.statusCode)), "statusText": .string(response.statusText),
            "headers": pairs(response.headers.sorted { $0.key.lowercased() < $1.key.lowercased() }), "contentType": .from(response.contentType),
            "timeMs": .number((response.responseTime * 10).rounded() / 10), "size": .from(response.bodySize ?? response.body?.utf8.count)
        ]
        if let body = response.body {
            let (text, truncated) = truncate(body, to: maxBodyBytes)
            value["body"] = .string(text)
            value["bodyTruncated"] = .bool(truncated)
        } else {
            value["body"] = .null
            if (response.bodySize ?? 0) > 0 { value["bodyNote"] = .string("The body is not UTF-8 text, so it is not shown.") }
        }
        if let timing = response.timing, let data = try? JSONEncoder().encode(timing), let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) {
            value["timing"] = decoded
        }
        if let stream = response.stream { value["stream"] = json(stream, maxTextBytes: maxBodyBytes) }
        return .object(value)
    }

    /// A streamed response's events (the first `maxStreamEvents`), assembled LLM text and how it ended.
    static func json(_ stream: StreamInfo, maxTextBytes: Int) -> JSONValue {
        func ms(_ value: Double?) -> JSONValue { .from(value.map { ($0 * 10).rounded() / 10 }) }
        var value: [String: JSONValue] = [
            "kind": .string(stream.kind.rawValue), "eventCount": .number(Double(stream.events.count)),
            "firstByteMs": ms(stream.firstByteTime), "firstTextMs": ms(stream.firstTextTime),
            "events": .array(
                stream.events.prefix(maxStreamEvents).map { event in
                    .object(["t": ms(event.time), "event": .from(event.event), "data": .string(event.data), "id": .from(event.eventID)])
                }),
            "eventsTruncated": .bool(stream.events.count > maxStreamEvents)
        ]
        switch stream.end {
        case .streaming: value["end"] = .string("streaming")
        case .completed: value["end"] = .string("completed")
        case .stopped: value["end"] = .string("stopped")
        case .failed(let message):
            value["end"] = .string("failed")
            value["error"] = .string(message)
        }
        if let text = stream.text {
            let (cut, truncated) = truncate(text, to: maxTextBytes)
            value["text"] = .string(cut)
            value["textTruncated"] = .bool(truncated)
        } else {
            value["text"] = .null
        }
        return .object(value)
    }

    private static func auth(_ type: AuthenticationType, token: String?, username: String?, password: String?) -> JSONValue {
        var value: [String: JSONValue] = ["type": .string(MCPAuthType(type).rawValue), "tokenSet": .bool(!(token ?? "").isEmpty)]
        value["username"] = .from(username)
        value["passwordSet"] = .bool(!(password ?? "").isEmpty)
        return .object(value)
    }

    private static func pairs(_ pairs: [KeyValuePair]) -> JSONValue {
        .array(pairs.map { .object(["key": .string($0.key), "value": .string($0.value), "enabled": .bool($0.isEnabled)]) })
    }

    /// At most `limit` UTF-8 bytes, cut on a character boundary.
    static func truncate(_ text: String, to limit: Int) -> (String, Bool) {
        guard text.utf8.count > limit else { return (text, false) }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: limit)
        while end > text.startIndex, String.Index(end, within: text) == nil { end = text.utf8.index(before: end) }
        return (String(text[..<end]), true)
    }
}

/// A tool's arguments, checked against its schema: unknown names and wrong types are INVALID_PARAMS.
struct Arguments {
    private let values: [String: JSONValue]
    private let path: String

    init(_ values: [String: JSONValue], tool: MCPTool) throws {
        try self.init(values, allowed: Set(tool.properties.keys), path: "")
        for name in tool.required where values[name] == nil || values[name] == .null {
            throw MCPToolError.invalidParams("\(name) is required.", field: name)
        }
    }

    private init(_ values: [String: JSONValue], allowed: Set<String>, path: String) throws {
        if let unknown = values.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw MCPToolError.invalidParams("Unknown argument \(path)\(unknown).", field: path + unknown)
        }
        self.values = values; self.path = path
    }

    private func value(_ name: String) -> JSONValue? {
        guard let value = values[name], value != .null else { return nil }
        return value
    }

    private func invalid(_ name: String, _ expected: String) -> MCPToolError { .invalidParams("\(path)\(name) must be \(expected).", field: path + name) }

    func string(_ name: String) throws -> String? {
        guard let value = value(name) else { return nil }
        guard case .string(let text) = value else { throw invalid(name, "a string") }
        return text
    }

    func nonEmptyString(_ name: String) throws -> String? {
        guard let text = try string(name) else { return nil }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid(name, "a non-empty string") }
        return text
    }

    func bool(_ name: String) throws -> Bool? {
        guard let value = value(name) else { return nil }
        guard case .bool(let flag) = value else { throw invalid(name, "true or false") }
        return flag
    }

    static let maxMilliseconds: Double = 86_400_000

    func double(_ name: String) throws -> Double? {
        guard let value = value(name) else { return nil }
        // Bounded (a day, for the one use: a response time in ms): a huge value rounds to infinity, which no JSON reply can hold.
        guard case .number(let number) = value, number.isFinite, number >= 0, number <= Self.maxMilliseconds else { throw invalid(name, "a number from 0 to 86400000") }
        return number
    }

    func int(_ name: String) throws -> Int? {
        guard let value = value(name) else { return nil }
        guard case .number(let number) = value, number.rounded() == number, number >= 0, number <= 10_000_000 else { throw invalid(name, "a whole number of 0 or more") }
        // The schemas' maximums; offset's is the 10,000,000 above.
        let limits: [String: Int] = ["limit": 500, "maxBodyBytes": 900_000, "status": 999, "sortOrder": 1_000_000]
        if let limit = limits[name], number > Double(limit) { throw invalid(name, "at most \(limit)") }
        if name == "limit", number < 1 { throw invalid(name, "at least 1") }
        return Int(number)
    }

    func uuid(_ name: String) throws -> UUID? {
        guard let text = try string(name) else { return nil }
        guard let id = UUID(uuidString: text) else { throw invalid(name, "a UUID") }
        return id
    }

    func date(_ name: String) throws -> Date? {
        guard let text = try string(name) else { return nil }
        guard let date = try? Date(text, strategy: .iso8601) else { throw invalid(name, "an ISO 8601 date, such as 2026-11-27T10:00:00Z") }
        return date
    }

    func method() throws -> HTTPMethod? {
        guard let text = try string("method") else { return nil }
        guard let method = HTTPMethod(rawValue: text.uppercased()) else { throw invalid("method", "one of \(MCPTools.methods.joined(separator: ", "))") }
        return method
    }

    func bodyType() throws -> ContentType? {
        guard let text = try string("bodyType") else { return nil }
        guard let type = MCPBodyType(rawValue: text) else { throw invalid("bodyType", "one of \(MCPTools.bodyTypes.joined(separator: ", "))") }
        return type.contentType
    }

    func authType() throws -> AuthenticationType? {
        guard let text = try string("type") else { return nil }
        guard let type = MCPAuthType(rawValue: text) else { throw invalid("type", "one of \(MCPTools.authTypes.joined(separator: ", "))") }
        return type.authenticationType
    }

    func environmentColor() throws -> EnvironmentColor? {
        guard let text = try string("color") else { return nil }
        guard let color = EnvironmentColor(rawValue: text) else { throw invalid("color", "one of \(MCPTools.environmentColors.joined(separator: ", "))") }
        return color
    }

    /// A variable as an agent passed it; `value` and `isSecret` are nil when not given.
    struct VariableInput {
        let key: String
        let value: String?
        let isEnabled: Bool
        let isSecret: Bool?
    }

    func variables() throws -> [VariableInput]? {
        guard let value = value("variables") else { return nil }
        guard case .array(let items) = value else { throw invalid("variables", "an array of {key, value, enabled, secret}") }
        var seen: Set<String> = []
        return try items.enumerated().map { index, item in
            let field = "\(path)variables[\(index)]"
            guard case .object(let object) = item else { throw invalid("variables[\(index)]", "an object") }
            let variable = try Arguments(object, allowed: ["key", "value", "enabled", "secret"], path: "\(field).")
            guard let key = try variable.string("key")?.trimmingCharacters(in: .whitespaces), !key.isEmpty else {
                throw MCPToolError.invalidParams("\(field).key must be a non-empty string.", field: "\(field).key")
            }
            guard seen.insert(key).inserted else { throw MCPToolError.invalidParams("\(key) is in variables twice.", field: "\(field).key") }
            return VariableInput(key: key, value: try variable.string("value"), isEnabled: try variable.bool("enabled") ?? true, isSecret: try variable.bool("secret"))
        }
    }

    /// A nested object, checked against the names its schema allows (`allowed` when a tool narrows them).
    func object(_ name: String, allowed: Set<String>? = nil) throws -> Arguments? {
        guard let value = value(name) else { return nil }
        guard case .object(let object) = value else { throw invalid(name, "an object") }
        let nested = try Arguments(object, allowed: allowed ?? Self.nestedNames[name] ?? [], path: "\(path)\(name).")
        for field in Self.nestedRequired[name] ?? [] where nested.value(field) == nil {
            throw MCPToolError.invalidParams("\(nested.path)\(field) is required.", field: nested.path + field)
        }
        return nested
    }

    func pairs(_ name: String) throws -> [KeyValuePair]? {
        guard let value = value(name) else { return nil }
        guard case .array(let items) = value else { throw invalid(name, "an array of {key, value, enabled}") }
        return try items.enumerated().map { index, item in
            guard case .object(let object) = item else { throw invalid("\(name)[\(index)]", "an object") }
            let pair = try Arguments(object, allowed: ["key", "value", "enabled"], path: "\(path)\(name)[\(index)].")
            guard let key = try pair.string("key") else { throw MCPToolError.invalidParams("\(path)\(name)[\(index)].key is required.", field: "\(path)\(name)[\(index)].key") }
            return KeyValuePair(key: key, value: try pair.string("value") ?? "", isEnabled: try pair.bool("enabled") ?? true)
        }
    }

    private static let nestedNames: [String: Set<String>] = [
        "auth": ["type", "token", "username", "password", "oauth2"],
        "oauth2": ["authorizationURL", "tokenURL", "clientID", "clientSecret", "scope", "redirectURI"],
        "request": Set(MCPTools.requestFields.keys),
        "response": ["status", "headers", "body", "contentType", "timeMs"]
    ]

    /// The nested schemas' `required` lists.
    private static let nestedRequired: [String: [String]] = ["response": ["status"]]
}
