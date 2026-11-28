import Foundation

/// A failure with the documented exit status (see `CLIHelp.exitStatuses`).
public struct CLIFailure: Error, Equatable, Sendable {
    public let code: String
    public let message: String
    public let exitStatus: Int32
    public var details: JSONValue?

    public init(code: String, message: String, exitStatus: Int32, details: JSONValue? = nil) {
        self.code = code; self.message = message; self.exitStatus = exitStatus; self.details = details
    }

    static func arguments(_ message: String) -> Self { Self(code: "INVALID_ARGUMENTS", message: message, exitStatus: 2) }
    static func transport(_ message: String) -> Self { Self(code: "TRANSPORT", message: message, exitStatus: 7) }
    static func notRunning(_ url: String) -> Self {
        Self(
            code: "APP_NOT_REACHABLE",
            message: "The Reqs MCP server isn't answering at \(url). Open Reqs and turn on Settings → Remote Agent, then press Apply.",
            exitStatus: 7)
    }
    static let noToken = Self(
        code: "AUTH_REQUIRED",
        message: "No agent token found. Turn on Settings → Remote Agent in Reqs, or pass --agent-token (or set REQS_TOKEN) with the token shown there.",
        exitStatus: 3)
    static let tokenRefused = Self(
        code: "AUTH_FAILED", message: "Reqs refused the agent token. Copy it again from Settings → Remote Agent (it changes when regenerated).", exitStatus: 3)
    static let rateLimited = Self(code: "RATE_LIMITED", message: "Too many failed sign-ins. Wait a minute and try again.", exitStatus: 6)

    /// A tool error from the app: its stable code picks the exit status.
    static func tool(_ error: JSONValue) -> Self {
        let code = error["code"]?.string ?? "INTERNAL_ERROR"
        let status: Int32 =
            switch code {
            case "INVALID_PARAMS": 2
            case "NOT_FOUND": 4
            case "REQUEST_FAILED": 5
            case "LIMIT_EXCEEDED": 6
            default: 1
            }
        return Self(code: code, message: error["message"]?.string ?? "The tool failed.", exitStatus: status, details: error["details"])
    }
}

/// Every side effect, injected so tests never touch the real app, files or terminal.
public struct CLIEnvironment: Sendable {
    public var send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    public var variable: @Sendable (String) -> String?
    public var readFile: @Sendable (String) throws -> Data
    public var readStdin: @Sendable () -> Data
    public var stdout: @Sendable (String) -> Void
    public var stderr: @Sendable (String) -> Void
    /// `$HOME` first, like other command-line tools.
    public var home: String
    /// The real executable, not argv[0], which is a bare name when run through PATH.
    public var executablePath: String
    public var links: CLILinks

    public init(
        send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse), variable: @escaping @Sendable (String) -> String?,
        readFile: @escaping @Sendable (String) throws -> Data, readStdin: @escaping @Sendable () -> Data, stdout: @escaping @Sendable (String) -> Void,
        stderr: @escaping @Sendable (String) -> Void, home: String, executablePath: String, links: CLILinks
    ) {
        self.send = send; self.variable = variable; self.readFile = readFile; self.readStdin = readStdin; self.stdout = stdout; self.stderr = stderr
        self.home = home; self.executablePath = executablePath; self.links = links
    }

    public static var live: CLIEnvironment {
        CLIEnvironment(
            send: { request in
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                return (data, http)
            },
            variable: { ProcessInfo.processInfo.environment[$0] },
            readFile: { try Data(contentsOf: URL(fileURLWithPath: $0)) },
            readStdin: { FileHandle.standardInput.readDataToEndOfFile() },
            stdout: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
            stderr: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
            home: ProcessInfo.processInfo.environment["HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? NSHomeDirectory(),
            executablePath: Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0],
            links: .live)
    }
}

/// Where a Reqs build keeps its agent token and Remote Agent settings.
struct AppLocation: Equatable, Sendable {
    let name: String
    let tokenPath: String
    /// The app's preferences plist; nil for unbundled runs.
    let preferencesPath: String?

    /// The installed app, then the dev bundle (`scripts/run-app.sh`), then `swift run`. Both bundles are sandboxed, so their
    /// files live in their containers.
    static func all(home: String) -> [Self] {
        func container(_ id: String) -> String { "\(home)/Library/Containers/\(id)/Data/Library" }
        return [
            Self(
                name: "Reqs", tokenPath: container("com.bearstouch.reqs") + "/Application Support/Reqs/remote-agent-token",
                preferencesPath: container("com.bearstouch.reqs") + "/Preferences/com.bearstouch.reqs.plist"),
            Self(
                name: "Reqs Dev", tokenPath: container("com.bearstouch.reqs.dev") + "/Application Support/Reqs/remote-agent-token",
                preferencesPath: container("com.bearstouch.reqs.dev") + "/Preferences/com.bearstouch.reqs.dev.plist"),
            Self(name: "Reqs (swift run)", tokenPath: home + "/Library/Application Support/Reqs Dev/remote-agent-token", preferencesPath: nil)
        ]
    }
}

