import Foundation
import XCTest

@testable import PostWomanCLI

/// Collects what the CLI prints.
final class CLIOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out: [String] = []
    private var err: [String] = []
    var stdout: String { lock.withLock { out.joined(separator: "\n") } }
    var stderr: String { lock.withLock { err.joined(separator: "\n") } }
    func write(_ text: String, error: Bool) { lock.withLock { error ? err.append(text) : out.append(text) } }
}

/// In-memory files and links, so tests never touch the real home directory.
final class FakeFiles: @unchecked Sendable {
    private let lock = NSLock()
    var files: [String: Data] = [:]
    var links: [String: String] = [:]

    func read(_ path: String) throws -> Data {
        guard let data = lock.withLock({ files[path] }) else { throw CocoaError(.fileNoSuchFile) }
        return data
    }

    var cliLinks: CLILinks {
        CLILinks(
            destination: { path in self.lock.withLock { self.links[path] } },
            exists: { path in self.lock.withLock { self.links[path] != nil || self.files[path] != nil } },
            createDirectory: { _ in },
            createLink: { path, target in self.lock.withLock { self.links[path] = target } },
            remove: { path in self.lock.withLock { self.links[path] = nil } })
    }
}

func makeCLIEnvironment(
    output: CLIOutputBox, files: FakeFiles = FakeFiles(), variables: [String: String] = [:],
    send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { _ in throw URLError(.cannotConnectToHost) }
) -> CLIEnvironment {
    CLIEnvironment(
        send: send, variable: { variables[$0] }, readFile: { try files.read($0) }, readStdin: { Data("from stdin".utf8) },
        stdout: { output.write($0, error: false) }, stderr: { output.write($0, error: true) }, home: "/Users/test", executablePath: "/Applications/PostWoman.app/Contents/Helpers/postwoman",
        links: files.cliLinks)
}

final class CLIArgumentTests: XCTestCase {
    private let input = CLIInput(readFile: { _ in Data("file body".utf8) }, readStdin: { Data("stdin body".utf8) })

    private func run(_ words: [String]) throws -> (Command, ToolArguments, GlobalOptions, String?) {
        guard case .run(let command, let arguments, let global, let positional) = try CLIArguments.parse(words, input: input) else {
            throw CLIFailure.arguments("not a run")
        }
        return (command, arguments, global, positional)
    }

    func testBuildsToolArgumentsFromFlags() throws {
        let (command, arguments, global, _) = try run([
            "request", "create", "--json", "--collection", "C", "--name=Create user", "-X", "post", "-H", "Accept: application/json", "--header", "X-Id:  7 ",
            "--query", "q=a=b", "--body-file", "-", "--bearer", "secret", "--agent-token", "pwm_x"
        ])
        XCTAssertEqual(command.tool, "request_create")
        XCTAssertTrue(global.json)
        XCTAssertEqual(global.token, "pwm_x")
        let merged = arguments.merged(nestFields: false)
        XCTAssertEqual(merged["collectionId"], .string("C"))
        XCTAssertEqual(merged["name"], .string("Create user"))
        XCTAssertEqual(merged["method"], .string("POST"))
        XCTAssertEqual(
            merged["headers"],
            .array([.object(["key": .string("Accept"), "value": .string("application/json")]), .object(["key": .string("X-Id"), "value": .string("7")])]))
        XCTAssertEqual(merged["queryParams"], .array([.object(["key": .string("q"), "value": .string("a=b")])]))
        XCTAssertEqual(merged["body"], .string("stdin body"))
        XCTAssertEqual(merged["auth"], .object(["type": .string("bearer"), "token": .string("secret")]))
    }

    func testAdHocExecuteNestsTheRequest() throws {
        let (_, arguments, _, _) = try run(["request", "execute", "--url", "https://x.test", "-u", "ada:pa:ss", "-i", "--no-history"])
        let merged = arguments.merged(nestFields: true)
        XCTAssertEqual(merged["recordHistory"], .bool(false))
        XCTAssertEqual(merged["request"]?["url"], .string("https://x.test"))
        XCTAssertEqual(merged["request"]?["auth"]?["password"], .string("pa:ss"))
        XCTAssertTrue(arguments.options.contains("include"))
        XCTAssertNil(merged["include"], "Output options never reach the tool.")
    }

