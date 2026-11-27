import Foundation
import XCTest

@testable import PostWomanCLI

/// Counts what would have gone to the app; help, version and argument errors must send nothing.
private final class SendCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var sent: Int { lock.withLock { count } }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        lock.withLock { count += 1 }
        throw URLError(.cannotConnectToHost)
    }
}

private func runCLI(_ words: [String]) async -> (status: Int32, stdout: String, stderr: String, sent: Int) {
    let output = CLIOutputBox()
    let counter = SendCounter()
    let files = FakeFiles()
    files.files[AppLocation.all(home: "/Users/test")[0].tokenPath] = Data("pwm_release".utf8)
    let environment = makeCLIEnvironment(output: output, files: files, send: { try counter.send($0) })
    let status = await CLI.run(words, environment: environment)
    return (status, output.stdout, output.stderr, counter.sent)
}

private func helpText(_ noun: String?, _ verb: String?) -> String {
    do { return try CLIHelp.text(noun: noun, verb: verb) } catch { return "error: \(error.message)" }
}

private let globalLine = "Global options: --server URL, --agent-token TOKEN, --agent-token-file PATH, --json (see 'postwoman help')."

final class CLIHelpTextTests: XCTestCase {
    func testEveryCommandsHelpGoesToStdoutAndNeverContactsTheApp() async {
        for command in CLICommands.all {
            let words = command.noun == "call" ? ["call", "tool"] : [command.noun, command.verb]
            let expected = helpText(command.noun, command.verb)
            XCTAssertFalse(expected.hasPrefix("error:"), command.name)
            for form in [words + ["--help"], words + ["-h"], ["help"] + words, ["--help"] + words, words + ["--id", "x", "--help"]] {
                let result = await runCLI(form)
                XCTAssertEqual(result.status, 0, "\(form)")
                XCTAssertEqual(result.stdout, expected, "\(form)")
                XCTAssertEqual(result.stderr, "", "\(form)")
                XCTAssertEqual(result.sent, 0, "\(form)")
            }
        }
    }

    func testEveryNounsHelpListsItsCommandsInAnAlignedColumn() async throws {
        for noun in CLICommands.nouns {
            let commands = CLICommands.all.filter { $0.noun == noun }
            let result = await runCLI([noun, "--help"])
            XCTAssertEqual(result.status, 0, noun)
            XCTAssertEqual(result.stdout, helpText(noun, nil), noun)
            let same = await runCLI(["help", noun])
            XCTAssertEqual(same.stdout, result.stdout, noun)
            guard commands.count > 1 else {
                XCTAssertEqual(result.stdout, helpText(noun, commands[0].verb), "\(noun) has one command, so its help is that command's")
                continue
            }
            let lines = result.stdout.components(separatedBy: "\n")
            XCTAssertEqual(lines.first, "Usage: postwoman \(noun) <command> [options]")
            XCTAssertEqual(lines.last, "Run 'postwoman help \(noun) <command>' for its options.")
            let width = try XCTUnwrap(commands.map(\.verb.count).max())
            for command in commands {
                XCTAssertTrue(lines.contains("  \(command.verb.padding(toLength: width, withPad: " ", startingAt: 0))  \(command.summary)"), command.name)
            }
        }
    }

    func testCommandHelpShowsUsageSummaryOptionsAndGlobals() {
        XCTAssertEqual(
            helpText("request", "get"),
            ["Usage: postwoman request get --id ID", "", "Show a saved request.", "", "Options:", "  --id ID  Request ID.", "", globalLine].joined(separator: "\n"))
        XCTAssertEqual(
            helpText("collection", "list"),
            ["Usage: postwoman collection list", "", "List collections with their IDs and request counts.", "", globalLine].joined(separator: "\n"), "No options, no Options section")
        XCTAssertEqual(
            helpText("collection", "get"),
            [
                "Usage: postwoman collection get --id ID [--no-requests]", "", "Show a collection and every request in it.", "", "Options:",
                "  --id ID        Collection ID.", "  --no-requests  Leave out the requests.", "", globalLine
            ].joined(separator: "\n"))
        XCTAssertTrue(helpText("call", nil).hasPrefix("Usage: postwoman call TOOL [--args JSON]\n"))
        XCTAssertEqual(helpText("call", "anything"), helpText("call", nil), "call's second word is a tool, not a command")
        XCTAssertEqual(helpText("tools", nil), helpText("tools", "list"))
    }

