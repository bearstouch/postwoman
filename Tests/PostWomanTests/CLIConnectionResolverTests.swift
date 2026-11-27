import Foundation
import XCTest

@testable import PostWomanCLI

private let home = "/Users/test"
private let fallback = "http://127.0.0.1:7778/mcp"

private func plist(_ settings: String) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: ["remoteAgent.settings": Data(settings.utf8)], format: .binary, options: 0)
}

private func environment(_ files: FakeFiles = FakeFiles(), variables: [String: String] = [:]) -> CLIEnvironment {
    makeCLIEnvironment(output: CLIOutputBox(), files: files, variables: variables)
}

private func candidates(
    server: String? = nil, token: String? = nil, tokenFile: String? = nil, files: FakeFiles = FakeFiles(), variables: [String: String] = [:]
) throws -> [String] {
    try ConnectionResolver.candidates(server: server, token: token, tokenFile: tokenFile, environment: environment(files, variables: variables)).map {
        "\($0.url.absoluteString) \($0.token)"
    }
}

private func failure(server: String? = nil, token: String? = nil, tokenFile: String? = nil, files: FakeFiles = FakeFiles(), variables: [String: String] = [:]) -> String? {
    do {
        _ = try ConnectionResolver.candidates(server: server, token: token, tokenFile: tokenFile, environment: environment(files, variables: variables))
        return nil
    } catch {
        XCTAssertEqual(error.exitStatus, 2)
        return error.message
    }
}

final class CLIConnectionResolverTests: XCTestCase {
    private let apps = AppLocation.all(home: home)

    func testAppLocationsAreTheReleaseDevAndSwiftRunContainers() {
        XCTAssertEqual(
            apps,
            [
                AppLocation(
                    name: "PostWoman", tokenPath: "/Users/test/Library/Containers/com.bearstouch.postwoman/Data/Library/Application Support/PostWoman/remote-agent-token",
                    preferencesPath: "/Users/test/Library/Containers/com.bearstouch.postwoman/Data/Library/Preferences/com.bearstouch.postwoman.plist"),
                AppLocation(
                    name: "PostWoman Dev",
                    tokenPath: "/Users/test/Library/Containers/com.bearstouch.postwoman.dev/Data/Library/Application Support/PostWoman/remote-agent-token",
                    preferencesPath: "/Users/test/Library/Containers/com.bearstouch.postwoman.dev/Data/Library/Preferences/com.bearstouch.postwoman.dev.plist"),
                AppLocation(name: "PostWoman (swift run)", tokenPath: "/Users/test/Library/Application Support/PostWoman Dev/remote-agent-token", preferencesPath: nil)
            ])
    }

    func testServerURLsAreCompletedToTheMCPEndpoint() throws {
        let cases: [(String, String)] = [
            ("localhost:9100", "http://localhost:9100/mcp"), ("127.0.0.1", "http://127.0.0.1/mcp"), ("http://h", "http://h/mcp"), ("https://h/", "https://h/mcp"),
            ("http://h:1/custom", "http://h:1/custom"), ("http://[::1]:9200", "http://[::1]:9200/mcp"), ("http://h?x=1", "http://h/mcp?x=1"),
            ("h/x", "http://h/x")
        ]
        for (given, expected) in cases { XCTAssertEqual(try ConnectionResolver.url(given).absoluteString, expected, given) }
        XCTAssertNoThrow(try ConnectionResolver.url("HTTPS://h"), "The scheme is case-insensitive")
    }

    func testServerURLsMustBeHTTP() {
        for rejected in ["ftp://h", "file:///tmp/socket", "ws://h:1", "http://h:abc", "http://h:port/mcp"] {
            XCTAssertEqual(failure(server: rejected, token: "pwm_x"), "--server must be a URL such as http://127.0.0.1:7778/mcp.", rejected)
            XCTAssertEqual(failure(token: "pwm_x", variables: ["POSTWOMAN_URL": rejected]), "--server must be a URL such as http://127.0.0.1:7778/mcp.", rejected)
        }
    }

    func testServerURLsMustHaveAHost() {
        for rejected in ["", "http://", "http:///mcp", "https://", "http://:7778/mcp", "://", "  "] {
            XCTAssertEqual(failure(server: rejected, token: "pwm_x"), "--server must be a URL such as http://127.0.0.1:7778/mcp.", "'\(rejected)'")
            XCTAssertEqual(failure(token: "pwm_x", variables: ["POSTWOMAN_URL": rejected]), "--server must be a URL such as http://127.0.0.1:7778/mcp.", "'\(rejected)'")
        }
    }

