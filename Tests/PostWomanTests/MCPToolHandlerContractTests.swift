import SwiftData
import XCTest

@testable import PostWoman

/// The IDs each `.remoteAgentWillDelete` carried, and whether every one still existed when it was posted.
private final class DeletionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(ids: Set<UUID>, allStillStored: Bool)] = []
    func add(_ ids: Set<UUID>, _ stored: Bool) { lock.withLock { entries.append((ids, stored)) } }
    var all: [(ids: Set<UUID>, allStillStored: Bool)] { lock.withLock { entries } }
}

/// A target server that echoes what it received: method, path, headers and body.
private func echoServer(status: Int = 200, extraHeaders: [(String, String)] = [], body: String? = nil) throws -> (MCPListener, UInt16) {
    let listener = MCPListener { request in
        if let body { return MCPHTTPResponse(status: status, headers: [("Content-Type", "text/plain")] + extraHeaders, body: Data(body.utf8)) }
        let echoed = JSONValue.object([
            "method": .string(request.method), "path": .string(request.path), "headers": .object(request.headers.mapValues(JSONValue.string)),
            "body": .string(String(decoding: request.body, as: UTF8.self))
        ])
        return .json(status, echoed.data, headers: extraHeaders)
    }
    return (listener, try listener.start(address: "127.0.0.1", port: 0))
}

private func text(_ value: JSONValue?) -> String? {
    if case .string(let text)? = value { return text }
    return nil
}

private func list(_ value: JSONValue?) -> [JSONValue] {
    if case .array(let items)? = value { return items }
    return []
}

private func uuid(_ value: JSONValue?) -> UUID? { text(value).flatMap(UUID.init(uuidString:)) }