/// One way to reach an app: its endpoint and the token to present.
struct Connection: Equatable, Sendable {
    let url: URL
    let token: String
}

/// A Streamable HTTP MCP client session: initialize, call tools, close.
final class MCPClient: Sendable {
    static let defaultURL = "http://127.0.0.1:7778/mcp"
    static let protocolVersion = "2025-06-18"

    let connection: Connection
    private let sessionID: String
    private let environment: CLIEnvironment

    private init(connection: Connection, sessionID: String, environment: CLIEnvironment) {
        self.connection = connection; self.sessionID = sessionID; self.environment = environment
    }

    /// Tries each candidate in order: one that isn't listening or refuses its token gives way to the next.
    static func connect(_ candidates: [Connection], version: String, environment: CLIEnvironment) async throws(CLIFailure) -> MCPClient {
        guard !candidates.isEmpty else { throw .noToken }
        var failure: CLIFailure?
        for candidate in candidates {
            do {
                return try await open(candidate, version: version, environment: environment)
            } catch {
                // Keep the most telling failure: a refused token over a server that isn't running.
                if failure == nil || error.exitStatus == 3 { failure = error }
                if error.code == CLIFailure.rateLimited.code { break }
            }
        }
        throw failure ?? .notRunning(candidates[0].url.absoluteString)
    }

    private static func open(_ connection: Connection, version: String, environment: CLIEnvironment) async throws(CLIFailure) -> MCPClient {
        let params: JSONValue = .object([
            "protocolVersion": .string(protocolVersion), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("reqs-cli"), "version": .string(version)])
        ])
        let (_, response) = try await post(connection, session: nil, method: "initialize", params: params, environment: environment)
        guard let session = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !session.isEmpty else {
            throw .transport("Reqs didn't open an MCP session at \(connection.url.absoluteString).")
        }
        let client = MCPClient(connection: connection, sessionID: session, environment: environment)
        _ = try? await post(connection, session: session, method: "notifications/initialized", params: nil, environment: environment, notification: true)
        return client
    }

    /// The tool's result, or its tool error as a failure with the error's exit status.
    func callTool(_ name: String, arguments: [String: JSONValue]) async throws(CLIFailure) -> JSONValue {
        let (result, _) = try await Self.post(
            connection, session: sessionID, method: "tools/call", params: .object(["name": .string(name), "arguments": .object(arguments)]), environment: environment)
        if result["isError"] == .bool(true) {
            throw .tool(result["structuredContent"]?["error"] ?? .object(["message": .string(Self.text(result) ?? "The tool failed.")]))
        }
        if let structured = result["structuredContent"] { return structured }
        // A result too large for both copies keeps only the JSON text.
        guard let text = Self.text(result), let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return .null }
        return value
    }

    func listTools() async throws(CLIFailure) -> [JSONValue] {
        let (result, _) = try await Self.post(connection, session: sessionID, method: "tools/list", params: nil, environment: environment)
        return result["tools"]?.array ?? []
    }

    /// Ends the session; best effort, since the CLI is about to exit.
    func close() async {
        var request = URLRequest(url: connection.url, timeoutInterval: 5)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        _ = try? await environment.send(request)
    }

    /// The last text item: an untrusted-data notice, if any, comes first.
    private static func text(_ result: JSONValue) -> String? { result["content"]?.array?.last?["text"]?.string }

    private static func post(
        _ connection: Connection, session: String?, method: String, params: JSONValue?, environment: CLIEnvironment, notification: Bool = false
    ) async throws(CLIFailure) -> (JSONValue, HTTPURLResponse) {
        var message: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if !notification { message["id"] = .number(1) }
        if let params { message["params"] = params }
        // request_execute waits for the remote server as long as the app's timeout setting allows (up to 600 s), so allow more.
        var request = URLRequest(url: connection.url, timeoutInterval: 660)
        request.httpMethod = "POST"
        request.httpBody = Data(JSONValue.object(message).compact.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await environment.send(request)
        } catch {
            throw .notRunning(connection.url.absoluteString)
        }
        switch response.statusCode {
        case 200: break
        case 202 where notification: return (.null, response)
        case 401: throw .tokenRefused
        case 404 where session != nil: throw .transport("Reqs ended the MCP session (it restarted or the token changed). Run the command again.")
        case 429: throw .rateLimited
        default:
            let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw .transport("Reqs answered HTTP \(response.statusCode)\(text.isEmpty ? "" : ": \(text)")")
        }
        guard let body = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw .transport("The answer from Reqs wasn't JSON.") }
        if let error = body["error"] {
            let code = error["code"]?.number.flatMap { Int(exactly: $0) } ?? 0
            throw CLIFailure(code: code == -32602 ? "INVALID_PARAMS" : "PROTOCOL", message: error["message"]?.string ?? "MCP error.", exitStatus: code == -32602 ? 2 : 1)
        }
        return (body["result"] ?? .null, response)
    }
}

