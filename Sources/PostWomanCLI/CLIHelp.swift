import Foundation

/// The text behind `help`, `--help` and `--version`: plain ASCII-friendly text for pipes and pagers.
/// `CLITests` checks every command is listed and every flag documented.
enum CLIHelp {
    static let nouns: [(String, String)] = [
        ("collection", "List, show, create, rename and delete collections"),
        ("request", "List, show, create, change, delete and send saved requests"),
        ("environment", "List, show, create, change, delete and choose a collection's environments"),
        ("history", "List, show, add, change and delete History entries"),
        ("tools", "List the MCP tools the app offers"),
        ("call", "Call any MCP tool with raw JSON arguments"),
        ("cli", "Link this command into your PATH (local; needs no app)")
    ]

    static let exitStatuses: [(Int32, String)] = [
        (0, "Success"), (1, "The tool failed (another error code)"), (2, "Invalid arguments (INVALID_ARGUMENTS, INVALID_PARAMS)"),
        (3, "No agent token, or the app refused it (AUTH_REQUIRED, AUTH_FAILED)"), (4, "Not found (NOT_FOUND)"),
        (5, "The request got no response (REQUEST_FAILED)"), (6, "Rate or size limit (LIMIT_EXCEEDED, RATE_LIMITED); retry later"),
        (7, "PostWoman isn't reachable (APP_NOT_REACHABLE, TRANSPORT)"), (22, "request execute --fail got a 4xx or 5xx response")
    ]

    static let globals: [(String, String)] = [
        ("--server URL", "MCP endpoint (default: from the app's settings, else http://127.0.0.1:7778/mcp). Env: POSTWOMAN_URL"),
        ("--agent-token TOKEN", "Agent token from Settings → Remote Agent (default: read from the app). Env: POSTWOMAN_TOKEN"),
        ("--agent-token-file PATH", "Read the agent token from a file. Env: POSTWOMAN_TOKEN_FILE"),
        ("--json", "Print {\"ok\": true, \"result\": …} or {\"ok\": false, \"error\": …} on stdout"),
        ("-h, --help", "Show help"), ("--version", "Show the version")
    ]

    static var version: String { "postwoman \(CLI.version)" }

    static func text(noun: String?, verb: String?) throws(CLIFailure) -> String {
        guard let noun else { return overview }
        let commands = CLICommands.all.filter { $0.noun == noun }
        guard !commands.isEmpty else { throw .arguments("Unknown command \(noun).") }
        if let verb, noun != "call" {
            guard let command = commands.first(where: { $0.verb == verb }) else { throw .arguments("Unknown command \(noun) \(verb).") }
            return detail(command)
        }
        if commands.count == 1 { return detail(commands[0]) }
        var lines = ["Usage: postwoman \(noun) <command> [options]", ""]
        let width = commands.map(\.verb.count).max() ?? 0
        lines += commands.map { "  \($0.verb.padding(toLength: width, withPad: " ", startingAt: 0))  \($0.summary)" }
        lines += ["", "Run 'postwoman help \(noun) <command>' for its options."]
        return lines.joined(separator: "\n")
    }

    private static var overview: String {
        var lines = [
            "postwoman: work with PostWoman's collections, requests and History from the command line.",
            "It talks to the running app over MCP: turn on Settings → Remote Agent and press Apply first.", "",
            "Usage: postwoman <noun> <command> [options]", "", "Commands:"
        ]
        let width = nouns.map(\.0.count).max() ?? 0
        lines += nouns.map { "  \($0.0.padding(toLength: width, withPad: " ", startingAt: 0))  \($0.1)" }
        lines += ["", "Global options:"] + table(globals)
        lines += ["  Flags win over environment variables: --agent-token, then --agent-token-file, then POSTWOMAN_TOKEN, then POSTWOMAN_TOKEN_FILE."]
        lines += [
            "", "Examples:", "  postwoman collection list", "  postwoman request create --collection ID --name 'Get user' --url https://api.example.com/users/1",
            "  postwoman request execute --id ID --include", "  postwoman request execute -X POST --url https://httpbin.org/post -H 'Accept: application/json' -d '{\"a\":1}'",
            "  postwoman environment create --collection ID --name Staging --var baseUrl=https://staging.example.com --select",
            "  postwoman history list --limit 10", "", "Run 'postwoman help <noun>' for its commands, 'postwoman help <noun> <command>' for options.",
            "", "Exit status:"
        ]
        lines += exitStatuses.map { "  \(String($0.0).padding(toLength: 3, withPad: " ", startingAt: 0)) \($0.1)" }
        return lines.joined(separator: "\n")
    }

    private static func detail(_ command: Command) -> String {
        let prefix = command.noun == "call" ? "postwoman call" : "postwoman \(command.name)"
        var lines = command.usage.map { "Usage: \(prefix)\($0.isEmpty ? "" : " " + $0)" } + ["", command.summary]
        if !command.flags.isEmpty {
            lines += ["", "Options:"]
            lines += table(
                command.flags.map { flag in
                    let short = flag.short.map { "-\($0), " } ?? ""
                    return ("\(short)--\(flag.name)\(flag.value.map { " \($0)" } ?? "")", flag.help + (flag.repeatable ? " (repeatable)" : ""))
                })
        }
        lines += ["", "Global options: --server URL, --agent-token TOKEN, --agent-token-file PATH, --json (see 'postwoman help')."]
        return lines.joined(separator: "\n")
    }

    private static func table(_ rows: [(String, String)]) -> [String] {
        let width = rows.map(\.0.count).max() ?? 0
        return rows.map { "  \($0.0.padding(toLength: width, withPad: " ", startingAt: 0))  \($0.1)" }
    }

    /// Where to read next after an argument error.
    static func hint(_ arguments: [String]) -> String {
        let words = arguments.filter { !$0.hasPrefix("-") }.prefix(2)
        if let noun = words.first, CLICommands.nouns.contains(noun) {
            if words.count == 2, CLICommands.command(noun, words.last!) != nil { return "Run 'postwoman help \(noun) \(words.last!)' for its options." }
            return "Run 'postwoman help \(noun)' for its commands."
        }
        return "Run 'postwoman help' for the commands."
    }
}