@MainActor
final class MCPToolHandlerContractTests: XCTestCase {
    private var container: ModelContainer!
    private var handler: MCPToolHandler!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        handler = MCPToolHandler(container: container)
    }

    override func tearDown() async throws {
        handler = nil
        container = nil
    }

    @discardableResult
    private func call(_ name: String, _ arguments: [String: JSONValue] = [:], file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
        switch await handler.call(name, arguments) {
        case .success(let value): return value
        case .failure(let error):
            XCTFail("\(name) failed: \(error.code) \(error.message)", file: file, line: line)
            throw error
        }
    }

    private func failure(_ name: String, _ arguments: [String: JSONValue] = [:]) async -> MCPToolError? {
        if case .failure(let error) = await handler.call(name, arguments) { return error }
        return nil
    }

    private func id(_ value: JSONValue) -> JSONValue { value["id"] ?? .null }

    /// A collection with one request, its Default environment and one History entry.
    private struct Fixture {
        let collection: JSONValue, request: JSONValue, environment: JSONValue, history: JSONValue
    }

    private func fixture() async throws -> Fixture {
        let collection = try await call("collection_create", ["name": .string("Users API")])
        let request = try await call(
            "request_create",
            [
                "collectionId": id(collection), "name": .string("List"), "url": .string("https://api.example.com/users"),
                "headers": .array([.object(["key": .string("Accept"), "value": .string("application/json")])])
            ])
        let environments = try await call("environment_list", ["collectionId": id(collection)])
        let environment = try XCTUnwrap(list(environments["environments"]).first)
        let history = try await call("history_create", ["url": .string("https://api.example.com/users"), "requestId": id(request)])
        return Fixture(collection: collection, request: request, environment: environment, history: history)
    }

    /// Everything an agent can read, to check a failed call changed nothing.
    private func everything() async throws -> JSONValue {
        var collections: [JSONValue] = []
        for collection in list(try await call("collection_list")["collections"]) {
            let full = try await call("collection_get", ["id": id(collection)])
            let environments = try await call("environment_list", ["collectionId": id(collection)])
            collections.append(.object(["collection": full, "environments": environments]))
        }
        var history: [JSONValue] = []
        for entry in list(try await call("history_list", ["limit": .number(500)])["entries"]) { history.append(try await call("history_get", ["id": id(entry)])) }
        return .object(["collections": .array(collections), "history": .array(history)])
    }

    private func observeDeletions() -> (DeletionLog, NSObjectProtocol) {
        let log = DeletionLog()
        let container = container!
        let observer = NotificationCenter.default.addObserver(forName: .remoteAgentWillDelete, object: nil, queue: nil) { note in
            let ids = note.userInfo?["ids"] as? Set<UUID> ?? []
            MainActor.assumeIsolated {
                let context = container.mainContext
                var stored = Set<UUID>()
                stored.formUnion(((try? context.fetch(FetchDescriptor<Folder>())) ?? []).map(\.id))
                stored.formUnion(((try? context.fetch(FetchDescriptor<APIRequest>())) ?? []).map(\.id))
                stored.formUnion(((try? context.fetch(FetchDescriptor<RequestHistory>())) ?? []).map(\.id))
                stored.formUnion(((try? context.fetch(FetchDescriptor<CollectionEnvironment>())) ?? []).map(\.id))
                log.add(ids, ids.isSubset(of: stored))
            }
        }
        return (log, observer)
    }

    // MARK: - Invalid params

    func testAnUnknownToolIsInvalidParams() async {
        let error = await failure("collection_drop")
        XCTAssertEqual(error?.code, "INVALID_PARAMS")
    }

    func testMissingOrNullRequiredArgumentsNameTheField() async {
        for tool in MCPTools.all where !tool.required.isEmpty {
            let missing = await failure(tool.name)
            XCTAssertEqual(missing?.code, "INVALID_PARAMS", tool.name)
            XCTAssertEqual(missing?.details?["field"], .string(tool.required[0]), tool.name)
            let null = await failure(tool.name, Dictionary(uniqueKeysWithValues: tool.required.map { ($0, JSONValue.null) }))
            XCTAssertEqual(null?.code, "INVALID_PARAMS", tool.name)
        }
    }

    func testIDsMustBeUUIDStrings() async {
        for tool in MCPTools.all {
            for name in ["id", "collectionId", "requestId"] where tool.properties[name] != nil {
                // request_update looks its request up (NOT_FOUND) before it reads collectionId.
                if tool.name == "request_update", name == "collectionId" { continue }
                var arguments: [String: JSONValue] = [:]
                for required in tool.required { arguments[required] = .string(UUID().uuidString) }
                if tool.name == "environment_create" { arguments["name"] = .string("Staging") }
                if tool.name == "history_create" { arguments["url"] = .string("https://x") }
                if tool.name == "request_execute", name == "collectionId" { arguments["request"] = .object(["url": .string("http://127.0.0.1:1/")]) }
                for bad: JSONValue in [.number(1), .string("not-a-uuid"), .bool(true), .array([]), .string("")] {
                    arguments[name] = bad
                    let error = await failure(tool.name, arguments)
                    XCTAssertEqual(error?.code, "INVALID_PARAMS", "\(tool.name).\(name) = \(bad)")
                    XCTAssertEqual(error?.details?["field"], .string(name), "\(tool.name).\(name)")
                }
            }
        }
    }

    func testUnknownIDsAreNotFound() async throws {
        let missing = UUID()
        let cases: [(String, [String: JSONValue])] = [
            ("collection_get", ["id": .string(missing.uuidString)]), ("collection_update", ["id": .string(missing.uuidString), "name": .string("x")]),
            ("collection_delete", ["id": .string(missing.uuidString)]), ("request_list", ["collectionId": .string(missing.uuidString)]),
            ("request_get", ["id": .string(missing.uuidString)]), ("request_create", ["collectionId": .string(missing.uuidString)]),
            ("request_update", ["id": .string(missing.uuidString)]), ("request_delete", ["id": .string(missing.uuidString)]),
            ("request_execute", ["id": .string(missing.uuidString)]),
            ("request_execute", ["request": .object(["url": .string("http://127.0.0.1:1/")]), "collectionId": .string(missing.uuidString)]),
            ("environment_list", ["collectionId": .string(missing.uuidString)]), ("environment_get", ["id": .string(missing.uuidString)]),
            ("environment_create", ["collectionId": .string(missing.uuidString), "name": .string("x")]),
            ("environment_update", ["id": .string(missing.uuidString)]), ("environment_delete", ["id": .string(missing.uuidString)]),
            ("environment_select", ["collectionId": .string(missing.uuidString)]), ("history_get", ["id": .string(missing.uuidString)]),
            ("history_update", ["id": .string(missing.uuidString)]), ("history_delete", ["id": .string(missing.uuidString)])
        ]
        for (tool, arguments) in cases {
            let error = await failure(tool, arguments)
            XCTAssertEqual(error?.code, "NOT_FOUND", tool)
            XCTAssertEqual(error?.details?["id"], .string(missing.uuidString), tool)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RequestHistory>()), 0, "Nothing was sent or recorded")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Folder>()), 0)
    }

    func testUnknownIDsInFiltersMatchNothing() async throws {
        let fixture = try await fixture()
        let filtered = try await call("history_list", ["requestId": .string(UUID().uuidString)])
        XCTAssertEqual(filtered["total"], .number(0))
        XCTAssertEqual(filtered["entries"], .array([]))
        let cleared = try await call("history_clear", ["requestId": .string(UUID().uuidString)])
        XCTAssertEqual(cleared["deleted"], .number(0))
        let kept = try await call("history_get", ["id": id(fixture.history)])
        XCTAssertEqual(kept["id"], id(fixture.history))
    }

    func testWrongTypesAreRefusedWithTheFieldAndChangeNothing() async throws {
        let fixture = try await fixture()
        let collection = id(fixture.collection), request = id(fixture.request), environment = id(fixture.environment), history = id(fixture.history)
        func pairs(_ items: JSONValue...) -> JSONValue { .array(items) }
        let cases: [(String, [String: JSONValue], String)] = [
            ("collection_create", ["name": .number(1)], "name"), ("collection_create", ["name": .string("  \n")], "name"),
            ("collection_create", ["name": .string("A"), "sortOrder": .number(-1)], "sortOrder"),
            ("collection_create", ["name": .string("A"), "sortOrder": .number(1.5)], "sortOrder"),
            ("collection_create", ["name": .string("A"), "sortOrder": .string("1")], "sortOrder"),
            ("collection_create", ["name": .string("A"), "sortOrder": .number(20_000_000)], "sortOrder"),
            ("collection_get", ["id": collection, "includeRequests": .string("yes")], "includeRequests"),
            ("collection_update", ["id": collection, "name": .string("")], "name"),
            ("request_create", ["collectionId": collection, "headers": .string("Accept: */*")], "headers"),
            ("request_create", ["collectionId": collection, "headers": pairs(.string("Accept"))], "headers[0]"),
            ("request_create", ["collectionId": collection, "headers": pairs(.object(["value": .string("x")]))], "headers[0].key"),
            ("request_create", ["collectionId": collection, "headers": pairs(.object(["key": .string("a"), "extra": .number(1)]))], "headers[0].extra"),
            ("request_create", ["collectionId": collection, "queryParams": pairs(.object(["key": .string("a"), "enabled": .string("no")]))], "queryParams[0].enabled"),
            ("request_create", ["collectionId": collection, "method": .string("TRACE")], "method"),
            ("request_create", ["collectionId": collection, "bodyType": .string("yaml")], "bodyType"),
            ("request_create", ["collectionId": collection, "body": .object([:])], "body"),
            ("request_create", ["collectionId": collection, "auth": .string("Bearer x")], "auth"),
            ("request_create", ["collectionId": collection, "auth": .object(["type": .string("digest")])], "auth.type"),
            ("request_create", ["collectionId": collection, "auth": .object(["bogus": .number(1)])], "auth.bogus"),
            ("request_create", ["collectionId": collection, "auth": .object(["token": .number(5)])], "auth.token"),
            ("request_create", ["collectionId": collection, "auth": .object(["oauth2": .object(["bogus": .string("")])])], "auth.oauth2.bogus"),
            ("request_update", ["id": request, "name": .string(" ")], "name"),
            ("request_execute", ["id": request, "recordHistory": .string("no")], "recordHistory"),
            ("request_execute", ["id": request, "maxBodyBytes": .number(900_001)], "maxBodyBytes"),
            ("request_execute", ["request": .string("https://x")], "request"),
            ("request_execute", ["request": .object(["url": .string("https://x"), "bogus": .bool(true)])], "request.bogus"),
            ("request_execute", ["request": .object(["url": .string("https://x")]), "environmentId": .number(1)], "environmentId"),
            ("environment_create", ["collectionId": collection, "name": .string("S"), "color": .string("purple")], "color"),
            ("environment_create", ["collectionId": collection, "name": .string("S"), "variables": .string("a=1")], "variables"),
            ("environment_create", ["collectionId": collection, "name": .string("S"), "variables": pairs(.string("a"))], "variables[0]"),
            ("environment_create", ["collectionId": collection, "name": .string("S"), "variables": pairs(.object(["key": .string(" ")]))], "variables[0].key"),
            (
                "environment_create",
                ["collectionId": collection, "name": .string("S"), "variables": pairs(.object(["key": .string("a")]), .object(["key": .string(" a ")]))],
                "variables[1].key"
            ),
            ("environment_create", ["collectionId": collection, "name": .string("S"), "variables": pairs(.object(["key": .string("a"), "secret": .string("y")]))], "variables[0].secret"),
            ("environment_create", ["collectionId": collection, "name": .string("S"), "variables": pairs(.object(["key": .string("a"), "x": .null]))], "variables[0].x"),
            ("environment_update", ["id": environment, "color": .number(1)], "color"),
            ("environment_select", ["collectionId": collection, "environmentId": .string("staging")], "environmentId"),
            ("history_list", ["limit": .number(0)], "limit"), ("history_list", ["limit": .number(501)], "limit"), ("history_list", ["limit": .number(2.5)], "limit"),
            ("history_list", ["offset": .number(-1)], "offset"), ("history_get", ["id": history, "maxBodyBytes": .number(900_001)], "maxBodyBytes"),
            ("history_create", ["url": .string("")], "url"), ("history_create", ["url": .string("https://x"), "timestamp": .string("yesterday")], "timestamp"),
            ("history_create", ["url": .string("https://x"), "response": .object(["status": .number(1000)])], "response.status"),
            ("history_create", ["url": .string("https://x"), "response": .object(["status": .number(200), "timeMs": .number(-1)])], "response.timeMs"),
            ("history_create", ["url": .string("https://x"), "response": .object(["status": .number(200), "cookies": .array([])])], "response.cookies"),
            ("history_update", ["id": history, "errorMessage": .bool(true)], "errorMessage"),
            ("history_update", ["id": history, "response": .array([])], "response")
        ]
        let before = try await everything()
        for (tool, arguments, field) in cases {
            let error = await failure(tool, arguments)
            XCTAssertEqual(error?.code, "INVALID_PARAMS", "\(tool) \(field)")
            XCTAssertEqual(error?.details?["field"], .string(field), "\(tool) \(field)")
            XCTAssertFalse(error?.message.isEmpty ?? true)
        }
        let after = try await everything()
        XCTAssertEqual(after, before, "A refused call leaves the store as it was")
    }

    func testSortOrderIsAcceptedUpToTheSchemaMaximumAndNoFurther() async throws {
        for tool in ["collection_create", "collection_update"] {
            let schema = try XCTUnwrap(MCPTools.byName[tool]?.properties["sortOrder"])
            XCTAssertEqual(schema["maximum"], .number(1_000_000), tool)
        }
        let atLimit = try await call("collection_create", ["name": .string("Last"), "sortOrder": .number(1_000_000)])
        XCTAssertEqual(atLimit["sortOrder"], .number(1_000_000))
        let before = try await everything()
        let created = await failure("collection_create", ["name": .string("Over"), "sortOrder": .number(1_000_001)])
        XCTAssertEqual(created?.code, "INVALID_PARAMS")
        XCTAssertEqual(created?.details?["field"], .string("sortOrder"))
        let updated = await failure("collection_update", ["id": id(atLimit), "sortOrder": .number(10_000_000)])
        XCTAssertEqual(updated?.code, "INVALID_PARAMS")
        XCTAssertEqual(updated?.details?["field"], .string("sortOrder"))
        let after = try await everything()
        XCTAssertEqual(after, before, "A refused sortOrder changes nothing")
    }

    // MARK: - Rollback

    func testAFailedUpdateRollsBackFieldsItHadAlreadyChanged() async throws {
        let fixture = try await fixture()
        let other = try await call("collection_create", ["name": .string("Other")])
        let before = try await everything()
        // url, name and the move apply before the bad bodyType is reached.
        let error = await failure(
            "request_update", ["id": id(fixture.request), "collectionId": id(other), "url": .string("https://changed"), "name": .string("Changed"), "bodyType": .string("yaml")])
        XCTAssertEqual(error?.code, "INVALID_PARAMS")
        let after = try await everything()
        XCTAssertEqual(after, before)
        let request = try await call("request_get", ["id": id(fixture.request)])
        XCTAssertEqual(request["url"], .string("https://api.example.com/users"))
        XCTAssertEqual(request["collectionId"], id(fixture.collection))

        let renamed = await failure("collection_update", ["id": id(fixture.collection), "name": .string("Renamed"), "sortOrder": .number(-5)])
        XCTAssertEqual(renamed?.code, "INVALID_PARAMS")
        let collectionRead = try await call("collection_get", ["id": id(fixture.collection), "includeRequests": .bool(false)])
        XCTAssertEqual(collectionRead["name"], .string("Users API"))

        let environment = await failure(
            "environment_update",
            ["id": id(fixture.environment), "name": .string("Renamed"), "variables": .array([.object(["key": .string("a")]), .object(["key": .string("a")])])])
        XCTAssertEqual(environment?.code, "INVALID_PARAMS")
        let environmentRead = try await call("environment_get", ["id": id(fixture.environment)])
        XCTAssertEqual(environmentRead["name"], .string("Default"))

        let history = await failure("history_update", ["id": id(fixture.history), "name": .string("Renamed"), "response": .object(["status": .number(5000)])])
        XCTAssertEqual(history?.code, "INVALID_PARAMS")
        let entry = try await call("history_get", ["id": id(fixture.history)])
        XCTAssertEqual(entry["request"]?["name"], .null, "The fixture's entry has no name; the refused rename did not stick")
        XCTAssertNil(entry["response"])
    }

    func testAFailedCreateLeavesNoPartialModels() async throws {
        // request_create with no collection would make a "Default Collection" first.
        let request = await failure("request_create", ["name": .string("x"), "method": .string("TRACE")])
        XCTAssertEqual(request?.code, "INVALID_PARAMS")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Folder>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CollectionEnvironment>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<APIRequest>()), 0)

        let collection = try await call("collection_create", ["name": .string("C")])
        // The environment is added before select is read.
        let environment = await failure("environment_create", ["collectionId": id(collection), "name": .string("Staging"), "select": .string("yes")])
        XCTAssertEqual(environment?.code, "INVALID_PARAMS")
        let environments = try await call("environment_list", ["collectionId": id(collection)])
        XCTAssertEqual(list(environments["environments"]).count, 1)

        let history = await failure("history_create", ["url": .string("https://x"), "response": .object(["status": .number(200)]), "errorMessage": .number(1)])
        XCTAssertEqual(history?.code, "INVALID_PARAMS")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RequestHistory>()), 0)
    }

    // MARK: - Deletion notices

    func testEveryDeleteAnnouncesItsModelsBeforeTheyGo() async throws {
        let fixture = try await fixture()
        let staging = try await call("environment_create", ["collectionId": id(fixture.collection), "name": .string("Staging")])
        let second = try await call("request_create", ["collectionId": id(fixture.collection), "url": .string("https://x")])
        let otherEntry = try await call("history_create", ["url": .string("https://y"), "requestId": id(second)])
        let loose = try await call("history_create", ["url": .string("https://z")])
        let (log, observer) = observeDeletions()
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = try await call("environment_delete", ["id": id(staging)])
        _ = try await call("history_delete", ["id": id(loose)])
        _ = try await call("history_clear", ["requestId": id(fixture.request)])
        _ = try await call("request_delete", ["id": id(second)])
        _ = try await call("collection_delete", ["id": id(fixture.collection)])

        let expected: [Set<UUID>] = [
            [uuid(staging["id"])!], [uuid(loose["id"])!], [uuid(fixture.history["id"])!], [uuid(second["id"])!],
            [uuid(fixture.collection["id"])!, uuid(fixture.request["id"])!, uuid(fixture.environment["id"])!]
        ]
        XCTAssertEqual(log.all.map { $0.ids }, expected)
        XCTAssertTrue(log.all.allSatisfy { $0.allStillStored }, "Each notice comes while its models still exist")
        // history_clear with a requestId kept the other request's entry; deleting requests keeps their History.
        let otherRead = try await call("history_get", ["id": id(otherEntry)])
        XCTAssertEqual(otherRead["requestId"], id(second))
    }

    func testClearingAllHistoryAnnouncesEveryEntry() async throws {
        for index in 0..<3 { _ = try await call("history_create", ["url": .string("https://x/\(index)")]) }
        let (log, observer) = observeDeletions()
        defer { NotificationCenter.default.removeObserver(observer) }
        let cleared = try await call("history_clear")
        XCTAssertEqual(cleared["deleted"], .number(3))
        XCTAssertEqual(log.all.map { $0.ids.count }, [3])
        XCTAssertTrue(log.all[0].allStillStored)
    }

    func testAFailedDeleteAnnouncesNothing() async throws {
        let fixture = try await fixture()
        let (log, observer) = observeDeletions()
        defer { NotificationCenter.default.removeObserver(observer) }
        let refused = await failure("environment_delete", ["id": id(fixture.environment)])
        XCTAssertEqual(refused?.code, "NOT_ALLOWED")
        _ = await failure("request_delete", ["id": .string(UUID().uuidString)])
        XCTAssertTrue(log.all.isEmpty)
    }

    // MARK: - Credentials and secrets

    func testSavedCredentialsAreNeverReturnedByAnyRead() async throws {
        let secrets = ["tok-SECRET-1", "pw-SECRET-2", "cs-SECRET-3"]
        let collection = try await call("collection_create", ["name": .string("C")])
        let created = try await call(
            "request_create",
            [
                "collectionId": id(collection), "url": .string("https://x"),
                "auth": .object([
                    "type": .string("basic"), "token": .string(secrets[0]), "username": .string("ada"), "password": .string(secrets[1]),
                    "oauth2": .object(["clientID": .string("client"), "clientSecret": .string(secrets[2]), "tokenURL": .string("https://t")])
                ])
            ])
        let auth = created["auth"]
        XCTAssertEqual(auth?["tokenSet"], .bool(true))
        XCTAssertEqual(auth?["passwordSet"], .bool(true))
        XCTAssertEqual(auth?["username"], .string("ada"))
        XCTAssertEqual(auth?["oauth2"]?["clientSecretSet"], .bool(true))
        XCTAssertEqual(auth?["oauth2"]?["clientID"], .string("client"))

        let reads = [
            created, try await call("request_get", ["id": id(created)]), try await call("request_list"), try await call("collection_get", ["id": id(collection)]),
            try await call("request_update", ["id": id(created), "name": .string("Renamed")]), try await call("collection_list")
        ]
        for output in reads {
            for secret in secrets { XCTAssertFalse(output.text.contains(secret), "\(secret) in \(output.text)") }
        }
        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<APIRequest>()).first)
        XCTAssertEqual([stored.authBearerToken, stored.authBasicPassword, stored.authOAuthConfig?.clientSecret], secrets.map(Optional.some), "Writes still save them")
    }

    func testOmittedCredentialsKeepTheirValueAndEmptyOnesClearIt() async throws {
        let created = try await call("request_create", ["url": .string("https://x"), "auth": .object(["type": .string("bearer"), "token": .string("keep-me")])])
        let switched = try await call("request_update", ["id": id(created), "auth": .object(["type": .string("basic"), "username": .string("u")])])
        XCTAssertEqual(switched["auth"]?["type"], .string("basic"))
        XCTAssertEqual(switched["auth"]?["tokenSet"], .bool(true))
        let cleared = try await call("request_update", ["id": id(created), "auth": .object(["token": .string("")])])
        XCTAssertEqual(cleared["auth"]?["tokenSet"], .bool(false))
        XCTAssertEqual(cleared["auth"]?["type"], .string("basic"), "Fields not passed are kept")
    }

    func testHistoryCredentialsAreWriteOnly() async throws {
        let entry = try await call(
            "history_create", ["url": .string("https://x"), "auth": .object(["type": .string("bearer"), "token": .string("h-SECRET"), "password": .string("hp-SECRET")])])
        let updated = try await call("history_update", ["id": id(entry), "auth": .object(["username": .string("ada")])])
        for output in [entry, updated, try await call("history_get", ["id": id(entry)]), try await call("history_list")] {
            XCTAssertFalse(output.text.contains("SECRET"), output.text)
        }
        XCTAssertEqual(updated["request"]?["auth"]?["tokenSet"], .bool(true))
        XCTAssertEqual(updated["request"]?["auth"]?["passwordSet"], .bool(true))
        XCTAssertEqual(updated["request"]?["auth"]?["username"], .string("ada"))
    }

    func testSecretVariableValuesNeverLeaveThroughAnyTool() async throws {
        let (target, port) = try echoServer()
        defer { target.stop() }
        let secret = "sk-live-SECRET-0042"
        let collection = try await call("collection_create", ["name": .string("C")])
        let environments = try await call("environment_list", ["collectionId": id(collection)])
        let defaultID = id(try XCTUnwrap(list(environments["environments"]).first))
        let variables: JSONValue = .array([
            .object(["key": .string("base"), "value": .string("http://127.0.0.1:\(port)")]),
            .object(["key": .string("apiKey"), "value": .string(secret), "secret": .bool(true)]),
            // A plain variable that uses the secret: still redacted where it is recorded.
            .object(["key": .string("authHeader"), "value": .string("Bearer {{apiKey}}")])
        ])
        let updated = try await call("environment_update", ["id": defaultID, "variables": variables])
        let request = try await call(
            "request_create",
            [
                "collectionId": id(collection), "url": .string("{{base}}/data?key={{apiKey}}"), "method": .string("POST"),
                "headers": .array([.object(["key": .string("X-Api-Key"), "value": .string("{{apiKey}}")]), .object(["key": .string("X-Auth"), "value": .string("{{authHeader}}")])]),
                "queryParams": .array([.object(["key": .string("k"), "value": .string("{{apiKey}}")])]), "body": .string(#"{"key":"{{apiKey}}"}"#),
                "auth": .object(["type": .string("basic"), "username": .string("{{apiKey}}"), "password": .string("{{apiKey}}")])
            ])
        let executed = try await call("request_execute", ["id": id(request)])

        // The server got the real value.
        let echoed = try JSONDecoder().decode(JSONValue.self, from: Data(try XCTUnwrap(text(executed["response"]?["body"])).utf8))
        XCTAssertEqual(echoed["headers"]?["x-api-key"], .string(secret))
        XCTAssertEqual(echoed["headers"]?["x-auth"], .string("Bearer \(secret)"))
        XCTAssertEqual(echoed["body"], .string(#"{"key":"\#(secret)"}"#))

        // Everything else an agent can read keeps it as {{apiKey}}. (The response body is the server's echo, so it is left out.)
        var executedWithoutResponse = executed
        if case .object(var object) = executed {
            object.removeValue(forKey: "response")
            executedWithoutResponse = .object(object)
        }
        XCTAssertEqual(executed["resolvedUrl"], .string("http://127.0.0.1:\(port)/data?key={{apiKey}}"))
        let historyID = try XCTUnwrap(executed["historyId"])
        var outputs = [updated, executedWithoutResponse, try await call("history_list"), try await call("request_get", ["id": id(request)])]
        outputs.append(try await call("environment_get", ["id": defaultID]))
        outputs.append(try await call("environment_list", ["collectionId": id(collection)]))
        outputs.append(try await call("collection_get", ["id": id(collection)]))
        let historyRead = try await call("history_get", ["id": historyID])
        outputs.append(try XCTUnwrap(historyRead["request"]))
        for output in outputs { XCTAssertFalse(output.text.contains(secret), output.text) }

        let entry = try XCTUnwrap(context.fetch(FetchDescriptor<RequestHistory>()).first)
        let recorded =
            [entry.url, entry.requestBody ?? "", entry.authBasicUsername ?? "", entry.authBasicPassword ?? ""] + entry.requestHeaders.map(\.value)
            + (entry.queryParams ?? []).map(\.value)
        XCTAssertFalse(recorded.contains { $0.contains(secret) }, "\(recorded)")
        XCTAssertTrue(entry.requestHeaders.contains { $0.value == "{{authHeader}}" || $0.value == "Bearer {{apiKey}}" })
    }

    func testSecretValuesReadAsNullAndUnmarkingWithoutAValueClearsThem() async throws {
        let collection = try await call("collection_create", ["name": .string("C")])
        let created = try await call(
            "environment_create",
            [
                "collectionId": id(collection), "name": .string("Prod"),
                "variables": .array([
                    .object(["key": .string("token"), "value": .string("prod-SECRET"), "secret": .bool(true)]),
                    .object(["key": .string("empty"), "secret": .bool(true)]), .object(["key": .string("plain"), "value": .string("p")])
                ])
            ])
        let variables = list(created["variables"])
        XCTAssertEqual(variables.map { $0["value"] }, [.null, .null, .string("p")])
        XCTAssertEqual(variables.map { $0["valueSet"] }, [.bool(true), .bool(false), .bool(true)])
        XCTAssertFalse(created.text.contains("prod-SECRET"))

        // Turning secret off without a value must not reveal the saved one: it is cleared.
        let revealed = try await call("environment_update", ["id": id(created), "variables": .array([.object(["key": .string("token"), "secret": .bool(false)])])])
        XCTAssertEqual(list(revealed["variables"]).first?["value"], .string(""))
        XCTAssertFalse(revealed.text.contains("prod-SECRET"))

        // A new value for a secret replaces it; reads still say null.
        _ = try await call("environment_update", ["id": id(created), "variables": .array([.object(["key": .string("token"), "secret": .bool(true), "value": .string("v2")])])])
        let renewed = try await call("environment_update", ["id": id(created), "variables": .array([.object(["key": .string("token"), "value": .null])])])
        XCTAssertEqual(list(renewed["variables"]).first?["value"], .null)
        XCTAssertEqual(list(renewed["variables"]).first?["secret"], .bool(true), "A variable passed without secret keeps being secret")
        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<CollectionEnvironment>()).first { $0.name == "Prod" })
        XCTAssertEqual(stored.variables.map(\.key), ["token"], "variables replaces the whole list")
        XCTAssertEqual(stored.variables.first?.value, "v2")
    }

    // MARK: - Collections and requests

    func testCollectionsAreListedInSidebarOrder() async throws {
        let first = try await call("collection_create", ["name": .string("First")])
        let second = try await call("collection_create", ["name": .string("Second")])
        XCTAssertEqual(second["sortOrder"], .number(1), "New collections go at the end")
        _ = try await call("collection_create", ["name": .string("Top"), "sortOrder": .number(0)])
        _ = try await call("collection_update", ["id": id(first), "sortOrder": .number(5)])
        let names = list(try await call("collection_list")["collections"]).map { $0["name"] }
        XCTAssertEqual(names.first, .string("Top"))
        XCTAssertEqual(names.last, .string("First"))
        let collections = try await call("collection_list")
        let summary = try XCTUnwrap(list(collections["collections"]).first)
        XCTAssertEqual(list(summary["environments"]).map { $0["isDefault"] }, [.bool(true)], "Every collection has its Default environment")
    }

    func testRequestsGetDefaultsAndKeepTheirOrder() async throws {
        let collection = try await call("collection_create", ["name": .string("C")])
        let first = try await call("request_create", ["collectionId": id(collection)])
        XCTAssertEqual(first["name"], .string("New Request"))
        XCTAssertEqual(first["method"], .string("GET"))
        XCTAssertEqual(first["bodyType"], .string("none"))
        XCTAssertEqual(first["headers"], .array([]))
        XCTAssertEqual(first["auth"]?["type"], .string("none"))
        let second = try await call("request_create", ["collectionId": id(collection), "body": .string("hi"), "bodyType": .string("text"), "method": .string("put")])
        XCTAssertEqual(second["bodyType"], .string("text"), "An explicit bodyType wins over the JSON default")
        XCTAssertEqual(second["method"], .string("PUT"))
        let empty = try await call("request_create", ["collectionId": id(collection), "body": .string("")])
        XCTAssertEqual(empty["bodyType"], .string("none"), "An empty body does not switch the type")
        // New requests go after the existing ones.
        let orders = [first, second, empty].compactMap { if case .number(let order)? = $0["sortOrder"] { order } else { nil } }
        XCTAssertEqual(orders, orders.sorted())
        XCTAssertEqual(Set(orders).count, 3)
        let collectionRead = try await call("collection_get", ["id": id(collection)])
        let requests = list(collectionRead["requests"])
        XCTAssertEqual(requests.map { $0["id"] }, [id(first), id(second), id(empty)])
        let secondRead = try await call("request_get", ["id": id(second)])
        XCTAssertEqual(requests[1], secondRead)
    }

    func testNewRequestsAreNumberedFromZeroAndAMoveNeverTies() async throws {
        let collection = try await call("collection_create", ["name": .string("C")])
        let first = try await call("request_create", ["collectionId": id(collection)])
        let second = try await call("request_create", ["collectionId": id(collection)])
        XCTAssertEqual(first["sortOrder"], .number(0), "The first request in an empty collection is at 0, as a move into it would be")
        XCTAssertEqual(second["sortOrder"], .number(1))
        let other = try await call("collection_create", ["name": .string("Other")])
        let moving = try await call("request_create", ["collectionId": id(other)])
        let moved = try await call("request_update", ["id": id(moving), "collectionId": id(collection)])
        XCTAssertEqual(moved["sortOrder"], .number(2), "A moved request goes after the others, tying with none")
        let read = try await call("collection_get", ["id": id(collection)])
        XCTAssertEqual(list(read["requests"]).map { $0["id"] }, [id(first), id(second), id(moving)])
    }

    func testRequestUpdateReplacesListsAndMovesToTheEnd() async throws {
        let fixture = try await fixture()
        let other = try await call("collection_create", ["name": .string("Other")])
        _ = try await call("request_create", ["collectionId": id(other)])
        let updated = try await call(
            "request_update",
            [
                "id": id(fixture.request), "collectionId": id(other),
                "headers": .array([.object(["key": .string("X-A"), "enabled": .bool(false)]), .object(["key": .string("X-B"), "value": .string("b")])])
            ])
        XCTAssertEqual(
            updated["headers"],
            .array([
                .object(["key": .string("X-A"), "value": .string(""), "enabled": .bool(false)]), .object(["key": .string("X-B"), "value": .string("b"), "enabled": .bool(true)])
            ]))
        XCTAssertEqual(updated["sortOrder"], .number(1), "A moved request takes the target collection's request count as its sortOrder")
        let oldCollection = try await call("request_list", ["collectionId": id(fixture.collection)])
        XCTAssertEqual(list(oldCollection["requests"]).count, 0)
        let allRequests = try await call("request_list")
        XCTAssertEqual(list(allRequests["requests"]).count, 2)
        let same = try await call("request_update", ["id": id(fixture.request), "collectionId": id(other)])
        XCTAssertEqual(same["sortOrder"], .number(1), "Moving to its own collection changes nothing")
    }

    // MARK: - Environments

    func testEnvironmentSelection() async throws {
        let collection = try await call("collection_create", ["name": .string("C")])
        let staging = try await call("environment_create", ["collectionId": id(collection), "name": .string("Staging")])
        XCTAssertEqual(staging["inUse"], .bool(false))
        XCTAssertEqual(staging["color"], .string("green"))
        let prod = try await call("environment_create", ["collectionId": id(collection), "name": .string("Prod"), "color": .string("red")])
        let listed = try await call("environment_list", ["collectionId": id(collection)])
        XCTAssertEqual(list(listed["environments"]).map { $0["name"] }, [.string("Default"), .string("Staging"), .string("Prod")])
        XCTAssertEqual(listed["selectedEnvironmentId"], .null)

        let selected = try await call("environment_select", ["collectionId": id(collection), "environmentId": id(prod)])
        XCTAssertEqual(selected["selectedEnvironmentId"], id(prod))
        XCTAssertEqual(selected["environment"], .string("Prod"))
        let prodRead = try await call("environment_get", ["id": id(prod)])
        XCTAssertEqual(prodRead["inUse"], .bool(true))
        _ = try await call("environment_delete", ["id": id(staging)])
        let collectionRead = try await call("collection_get", ["id": id(collection), "includeRequests": .bool(false)])
        XCTAssertEqual(collectionRead["selectedEnvironmentId"], id(prod), "Deleting another environment keeps the choice")

        let defaultID = id(try XCTUnwrap(list(listed["environments"]).first))
        for choice: JSONValue? in [.string("DEFAULT"), defaultID, nil] {
            _ = try await call("environment_select", ["collectionId": id(collection), "environmentId": id(prod)])
            var arguments: [String: JSONValue] = ["collectionId": id(collection)]
            arguments["environmentId"] = choice
            let selection = try await call("environment_select", arguments)
            XCTAssertEqual(selection["selectedEnvironmentId"], .null, "\(String(describing: choice)) means Default only")
        }
    }

    func testEnvironmentsOfAnotherCollectionCannotBeChosen() async throws {
        let first = try await call("collection_create", ["name": .string("A")])
        let second = try await call("collection_create", ["name": .string("B")])
        let foreign = try await call("environment_create", ["collectionId": id(second), "name": .string("Foreign")])
        let select = await failure("environment_select", ["collectionId": id(first), "environmentId": id(foreign)])
        XCTAssertEqual(select?.code, "NOT_FOUND")
        let execute = await failure(
            "request_execute", ["request": .object(["url": .string("http://127.0.0.1:1/")]), "collectionId": id(first), "environmentId": id(foreign)])
        XCTAssertEqual(execute?.code, "NOT_FOUND")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RequestHistory>()), 0, "Nothing was sent")
    }

    // MARK: - History

    func testHistoryIsPagedNewestFirst() async throws {
        for (index, day) in ["2026-01-01", "2026-03-01", "2026-02-01"].enumerated() {
            _ = try await call("history_create", ["url": .string("https://x/\(index)"), "timestamp": .string("\(day)T10:00:00Z")])
        }
        let first = try await call("history_list", ["limit": .number(2)])
        XCTAssertEqual(list(first["entries"]).map { $0["url"] }, [.string("https://x/1"), .string("https://x/2")])
        XCTAssertEqual(first["nextOffset"], .number(2))
        XCTAssertEqual(first["total"], .number(3))
        let last = try await call("history_list", ["limit": .number(2), "offset": .number(2)])
        XCTAssertEqual(list(last["entries"]).map { $0["url"] }, [.string("https://x/0")])
        XCTAssertNil(last["nextOffset"])
        let beyond = try await call("history_list", ["offset": .number(50)])
        XCTAssertEqual(beyond["entries"], .array([]))
        XCTAssertNil(list(first["entries"]).first?["response"], "Lists carry no bodies")
    }

    func testHistoryRecordsOutcomes() async throws {
        let failed = try await call("history_create", ["url": .string("https://x"), "errorMessage": .string("Offline")])
        XCTAssertEqual(failed["wasSuccessful"], .bool(false))
        XCTAssertNil(failed["response"], "A failed request has no response")
        let serverError = try await call(
            "history_create",
            [
                "url": .string("https://x"),
                "response": .object([
                    "status": .number(500), "body": .string("oops"), "headers": .array([.object(["key": .string("Content-Type"), "value": .string("text/plain")])])
                ])
            ])
        XCTAssertEqual(serverError["wasSuccessful"], .bool(false))
        XCTAssertEqual(serverError["response"]?["status"], .number(500))
        XCTAssertEqual(serverError["response"]?["statusText"], .string("Internal Server Error"))
        XCTAssertEqual(serverError["response"]?["contentType"], .string("text/plain"))

        let cleared = try await call("history_update", ["id": id(failed), "errorMessage": .string(""), "response": .object(["status": .number(204)])])
        XCTAssertEqual(cleared["errorMessage"], .null)
        XCTAssertEqual(cleared["wasSuccessful"], .bool(true))
        XCTAssertEqual(cleared["response"]?["body"], .null)

        let empty = try await call("history_get", ["id": id(serverError), "maxBodyBytes": .number(0)])
        XCTAssertEqual(empty["response"]?["body"], .string(""))
        XCTAssertEqual(empty["response"]?["bodyTruncated"], .bool(true))
        let full = try await call("history_get", ["id": id(serverError)])
        XCTAssertEqual(full["response"]?["bodyTruncated"], .bool(false))

        let dated = try await call("history_create", ["url": .string("https://x"), "timestamp": .string("2026-11-27T10:00:00Z"), "method": .string("delete")])
        XCTAssertEqual(dated["timestamp"], .string("2026-11-27T10:00:00Z"))
        XCTAssertEqual(dated["request"]?["method"], .string("DELETE"))
    }

    func testARecordedResponseNeedsItsStatusAsTheSchemaSays() async throws {
        for tool in ["history_create", "history_update"] {
            let schema = try XCTUnwrap(MCPTools.byName[tool]?.properties["response"])
            XCTAssertEqual(schema["required"], .array([.string("status")]), tool)
        }
        let fixture = try await fixture()
        let before = try await everything()
        let created = await failure("history_create", ["url": .string("https://x"), "response": .object(["body": .string("ok")])])
        XCTAssertEqual(created?.code, "INVALID_PARAMS")
        XCTAssertEqual(created?.details?["field"], .string("response.status"))
        let nullStatus = await failure("history_create", ["url": .string("https://x"), "response": .object(["status": .null])])
        XCTAssertEqual(nullStatus?.details?["field"], .string("response.status"))
        let updated = await failure("history_update", ["id": id(fixture.history), "name": .string("Renamed"), "response": .object(["timeMs": .number(5)])])
        XCTAssertEqual(updated?.code, "INVALID_PARAMS")
        XCTAssertEqual(updated?.details?["field"], .string("response.status"))
        let after = try await everything()
        XCTAssertEqual(after, before, "No entry was added and the existing one kept its name and response")
    }

    // MARK: - request_execute

    func testExecuteSendsTheSavedFieldsAndRecordsWhatCameBack() async throws {
        let (target, port) = try echoServer(status: 404, extraHeaders: [("X-Zeta", "z"), ("X-Alpha", "a")])
        defer { target.stop() }
        let request = try await call(
            "request_create",
            [
                "url": .string("http://127.0.0.1:\(port)/items"), "method": .string("PUT"), "body": .string(#"{"a":1}"#),
                "headers": .array([.object(["key": .string("X-Sent"), "value": .string("yes")]), .object(["key": .string("X-Off"), "value": .string("no"), "enabled": .bool(false)])])
            ])
        let result = try await call("request_execute", ["id": id(request)])
        let response = try XCTUnwrap(result["response"])
        XCTAssertEqual(response["status"], .number(404))
        XCTAssertEqual(response["statusText"], .string("Not Found"))
        let echoed = try JSONDecoder().decode(JSONValue.self, from: Data(try XCTUnwrap(text(response["body"])).utf8))
        XCTAssertEqual(echoed["method"], .string("PUT"))
        XCTAssertEqual(echoed["path"], .string("/items"))
        XCTAssertEqual(echoed["body"], .string(#"{"a":1}"#))
        XCTAssertEqual(echoed["headers"]?["x-sent"], .string("yes"))
        XCTAssertNil(echoed["headers"]?["x-off"], "Disabled headers are not sent")
        let headerNames = list(response["headers"]).compactMap { text($0["key"])?.lowercased() }
        XCTAssertEqual(headerNames, headerNames.sorted(), "Response headers are sorted by name")
        XCTAssertEqual(result["environment"], .string("Default"))
        XCTAssertEqual(result["unresolvedVariables"], .array([]))

        let entry = try await call("history_get", ["id": try XCTUnwrap(result["historyId"])])
        XCTAssertEqual(entry["wasSuccessful"], .bool(false), "A 404 is recorded as unsuccessful")
        XCTAssertEqual(entry["requestId"], id(request))
        XCTAssertEqual(entry["response"]?["status"], .number(404))
    }

    func testExecuteCutsLongBodiesOnRequest() async throws {
        let (target, port) = try echoServer(body: String(repeating: "é", count: 100))
        defer { target.stop() }
        let result = try await call("request_execute", ["request": .object(["url": .string("http://127.0.0.1:\(port)/")]), "maxBodyBytes": .number(5), "recordHistory": .bool(false)])
        XCTAssertEqual(result["response"]?["body"], .string("éé"))
        XCTAssertEqual(result["response"]?["bodyTruncated"], .bool(true))
        XCTAssertEqual(result["response"]?["size"], .number(200))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RequestHistory>()), 0)
    }

    func testAdHocRequestsAreRecordedButNeverSaved() async throws {
        let (target, port) = try echoServer()
        defer { target.stop() }
        let url = "http://127.0.0.1:\(port)/adhoc"
        let result = try await call("request_execute", ["request": .object(["url": .string(url), "method": .string("DELETE")]), "environmentId": .string("default")])
        XCTAssertEqual(result["environment"], .null, "No collection, so no environment")
        let entry = try await call("history_get", ["id": try XCTUnwrap(result["historyId"])])
        XCTAssertEqual(entry["requestId"], .null)
        XCTAssertEqual(entry["request"]?["name"], .string(url))
        XCTAssertEqual(entry["request"]?["method"], .string("DELETE"))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<APIRequest>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Folder>()), 0)
    }

    func testExecuteRefusesAmbiguousOrIncompleteRequests() async throws {
        let fixture = try await fixture()
        let noURL = await failure("request_execute", ["request": .object(["name": .string("x")])])
        XCTAssertEqual(noURL?.code, "INVALID_PARAMS")
        XCTAssertEqual(noURL?.details?["field"], .string("url"))
        let neither = await failure("request_execute", ["recordHistory": .bool(true)])
        XCTAssertEqual(neither?.code, "INVALID_PARAMS")
        let savedWithCollection = await failure("request_execute", ["id": id(fixture.request), "collectionId": id(fixture.collection)])
        XCTAssertEqual(savedWithCollection?.details?["field"], .string("collectionId"))
        let emptySaved = try await call("request_create", ["collectionId": id(fixture.collection)])
        let noSavedURL = await failure("request_execute", ["id": id(emptySaved)])
        XCTAssertEqual(noSavedURL?.details?["field"], .string("url"))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RequestHistory>()), 1, "Only the fixture's entry: nothing was sent")
    }

    func testAFailedSendIsRecordedUnlessHistoryIsOff() async throws {
        let recorded = await failure("request_execute", ["request": .object(["url": .string("http://127.0.0.1:1/")])])
        XCTAssertEqual(recorded?.code, "REQUEST_FAILED")
        let historyID = try XCTUnwrap(recorded?.details?["historyId"])
        let entry = try await call("history_get", ["id": historyID])
        XCTAssertEqual(entry["wasSuccessful"], .bool(false))
        XCTAssertNotEqual(entry["errorMessage"], .null)

        let unrecorded = await failure("request_execute", ["request": .object(["url": .string("http://127.0.0.1:1/")]), "recordHistory": .bool(false)])
        XCTAssertEqual(unrecorded?.code, "REQUEST_FAILED")
        XCTAssertNil(unrecorded?.details)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RequestHistory>()), 1)
    }
}
