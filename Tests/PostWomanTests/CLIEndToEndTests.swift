import Foundation
import SwiftData
import XCTest

@testable import PostWoman
@testable import PostWomanCLI

// Both modules have a JSONValue, so this file always names the module.

/// The CLI's commands must stay in step with the app's MCP tools.
final class CLIContractTests: XCTestCase {
    func testEveryToolHasACommand() {
        let covered = Set(CLICommands.all.compactMap(\.tool))
        for tool in MCPTools.all { XCTAssertTrue(covered.contains(tool.name), "No CLI command calls \(tool.name)") }
        for name in covered { XCTAssertNotNil(MCPTools.byName[name], "\(name) is not an app tool") }
    }

    func testTheCLIAcceptsExactlyTheMethodsTheAppHas() {
        XCTAssertEqual(CLICommands.methods, MCPTools.methods)
    }

    /// Every flag, given a sample value, builds arguments the tool's schema accepts.
    func testEveryFlagBuildsArgumentsTheToolAccepts() throws {
        let input = CLIInput(readFile: { _ in Data("body".utf8) }, readStdin: { Data() })
        let samples: [String: String] = [
            "method": "GET", "body-type": "json", "auth": "bearer", "basic": "u:p", "header": "A: b", "response-header": "A: b", "query": "a=b",
            "time-ms": "1", "timestamp": "2026-11-27T10:00:00Z", "var": "baseUrl=https://example.com", "secret": "token=abc", "color": "green"
        ]
        for command in CLICommands.all {
            guard let toolName = command.tool, let tool = MCPTools.byName[toolName] else { continue }
            for nest in toolName == "request_execute" ? [false, true] : [false] {
                var arguments = ToolArguments()
                // request execute takes request fields only without --id (an ad-hoc request).
                let fieldNames = Set(CLICommands.requestFields.map(\.name))
                let skipFields = toolName == "request_execute" && !nest
                for flag in command.flags where flag.name != "body-file" && !(nest && flag.name == "id") && !(skipFields && fieldNames.contains(flag.name)) {
                    let value = flag.value == nil ? "" : samples[flag.name] ?? (flag.value == "N" ? "1" : "x")
                    try flag.apply(&arguments, value, input)
                }
                let built = try JSONDecoder().decode(PostWoman.JSONValue.self, from: JSONEncoder().encode(PostWomanCLI.JSONValue.object(arguments.merged(nestFields: nest))))
                try check(built, against: tool.inputSchema, path: command.name)
            }
        }
    }

    /// Object keys must be declared properties (the schemas are closed), recursively through objects and arrays.
    private func check(_ value: PostWoman.JSONValue, against schema: PostWoman.JSONValue, path: String) throws {
        switch value {
        case .object(let object):
            guard case .object(let properties)? = schema["properties"] else { return XCTFail("\(path) is an object, but the schema has no properties") }
            for (key, child) in object {
                guard let childSchema = properties[key] else {
                    XCTFail("\(path).\(key) is not in the tool's schema")
                    continue
                }
                try check(child, against: childSchema, path: "\(path).\(key)")
            }
        case .array(let items):
            for item in items { try check(item, against: schema["items"] ?? .null, path: "\(path)[]") }
        default: break
        }
    }
}

/// The real CLI, over HTTP, against the app's real MCP server and tools on an in-memory store.
@MainActor
final class CLIEndToEndTests: XCTestCase {
    private var server: MCPServer!
    private var target: MCPListener!
    private var container: ModelContainer!
    private var url = ""
    private var targetPort: UInt16 = 0
    private let token = RemoteAgentToken.generate()

    override func setUp() async throws {
        container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let handler = MCPToolHandler(container: container)
        server = MCPServer(serverVersion: "test") { name, arguments in await handler.call(name, arguments) }
        let probe = MCPListener { _ in .empty(204) }
        let port = try probe.start(address: "127.0.0.1", port: 0)
        probe.stop()
        guard case .running(let running) = server.apply(RemoteAgentSettings(mcpEnabled: true, port: port), token: token) else {
            throw XCTSkip("Couldn't start the MCP server")
        }
        url = running
        // The API the CLI's requests go to: it echoes what it got.
        target = MCPListener { request in
            let status = request.path == "/missing" ? 404 : 201
            let body = #"{"method":"\#(request.method)","path":"\#(request.path)","auth":"\#(request.header("authorization") ?? "")"}"#
            return MCPHTTPResponse.json(status, Data(body.utf8), headers: [("X-Echo", "yes")])
        }
        targetPort = try target.start(address: "127.0.0.1", port: 0)
    }