    func testExecuteHelpShowsBothUsagesShortFlagsAndRepeatableOnes() throws {
        let text = helpText("request", "execute")
        XCTAssertTrue(
            text.hasPrefix("Usage: postwoman request execute --id ID [output options]\nUsage: postwoman request execute --url URL [request fields] [output options]\n\n"))
        let lines = text.components(separatedBy: "\n")
        for (start, end) in [
            ("  -X, --method METHOD", "GET, POST, PUT or DELETE."), ("  -H, --header 'NAME: VALUE'", "(repeatable)"), ("  --query NAME=VALUE", "(repeatable)"),
            ("  -d, --body TEXT", "The body text."), ("  -u, --basic USER:PASSWORD", "Basic authentication."), ("  -i, --include", "before the body."),
            ("  -f, --fail", "400 or more."), ("  --env ID|default", "(default: the one it uses).")
        ] {
            XCTAssertTrue(lines.contains { $0.hasPrefix(start) && $0.hasSuffix(end) }, start)
        }
        XCTAssertFalse(lines.contains { $0.contains("--body TEXT") && $0.hasSuffix("(repeatable)") }, "Only repeatable flags say so")
    }

    func testOptionDescriptionsStartInOneColumn() throws {
        for command in CLICommands.all where !command.flags.isEmpty {
            let lines = helpText(command.noun, command.verb).components(separatedBy: "\n")
            let start = try XCTUnwrap(lines.firstIndex(of: "Options:"), command.name) + 1
            let options = lines[start..<lines.count].prefix { !$0.isEmpty }
            XCTAssertEqual(options.count, command.flags.count, command.name)
            let columns = Set(
                zip(options, command.flags).map { line, flag -> Int in
                    guard let range = line.range(of: "  " + flag.help) else { return -1 }
                    return line.distance(from: line.startIndex, to: range.lowerBound)
                })
            XCTAssertEqual(columns.count, 1, command.name)
            XCTAssertFalse(columns.contains(-1), command.name)
        }
    }