    func testRejectsBadArguments() {
        func code(_ words: [String]) -> String? {
            do {
                _ = try CLIArguments.parse(words, input: input)
                return nil
            } catch {
                return error.message
            }
        }
        XCTAssertEqual(code(["request", "get", "--idd", "x"]), "request get has no option --idd.")
        XCTAssertEqual(code(["request", "get", "--id"]), "--id needs a value (ID).")
        XCTAssertEqual(code(["request", "get", "--id", "a", "--id", "b"]), "--id is given twice.")
        XCTAssertEqual(code(["request", "create", "-X", "PATCH"]), "--method must be one of GET, POST, PUT, DELETE.")
        XCTAssertEqual(code(["request", "create", "-H", "no colon"]), "--header must look like \"Name: value\".")
        XCTAssertEqual(code(["request", "create", "--body", "a", "--body-file", "b"]), "Pass --body or --body-file, not both.")
        XCTAssertEqual(code(["request"]), "Say what to do with request: list, get, create, update, delete, execute.")
        XCTAssertEqual(code(["nope", "list"]), "Unknown command nope.")
        XCTAssertEqual(code(["history", "list", "--limit", "-1"]), "--limit must be a whole number of 0 or more.")
        XCTAssertEqual(code(["call"]), "Name the tool: postwoman call TOOL [--args JSON].")
    }