    override func tearDown() async throws {
        server.stop()
        target.stop()
    }

    private func run(_ words: [String], token: String? = nil) async -> (status: Int32, stdout: String, stderr: String) {
        let output = CLIOutputBox()
        var environment = CLIEnvironment.live
        environment.stdout = { output.write($0, error: false) }
        environment.stderr = { output.write($0, error: true) }
        environment.home = "/nonexistent"
        environment.variable = { _ in nil }
        let status = await CLI.run(words + ["--server", url, "--agent-token", token ?? self.token], environment: environment)
        return (status, output.stdout, output.stderr)
    }

    private func id(_ json: String) throws -> String {
        let value = try JSONDecoder().decode(PostWomanCLI.JSONValue.self, from: Data(json.utf8))
        return try XCTUnwrap(value["result"]?["id"]?.string)
    }

    func testManagesAndSendsRequests() async throws {
        let created = await run(["collection", "create", "--name", "From the CLI", "--json"])
        XCTAssertEqual(created.status, 0, created.stdout)
        let collection = try id(created.stdout)

        let request = await run([
            "request", "create", "--collection", collection, "--name", "Create user", "-X", "POST", "--url", "http://127.0.0.1:\(targetPort)/users", "-d", "{}",
            "--bearer", "s3cret", "--json"
        ])
        XCTAssertEqual(request.status, 0, request.stdout)
        XCTAssertFalse(request.stdout.contains("s3cret"))
        let requestID = try id(request.stdout)

        let listed = await run(["request", "list", "--collection", collection])
        XCTAssertTrue(listed.stdout.contains("POST"), listed.stdout)
        XCTAssertTrue(listed.stdout.contains("Create user"))

        let sent = await run(["request", "execute", "--id", requestID, "-i"])
        XCTAssertEqual(sent.status, 0, sent.stderr)
        XCTAssertTrue(sent.stdout.hasPrefix("HTTP 201 Created"), sent.stdout)
        XCTAssertTrue(sent.stdout.contains("X-Echo: yes"))
        XCTAssertTrue(sent.stdout.contains(#""auth":"Bearer s3cret""#))
        XCTAssertTrue(sent.stderr.contains("201 Created"), sent.stderr)

        let mixed = await run(["request", "execute", "--id", requestID, "--url", "http://x.test"])
        XCTAssertEqual(mixed.status, 2)

        let missing = await run(["request", "execute", "--url", "http://127.0.0.1:\(targetPort)/missing", "--fail", "--no-history"])
        XCTAssertEqual(missing.status, 22)

        let history = await run(["history", "list"])
        XCTAssertTrue(history.stdout.contains("201"), history.stdout)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<RequestHistory>()), 1)

        let updated = await run(["request", "update", "--id", requestID, "--name", "Renamed"])
        XCTAssertTrue(updated.stdout.contains(#""name" : "Renamed""#), updated.stdout)

        let notFound = await run(["request", "get", "--id", UUID().uuidString])
        XCTAssertEqual(notFound.status, 4)
        XCTAssertTrue(notFound.stderr.contains("NOT_FOUND"))

        let raw = await run(["call", "collection_list"])
        XCTAssertTrue(raw.stdout.contains("From the CLI"))
        let tools = await run(["tools"])
        XCTAssertTrue(tools.stdout.contains("request_execute"))

        let deleted = await run(["collection", "delete", "--id", collection])
        XCTAssertEqual(deleted.stdout, "Deleted collection \(collection) and its 1 request.")
        let cleared = await run(["history", "clear"])
        XCTAssertEqual(cleared.stdout, "Deleted 1 history entry.")
    }

    func testAWrongTokenIsRefused() async {
        let refused = await run(["collection", "list"], token: "pwm_wrong")
        XCTAssertEqual(refused.status, 3)
        XCTAssertTrue(refused.stderr.contains("AUTH_FAILED"), refused.stderr)
    }

    func testFailedRequestsReportTheirHistoryEntry() async {
        let failed = await run(["request", "execute", "--url", "http://127.0.0.1:1/nothing"])
        XCTAssertEqual(failed.status, 5)
        XCTAssertTrue(failed.stderr.contains("Recorded in History as"), failed.stderr)
    }
}