    func testAnEmptyServerExitsWithAnArgumentError() async {
        let output = CLIOutputBox()
        let sent = SentFlag()
        let environment = makeCLIEnvironment(
            output: output, variables: ["POSTWOMAN_TOKEN": "pwm_x"],
            send: { _ in
                sent.set()
                throw URLError(.cannotConnectToHost)
            })
        let status = await CLI.run(["collection", "list", "--server", ""], environment: environment)
        XCTAssertEqual(status, 2)
        XCTAssertTrue(output.stderr.hasPrefix("postwoman: --server must be a URL such as http://127.0.0.1:7778/mcp."), output.stderr)
        XCTAssertFalse(sent.value, "Nothing is sent to http:///mcp")
    }

    func testAnExplicitTokenIsTriedAtEachAppsEndpoint() throws {
        let files = FakeFiles()
        files.files[try XCTUnwrap(apps[0].preferencesPath)] = try plist(#"{"port":9001}"#)
        files.files[try XCTUnwrap(apps[1].preferencesPath)] = try plist(#"{"port":9002,"bindAddress":"::"}"#)
        XCTAssertEqual(
            try candidates(token: "  pwm_x \n", files: files), ["http://127.0.0.1:9001/mcp pwm_x", "http://[::1]:9002/mcp pwm_x", "\(fallback) pwm_x"],
            "Trimmed, then each app's endpoint and the default")
        XCTAssertEqual(try candidates(token: "pwm_x"), ["\(fallback) pwm_x"], "No settings, only the default")

        let same = FakeFiles()
        same.files[try XCTUnwrap(apps[0].preferencesPath)] = try plist(#"{"port":7778}"#)
        same.files[try XCTUnwrap(apps[1].preferencesPath)] = try plist(#"{"port":7778,"bindAddress":"0.0.0.0"}"#)
        XCTAssertEqual(try candidates(token: "pwm_x", files: same), ["\(fallback) pwm_x"], "The same endpoint is tried once")
        XCTAssertEqual(try candidates(server: "http://h:1", token: "pwm_x", files: files), ["http://h:1/mcp pwm_x"], "An explicit endpoint is the only one")
    }

    func testFlagsBeatEnvironmentVariables() throws {
        let files = FakeFiles()
        files.files["/tmp/token"] = Data("pwm_file\n".utf8)
        let variables = ["POSTWOMAN_URL": "http://env:1", "POSTWOMAN_TOKEN": "pwm_env"]
        XCTAssertEqual(try candidates(files: files, variables: variables), ["http://env:1/mcp pwm_env"])
        XCTAssertEqual(try candidates(server: "http://flag:2", token: "pwm_flag", files: files, variables: variables), ["http://flag:2/mcp pwm_flag"])
        XCTAssertEqual(try candidates(tokenFile: "/tmp/token", files: files), ["\(fallback) pwm_file"])
        XCTAssertEqual(try candidates(files: files, variables: ["POSTWOMAN_TOKEN_FILE": "/tmp/token"]), ["\(fallback) pwm_file"])
        XCTAssertEqual(try candidates(token: "pwm_flag", tokenFile: "/tmp/missing", files: files), ["\(fallback) pwm_flag"], "A token is never read from a file when given")
    }

    func testAnyTokenFlagBeatsAnyTokenEnvironmentVariable() throws {
        let files = FakeFiles()
        files.files["/tmp/token"] = Data("pwm_file\n".utf8)
        files.files["/tmp/env-token"] = Data("pwm_envfile".utf8)
        let both = ["POSTWOMAN_TOKEN": "pwm_env", "POSTWOMAN_TOKEN_FILE": "/tmp/env-token"]
        XCTAssertEqual(try candidates(tokenFile: "/tmp/token", files: files, variables: ["POSTWOMAN_TOKEN": "pwm_env"]), ["\(fallback) pwm_file"])
        XCTAssertEqual(try candidates(tokenFile: "/tmp/token", files: files, variables: both), ["\(fallback) pwm_file"])
        XCTAssertEqual(try candidates(token: "pwm_flag", files: files, variables: both), ["\(fallback) pwm_flag"])
        XCTAssertEqual(try candidates(files: files, variables: both), ["\(fallback) pwm_env"], "Without flags, POSTWOMAN_TOKEN beats POSTWOMAN_TOKEN_FILE")
        XCTAssertEqual(
            failure(tokenFile: "/tmp/missing", files: files, variables: ["POSTWOMAN_TOKEN": "pwm_env"]), "Can't read the token file /tmp/missing.",
            "A token file flag is read even when POSTWOMAN_TOKEN is set")
        XCTAssertEqual(try candidates(server: "http://flag:2", files: files, variables: ["POSTWOMAN_URL": "http://env:1", "POSTWOMAN_TOKEN": "pwm_env"]), ["http://flag:2/mcp pwm_env"])
    }

    func testAnUnreadableTokenFileIsAnArgumentError() {
        XCTAssertEqual(failure(tokenFile: "/tmp/missing"), "Can't read the token file /tmp/missing.")
        XCTAssertEqual(failure(variables: ["POSTWOMAN_TOKEN_FILE": "/tmp/gone"]), "Can't read the token file /tmp/gone.")
    }

    func testAppTokensAreTrimmedAndEmptyOrMissingOnesSkipped() throws {
        let files = FakeFiles()
        files.files[apps[1].tokenPath] = Data("  \n".utf8)
        files.files[apps[2].tokenPath] = Data("pwm_run\n".utf8)
        XCTAssertEqual(try candidates(files: files), ["\(fallback) pwm_run"])
        XCTAssertEqual(try candidates(), [], "No token anywhere, no candidates")
    }

    func testEachAppsTokenGoesToItsOwnEndpointInOrder() throws {
        let files = FakeFiles()
        for (index, token) in ["pwm_release", "pwm_dev", "pwm_run"].enumerated() { files.files[apps[index].tokenPath] = Data(token.utf8) }
        files.files[try XCTUnwrap(apps[1].preferencesPath)] = try plist(#"{"port":9002,"bindAddress":"127.0.0.1"}"#)
        XCTAssertEqual(try candidates(files: files), ["\(fallback) pwm_release", "http://127.0.0.1:9002/mcp pwm_dev", "\(fallback) pwm_run"])
        XCTAssertEqual(
            try candidates(server: "h:3", files: files), ["http://h:3/mcp pwm_release", "http://h:3/mcp pwm_dev", "http://h:3/mcp pwm_run"],
            "An explicit endpoint applies to every app's token")
    }

    func testIdenticalAppConnectionsAreListedOnce() throws {
        let files = FakeFiles()
        files.files[apps[1].tokenPath] = Data("pwm_same".utf8)
        files.files[apps[2].tokenPath] = Data("pwm_same\n".utf8)
        XCTAssertEqual(try candidates(files: files), ["\(fallback) pwm_same"])
    }

    func testTheEndpointComesFromTheAppsSavedSettings() throws {
        let cases: [(String, String?)] = [
            (#"{"port":9001}"#, "http://127.0.0.1:9001/mcp"), (#"{"port":9001,"bindAddress":"0.0.0.0"}"#, "http://127.0.0.1:9001/mcp"),
            (#"{"port":9001,"bindAddress":"::"}"#, "http://[::1]:9001/mcp"), (#"{"port":9001,"bindAddress":"::1"}"#, "http://[::1]:9001/mcp"),
            (#"{"port":9001,"bindAddress":"192.168.1.5"}"#, "http://192.168.1.5:9001/mcp"), (#"{"mcpEnabled":true}"#, nil), ("not json", nil),
            (#"{"port":1e20}"#, nil), (#"{"port":-1}"#, nil), (#"{"port":65536}"#, nil), (#"{"port":9001.5}"#, nil)
        ]
        for (settings, expected) in cases {
            let files = FakeFiles()
            files.files[try XCTUnwrap(apps[0].preferencesPath)] = try plist(settings)
            XCTAssertEqual(ConnectionResolver.appURL(apps[0], environment(files))?.absoluteString, expected, settings)
        }
    }

    func testUnreadableSettingsFallBackToTheDefaultEndpoint() throws {
        let path = try XCTUnwrap(apps[0].preferencesPath)
        let unreadable: [Data] = [
            Data("garbage".utf8), try PropertyListSerialization.data(fromPropertyList: ["other": 1], format: .xml, options: 0),
            try PropertyListSerialization.data(fromPropertyList: ["remoteAgent.settings": "not data"], format: .binary, options: 0), Data()
        ]
        for data in unreadable {
            let files = FakeFiles()
            files.files[path] = data
            files.files[apps[0].tokenPath] = Data("pwm_release".utf8)
            XCTAssertNil(ConnectionResolver.appURL(apps[0], environment(files)))
            XCTAssertEqual(try candidates(files: files), ["\(fallback) pwm_release"])
        }
        XCTAssertNil(ConnectionResolver.appURL(apps[2], environment()), "swift run keeps no preferences file")
    }

    func testABadServerFailsBeforeContactingTheApp() async {
        let output = CLIOutputBox()
        let sent = SentFlag()
        let environment = makeCLIEnvironment(
            output: output, variables: ["POSTWOMAN_URL": "ftp://x", "POSTWOMAN_TOKEN": "pwm_x"],
            send: { _ in
                sent.set()
                throw URLError(.cannotConnectToHost)
            })
        let status = await CLI.run(["collection", "list"], environment: environment)
        XCTAssertEqual(status, 2)
        XCTAssertEqual(output.stderr, "postwoman: --server must be a URL such as http://127.0.0.1:7778/mcp. (INVALID_ARGUMENTS)\nRun 'postwoman help collection list' for its options.")
        XCTAssertFalse(sent.value)
    }
}

private final class SentFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