/// Finding the endpoint and token: flags, then environment variables, then each app's own files.
enum ConnectionResolver {
    static func candidates(server: String?, token: String?, tokenFile: String?, environment: CLIEnvironment) throws(CLIFailure) -> [Connection] {
        // An empty REQS_URL (exported blank by an env file) is no choice, like an empty REQS_TOKEN; an empty --server is a mistake.
        let fromEnvironment = environment.variable("REQS_URL").flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let explicitURL = try (server ?? fromEnvironment).map { text throws(CLIFailure) in try url(text) }
        let fallback = try url(MCPClient.defaultURL)
        // Any flag beats any environment variable: --agent-token, --agent-token-file, REQS_TOKEN, REQS_TOKEN_FILE.
        func read(_ path: String) throws(CLIFailure) -> String {
            guard let data = try? environment.readFile(path) else { throw .arguments("Can't read the token file \(path).") }
            return String(decoding: data, as: UTF8.self)
        }
        var explicitToken = token
        if explicitToken == nil, let tokenFile { explicitToken = try read(tokenFile) }
        if explicitToken == nil { explicitToken = environment.variable("REQS_TOKEN") }
        if explicitToken == nil, let path = environment.variable("REQS_TOKEN_FILE") { explicitToken = try read(path) }
        explicitToken = explicitToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicitToken, !explicitToken.isEmpty {
            // A token alone: try it at each app's endpoint, so it reaches whichever app it belongs to.
            let urls = explicitURL.map { [$0] } ?? unique(AppLocation.all(home: environment.home).compactMap { appURL($0, environment) } + [fallback])
            return urls.map { Connection(url: $0, token: explicitToken) }
        }
        var result: [Connection] = []
        // An app whose server is on goes first, one that says it is off last: every refused token counts towards the server's
        // sign-in limit, so a leftover token from another build, tried first, would lock everyone out after a few commands.
        let apps = AppLocation.all(home: environment.home).map { ($0, serverIsOn($0, environment)) }
        for app in apps.filter({ $0.1 == true }) + apps.filter({ $0.1 == nil }) + apps.filter({ $0.1 == false }) {
            let app = app.0
            guard let data = try? environment.readFile(app.tokenPath) else { continue }
            let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            let connection = Connection(url: explicitURL ?? appURL(app, environment) ?? fallback, token: token)
            if !result.contains(connection) { result.append(connection) }
        }
        return result
    }

    /// The endpoint an app's saved Remote Agent settings point at (a wildcard bind as its loopback address).
    static func appURL(_ app: AppLocation, _ environment: CLIEnvironment) -> URL? {
        guard let settings = savedSettings(app, environment), let port = settings["port"]?.number.flatMap({ Int(exactly: $0) }), (0...65535).contains(port) else { return nil }
        var host = settings["bindAddress"]?.string ?? "127.0.0.1"
        if host == "0.0.0.0" { host = "127.0.0.1" }
        if host == "::" { host = "::1" }
        return URL(string: "http://\(host.contains(":") ? "[\(host)]" : host):\(port)/mcp")
    }

    /// Whether an app's saved settings turn its MCP server on. It is off until someone turns it on, so an app that has saved
    /// nothing counts as off; nil when the CLI can't tell (`swift run` keeps its settings elsewhere, or the file is unreadable).
    static func serverIsOn(_ app: AppLocation, _ environment: CLIEnvironment) -> Bool? {
        guard let path = app.preferencesPath else { return nil }
        guard let plist = try? environment.readFile(path) else { return false }
        guard let preferences = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] else { return nil }
        guard let stored = preferences["remoteAgent.settings"] else { return false }
        guard let data = stored as? Data, let settings = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return settings["mcpEnabled"] == .bool(true)
    }

    private static func savedSettings(_ app: AppLocation, _ environment: CLIEnvironment) -> JSONValue? {
        guard let path = app.preferencesPath, let plist = try? environment.readFile(path),
            let preferences = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
            let data = preferences["remoteAgent.settings"] as? Data
        else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func url(_ text: String) throws(CLIFailure) -> URL {
        var text = text
        if !text.contains("://") { text = "http://" + text }
        guard var components = URLComponents(string: text), let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            components.host?.isEmpty == false
        else { throw .arguments("--server must be a URL such as http://127.0.0.1:7778/mcp.") }
        if components.path.isEmpty || components.path == "/" { components.path = "/mcp" }
        guard let url = components.url else { throw .arguments("--server must be a URL such as http://127.0.0.1:7778/mcp.") }
        return url
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen: [URL] = []
        for url in urls where !seen.contains(url) { seen.append(url) }
        return seen
    }
}