    func testHelpVersionAndCall() throws {
        guard case .version = try CLIArguments.parse(["--version"], input: input) else { return XCTFail() }
        guard case .help(nil, nil) = try CLIArguments.parse([], input: input) else { return XCTFail() }
        guard case .help("request", "execute") = try CLIArguments.parse(["help", "request", "execute"], input: input) else { return XCTFail() }
        guard case .help("history", nil) = try CLIArguments.parse(["history", "--help"], input: input) else { return XCTFail() }
        let (command, arguments, _, positional) = try run(["call", "history_list", "--args", #"{"limit":2}"#])
        XCTAssertEqual(command.noun, "call")
        XCTAssertEqual(positional, "history_list")
        XCTAssertEqual(arguments.root["args"], .string(#"{"limit":2}"#))
        XCTAssertEqual(try run(["tools"]).0.name, "tools list")
    }

    func testEveryCommandAndFlagIsDocumented() throws {
        let overview = try CLIHelp.text(noun: nil, verb: nil)
        for noun in CLICommands.nouns { XCTAssertTrue(overview.contains("  \(noun) "), noun) }
        var shorts: [String: Set<Character>] = [:]
        for command in CLICommands.all {
            let text = try CLIHelp.text(noun: command.noun, verb: command.verb)
            for flag in command.flags {
                XCTAssertTrue(text.contains("--\(flag.name)"), "\(command.name) --\(flag.name)")
                if let short = flag.short { XCTAssertTrue(shorts[command.name, default: []].insert(short).inserted, "\(command.name) -\(short) twice") }
            }
            XCTAssertEqual(Set(command.flags.map(\.name)).count, command.flags.count, "\(command.name) repeats a flag")
        }
    }
}

final class CLIConnectionTests: XCTestCase {
    private func settingsPlist(port: Int, address: String = "127.0.0.1") throws -> Data {
        let settings = Data(#"{"mcpEnabled":true,"bindAddress":"\#(address)","port":\#(port)}"#.utf8)
        return try PropertyListSerialization.data(fromPropertyList: ["remoteAgent.settings": settings], format: .binary, options: 0)
    }

    func testReadsEachAppsTokenAndEndpoint() throws {
        let files = FakeFiles()
        let apps = AppLocation.all(home: "/Users/test")
        files.files[apps[0].tokenPath] = Data("pwm_release\n".utf8)
        files.files[apps[0].preferencesPath!] = try settingsPlist(port: 9001, address: "0.0.0.0")
        files.files[apps[1].tokenPath] = Data("pwm_dev".utf8)
        let environment = makeCLIEnvironment(output: CLIOutputBox(), files: files)
        let candidates = try ConnectionResolver.candidates(server: nil, token: nil, tokenFile: nil, environment: environment)
        XCTAssertEqual(
            candidates,
            [
                Connection(url: URL(string: "http://127.0.0.1:9001/mcp")!, token: "pwm_release"),
                Connection(url: URL(string: "http://127.0.0.1:7778/mcp")!, token: "pwm_dev")
            ])
        XCTAssertTrue(apps[0].tokenPath.contains("/Library/Containers/com.bearstouch.postwoman/Data/Library/Application Support/PostWoman/"))
    }

    func testFlagsAndEnvironmentWin() throws {
        let files = FakeFiles()
        files.files["/tmp/token"] = Data("pwm_file".utf8)
        let environment = makeCLIEnvironment(output: CLIOutputBox(), files: files, variables: ["POSTWOMAN_URL": "localhost:9100", "POSTWOMAN_TOKEN": "pwm_env"])
        XCTAssertEqual(
            try ConnectionResolver.candidates(server: nil, token: nil, tokenFile: nil, environment: environment),
            [Connection(url: URL(string: "http://localhost:9100/mcp")!, token: "pwm_env")])
        XCTAssertEqual(
            try ConnectionResolver.candidates(server: "http://[::1]:9200/mcp", token: "pwm_flag", tokenFile: nil, environment: environment),
            [Connection(url: URL(string: "http://[::1]:9200/mcp")!, token: "pwm_flag")])
        let fileOnly = makeCLIEnvironment(output: CLIOutputBox(), files: files)
        XCTAssertEqual(try ConnectionResolver.candidates(server: nil, token: nil, tokenFile: "/tmp/token", environment: fileOnly).first?.token, "pwm_file")
    }

    func testNoTokenAndNoAppExplainWhatToDo() async {
        let output = CLIOutputBox()
        let status = await CLI.run(["collection", "list"], environment: makeCLIEnvironment(output: output))
        XCTAssertEqual(status, 3)
        XCTAssertTrue(output.stderr.contains("Settings → Remote Agent"))

        let unreachable = CLIOutputBox()
        let refused = await CLI.run(["--agent-token", "pwm_x", "--json", "collection", "list"], environment: makeCLIEnvironment(output: unreachable))
        XCTAssertEqual(refused, 7)
        XCTAssertTrue(unreachable.stdout.contains(#""code":"APP_NOT_REACHABLE""#))
    }
}

final class CLILinkTests: XCTestCase {
    func testInstallsAndRemovesTheLink() async {
        let files = FakeFiles()
        let output = CLIOutputBox()
        let environment = makeCLIEnvironment(output: output, files: files, variables: ["PATH": "/usr/bin:/Users/test/.local/bin"])
        let status = await CLI.run(["cli", "install-link"], environment: environment)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(files.links["/Users/test/.local/bin/postwoman"], "/Applications/PostWoman.app/Contents/Helpers/postwoman")
        XCTAssertFalse(output.stderr.contains("Add "), "The directory is already on PATH.")

        files.links["/Users/test/.local/bin/postwoman"] = "/somewhere/else"
        let taken = await CLI.run(["cli", "install-link"], environment: environment)
        XCTAssertEqual(taken, 1)
        let forced = await CLI.run(["cli", "install-link", "--force"], environment: environment)
        XCTAssertEqual(forced, 0)

        files.files["/opt/bin/postwoman"] = Data()
        let notALink = await CLI.run(["cli", "install-link", "--directory", "/opt/bin/"], environment: environment)
        XCTAssertEqual(notALink, 1, "A real file is never replaced.")

        let removed = await CLI.run(["cli", "remove-link"], environment: environment)
        XCTAssertEqual(removed, 0)
        XCTAssertNil(files.links["/Users/test/.local/bin/postwoman"])
    }
}
