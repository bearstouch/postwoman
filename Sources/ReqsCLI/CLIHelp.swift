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
        (7, "Reqs isn't reachable (APP_NOT_REACHABLE, TRANSPORT)"), (22, "request execute --fail got a 4xx or 5xx response")
    ]

    static let globals: [(String, String)] = [
        ("--server URL", "MCP endpoint (default: from the app's settings, else http://127.0.0.1:7778/mcp). Env: REQS_URL"),
        ("--agent-token TOKEN", "Agent token from Settings → Remote Agent (default: read from the app). Env: REQS_TOKEN"),
        ("--agent-token-file PATH", "Read the agent token from a file. Env: REQS_TOKEN_FILE"),
        ("--json", "Print {\"ok\": true, \"result\": …} or {\"ok\": false, \"error\": …} on stdout"),
        ("-h, --help", "Show help"), ("--version", "Show the version")
    ]

    static var version: String { "reqs \(CLI.version)" }

    static func text(noun: String?, verb: String?) throws(CLIFailure) -> String {
        guard let noun else { return overview }
        let commands = CLICommands.all.filter { $0.noun == noun }
        guard !commands.isEmpty else { throw .arguments("Unknown command \(noun).") }
        if let verb, noun != "call" {
            guard let command = commands.first(where: { $0.verb == verb }) else { throw .arguments("Unknown command \(noun) \(verb).") }
            return detail(command)
        }
        if commands.count == 1 { return detail(commands[0]) }
        var lines = ["Usage: reqs \(noun) <command> [options]", ""]
        let width = commands.map(\.verb.count).max() ?? 0
        lines += commands.map { "  \($0.verb.padding(toLength: width, withPad: " ", startingAt: 0))  \($0.summary)" }
        lines += ["", "Run 'reqs help \(noun) <command>' for its options."]
        return lines.joined(separator: "\n")
    }

    private static var overview: String {
        var lines = [
            "reqs: work with the collections, requests and History in Reqs from the command line.",
            "It talks to the running app over MCP: turn on Settings → Remote Agent and press Apply first.", "",
            "Usage: reqs <noun> <command> [options]", "", "Commands:"
        ]
        let width = nouns.map(\.0.count).max() ?? 0
        lines += nouns.map { "  \($0.0.padding(toLength: width, withPad: " ", startingAt: 0))  \($0.1)" }
        lines += ["", "Global options:"] + table(globals)
        lines += ["  Flags win over environment variables: --agent-token, then --agent-token-file, then REQS_TOKEN, then REQS_TOKEN_FILE."]
        lines += [
            "", "Examples:", "  reqs collection list", "  reqs request create --collection ID --name 'Get user' --url https://api.example.com/users/1",
            "  reqs request execute --id ID --include", "  reqs request execute -X POST --url https://httpbin.org/post -H 'Accept: application/json' -d '{\"a\":1}'",
            "  reqs environment create --collection ID --name Staging --var baseUrl=https://staging.example.com --select",
            "  reqs history list --limit 10", "", "Run 'reqs help <noun>' for its commands, 'reqs help <noun> <command>' for options.",
            "", "Exit status:"
        ]
        lines += exitStatuses.map { "  \(String($0.0).padding(toLength: 3, withPad: " ", startingAt: 0)) \($0.1)" }
        return lines.joined(separator: "\n")
    }

    private static func detail(_ command: Command) -> String {
        let prefix = command.noun == "call" ? "reqs call" : "reqs \(command.name)"
        var lines = command.usage.map { "Usage: \(prefix)\($0.isEmpty ? "" : " " + $0)" } + ["", command.summary]
        if !command.flags.isEmpty {
            lines += ["", "Options:"]
            lines += table(
                command.flags.map { flag in
                    let short = flag.short.map { "-\($0), " } ?? ""
                    return ("\(short)--\(flag.name)\(flag.value.map { " \($0)" } ?? "")", flag.help + (flag.repeatable ? " (repeatable)" : ""))
                })
        }
        lines += ["", "Global options: --server URL, --agent-token TOKEN, --agent-token-file PATH, --json (see 'reqs help')."]
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
            if words.count == 2, CLICommands.command(noun, words.last!) != nil { return "Run 'reqs help \(noun) \(words.last!)' for its options." }
            return "Run 'reqs help \(noun)' for its commands."
        }
        return "Run 'reqs help' for the commands."
    }
}