    func testOverviewListsNounsGlobalOptionsExamplesAndExitStatuses() async throws {
        let result = await runCLI(["--help"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stderr, "")
        let text = result.stdout
        XCTAssertTrue(text.hasPrefix("postwoman: work with PostWoman's collections, requests and History from the command line.\n"))
        let lines = text.components(separatedBy: "\n")
        for heading in ["Usage: postwoman <noun> <command> [options]", "Commands:", "Global options:", "Examples:", "Exit status:"] {
            XCTAssertTrue(lines.contains(heading), heading)
        }
        let width = try XCTUnwrap(CLIHelp.nouns.map(\.0.count).max())
        for (noun, summary) in CLIHelp.nouns { XCTAssertTrue(lines.contains("  \(noun.padding(toLength: width, withPad: " ", startingAt: 0))  \(summary)"), noun) }
        for (option, _) in CLIHelp.globals { XCTAssertTrue(lines.contains { $0.hasPrefix("  \(option) ") }, option) }
        XCTAssertTrue(
            lines.contains("  Flags win over environment variables: --agent-token, then --agent-token-file, then POSTWOMAN_TOKEN, then POSTWOMAN_TOKEN_FILE."),
            "The token precedence is documented")
        XCTAssertTrue(lines.contains("  0   Success"))
        XCTAssertTrue(lines.contains("  22  request execute --fail got a 4xx or 5xx response"))
        XCTAssertEqual(lines.last, "  22  request execute --fail got a 4xx or 5xx response", "Exit statuses end the overview")
        for empty in [[], ["help"], ["-h"]] {
            let same = await runCLI(empty)
            XCTAssertEqual(same.stdout, text, "\(empty)")
        }
    }

    func testHelpTablesMatchTheCommandsAndExitStatuses() {
        XCTAssertEqual(CLIHelp.nouns.map(\.0), CLICommands.nouns, "Every noun is described, in the table's order")
        XCTAssertEqual(CLIHelp.exitStatuses.map(\.0), [0, 1, 2, 3, 4, 5, 6, 7, 22])
        XCTAssertEqual(CLIOutput.failedResponseStatus, 22)
        let documented = Set(CLIHelp.exitStatuses.map(\.0))
        for failure in [CLIFailure.arguments("x"), .transport("x"), .notRunning("u"), .noToken, .tokenRefused, .rateLimited] {
            XCTAssertTrue(documented.contains(failure.exitStatus), failure.code)
        }
        for code in ["INVALID_PARAMS", "NOT_FOUND", "REQUEST_FAILED", "LIMIT_EXCEEDED", "OTHER"] {
            XCTAssertTrue(documented.contains(CLIFailure.tool(.object(["code": .string(code)])).exitStatus), code)
        }
        XCTAssertEqual(CLIHelp.version, "postwoman \(CLI.version)")
    }

    func testUnknownHelpTopicsFailWithExitStatusTwo() async {
        let cases: [([String], String)] = [
            (["help", "nope"], "postwoman: Unknown command nope. (INVALID_ARGUMENTS)\nRun 'postwoman help' for the commands."),
            (["help", "request", "nope"], "postwoman: Unknown command request nope. (INVALID_ARGUMENTS)\nRun 'postwoman help' for the commands."),
            (["request", "nope", "--help"], "postwoman: Unknown command request nope. (INVALID_ARGUMENTS)\nRun 'postwoman help request' for its commands."),
            (["nope", "--help"], "postwoman: Unknown command nope. (INVALID_ARGUMENTS)\nRun 'postwoman help' for the commands.")
        ]
        for (words, expected) in cases {
            let result = await runCLI(words)
            XCTAssertEqual(result.status, 2, "\(words)")
            XCTAssertEqual(result.stdout, "", "\(words)")
            XCTAssertEqual(result.stderr, expected, "\(words)")
        }
    }

    func testVersionPrintsPlainOrInTheEnvelope() async {
        for words in [["--version"], ["--version", "collection", "list"]] {
            let result = await runCLI(words)
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.stdout, "postwoman \(CLI.version)", "\(words)")
            XCTAssertEqual(result.sent, 0)
        }
        for words in [["--json", "--version"], ["--version", "--json"]] {
            let result = await runCLI(words)
            XCTAssertEqual(result.stdout, #"{"ok":true,"result":{"version":"\#(CLI.version)"}}"#, "\(words)")
            XCTAssertEqual(result.stderr, "")
        }
    }

    func testJSONHelpIsTheTextInTheEnvelope() async throws {
        for (words, noun, verb) in [(["--json", "--help"], nil, nil), (["request", "execute", "--help", "--json"], "request", "execute"), (["help", "history", "--json"], "history", nil)] as [([String], String?, String?)]
        {
            let result = await runCLI(words)
            XCTAssertEqual(result.status, 0)
            XCTAssertFalse(result.stdout.contains("\n"), "One line, for scripts")
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
            XCTAssertEqual(value, .object(["ok": .bool(true), "result": .object(["help": .string(helpText(noun, verb))])]), "\(words)")
        }
    }

    func testArgumentErrorsSayWhereToReadNext() async {
        let cases: [([String], String)] = [
            (["request", "get", "--idd", "x"], "postwoman: request get has no option --idd. (INVALID_ARGUMENTS)\nRun 'postwoman help request get' for its options."),
            (["request"], "postwoman: Say what to do with request: list, get, create, update, delete, execute. (INVALID_ARGUMENTS)\nRun 'postwoman help request' for its commands."),
            (["request", "nope"], "postwoman: Unknown command request nope. Try list, get, create, update, delete, execute. (INVALID_ARGUMENTS)\nRun 'postwoman help request' for its commands."),
            (["nope"], "postwoman: Unknown command nope. (INVALID_ARGUMENTS)\nRun 'postwoman help' for the commands."),
            (["history", "list", "--limit", "-1"], "postwoman: --limit must be a whole number of 0 or more. (INVALID_ARGUMENTS)\nRun 'postwoman help history list' for its options."),
            (["collection", "list", "--server"], "postwoman: --server needs a value. (INVALID_ARGUMENTS)\nRun 'postwoman help collection list' for its options.")
        ]
        for (words, expected) in cases {
            let result = await runCLI(words)
            XCTAssertEqual(result.status, 2, "\(words)")
            XCTAssertEqual(result.stdout, "", "\(words)")
            XCTAssertEqual(result.stderr, expected, "\(words)")
            XCTAssertEqual(result.sent, 0, "Argument errors never reach the app: \(words)")
        }
    }

    func testJSONArgumentErrorsGoToStdoutOnly() async throws {
        let result = await runCLI(["--json", "request", "get", "--idd", "x"])
        XCTAssertEqual(result.status, 2)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.stdout, #"{"error":{"code":"INVALID_ARGUMENTS","exitStatus":2,"message":"request get has no option --idd."},"ok":false}"#)
    }

    func testHintsFollowTheFirstTwoWords() {
        let cases: [([String], String)] = [
            (["request", "get", "--idd"], "Run 'postwoman help request get' for its options."), (["--json", "request", "get"], "Run 'postwoman help request get' for its options."),
            (["request", "nope"], "Run 'postwoman help request' for its commands."), (["request"], "Run 'postwoman help request' for its commands."),
            (["nope", "get"], "Run 'postwoman help' for the commands."), ([], "Run 'postwoman help' for the commands."),
            (["tools", "list"], "Run 'postwoman help tools list' for its options.")
        ]
        for (words, expected) in cases { XCTAssertEqual(CLIHelp.hint(words), expected, "\(words)") }
    }
}
