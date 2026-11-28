import Foundation

/// What flags build: the tool's arguments, plus options that only change how the CLI prints.
struct ToolArguments: Sendable {
    var root: [String: JSONValue] = [:]
    /// Request fields (name, url, method, headers…): the tool's top level, or `request` for an ad-hoc execute.
    var fields: [String: JSONValue] = [:]
    var auth: [String: JSONValue] = [:]
    var response: [String: JSONValue] = [:]
    var options: Set<String> = []

    /// The arguments the tool gets. `nestFields` puts request fields under `request` (request_execute without an ID).
    func merged(nestFields: Bool) -> [String: JSONValue] {
        var fields = fields
        if !auth.isEmpty { fields["auth"] = .object(auth) }
        var result = root
        if nestFields {
            if !fields.isEmpty { result["request"] = .object(fields) }
        } else {
            result.merge(fields) { $1 }
        }
        if !response.isEmpty { result["response"] = .object(response) }
        return result
    }

    mutating func append(_ value: JSONValue, to key: String) {
        var items = fields[key]?.array ?? []
        items.append(value)
        fields[key] = .array(items)
    }
}

/// Reads `--body-file`: a path, or `-` for standard input.
struct CLIInput: Sendable {
    let readFile: @Sendable (String) throws -> Data
    let readStdin: @Sendable () -> Data

    func text(at path: String) throws(CLIFailure) -> String {
        if path == "-" { return String(decoding: readStdin(), as: UTF8.self) }
        guard let data = try? readFile(path) else { throw .arguments("Can't read \(path).") }
        return String(decoding: data, as: UTF8.self)
    }
}

struct Flag: Sendable {
    typealias Apply = @Sendable (inout ToolArguments, String, CLIInput) throws(CLIFailure) -> Void
    /// Without the leading `--`.
    let name: String
    /// The value's placeholder in help; nil for a switch.
    let value: String?
    let help: String
    var repeatable = false
    var short: Character?
    let apply: Apply
}

/// How a command's result is printed (without `--json`).
enum Rendering: Sendable {
    case json, collections, requests, environments, history, deleted(String), execute, tools
}

struct Command: Sendable {
    let noun: String
    let verb: String
    /// The MCP tool it calls; nil for local commands.
    let tool: String?
    let summary: String
    let usage: [String]
    let flags: [Flag]
    var rendering: Rendering = .json

    var name: String { "\(noun) \(verb)" }
}

enum CLICommands {
    // MARK: Flag builders

    private static func string(_ name: String, _ key: String, _ placeholder: String, _ help: String) -> Flag {
        Flag(name: name, value: placeholder, help: help) { args, value, _ throws(CLIFailure) in args.root[key] = .string(value) }
    }

    private static func id(_ name: String, _ key: String, _ help: String) -> Flag { string(name, key, "ID", help) }
    private static func id(help: String) -> Flag { string("id", "id", "ID", help) }

    /// `intoResponse` puts it in the recorded response (history `--status`) instead of the top level.
    private static func integer(_ name: String, _ key: String, _ help: String, intoResponse: Bool = false) -> Flag {
        Flag(name: name, value: "N", help: help) { args, value, _ throws(CLIFailure) in
            guard let number = Int(value), number >= 0 else { throw .arguments("--\(name) must be a whole number of 0 or more.") }
            if intoResponse { args.response[key] = .number(Double(number)) } else { args.root[key] = .number(Double(number)) }
        }
    }

    private static func toggle(_ name: String, _ key: String, _ value: Bool, _ help: String) -> Flag {
        Flag(name: name, value: nil, help: help) { args, _, _ throws(CLIFailure) in args.root[key] = .bool(value) }
    }

    private static func option(_ name: String, short: Character? = nil, _ help: String) -> Flag {
        Flag(name: name, value: nil, help: help, short: short) { args, _, _ throws(CLIFailure) in args.options.insert(name) }
    }

    /// `"Name: value"` (headers) or `name=value` (query parameters).
    private static func pair(_ text: String, separator: Character, flag: String) throws(CLIFailure) -> JSONValue {
        guard let index = text.firstIndex(of: separator), index != text.startIndex else {
            throw .arguments(separator == ":" ? "--\(flag) must look like \"Name: value\"." : "--\(flag) must look like name=value.")
        }
        let key = text[..<index].trimmingCharacters(in: .whitespaces)
        var value = String(text[text.index(after: index)...])
        if separator == ":" { value = value.trimmingCharacters(in: .whitespaces) }
        return .object(["key": .string(key), "value": .string(value)])
    }

    /// `--var NAME=VALUE` / `--secret NAME=VALUE`: a variable for an environment.
    private static func variable(_ name: String, secret: Bool, _ help: String) -> Flag {
        Flag(name: name, value: "NAME=VALUE", help: help, repeatable: true) { args, value, _ throws(CLIFailure) in
            guard let index = value.firstIndex(of: "="), index != value.startIndex else { throw .arguments("--\(name) must look like NAME=VALUE.") }
            var items = args.root["variables"]?.array ?? []
            items.append(
                .object([
                    "key": .string(value[..<index].trimmingCharacters(in: .whitespaces)), "value": .string(String(value[value.index(after: index)...])),
                    "secret": .bool(secret)
                ]))
            args.root["variables"] = .array(items)
        }
    }

    static let environmentColors = ["green", "orange", "red", "blue", "pink", "gray"]

    private static func color() -> Flag {
        Flag(name: "color", value: "COLOR", help: "green, orange, red, blue, pink or gray.") { args, value, _ throws(CLIFailure) in
            guard environmentColors.contains(value) else { throw .arguments("--color must be one of \(environmentColors.joined(separator: ", ")).") }
            args.root["color"] = .string(value)
        }
    }

    private static let variableFlags: [Flag] = [
        variable("var", secret: false, "A variable, used in requests as {{NAME}}; repeat for more. Replaces every saved variable."),
        variable("secret", secret: true, "A secret variable (write-only, masked, kept out of History); repeat for more.")
    ]

    // MARK: Shared flag sets

    static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
    static let bodyTypes = ["none", "json", "form-data", "urlencoded", "xml", "text"]
    static let authTypes = ["none", "bearer", "basic", "oauth2"]

    /// The request's fields, as request_create/update/execute and history_create/update take them.
    static let requestFields: [Flag] = [
        Flag(name: "name", value: "NAME", help: "Display name.") { args, value, _ throws(CLIFailure) in args.fields["name"] = .string(value) },
        Flag(name: "url", value: "URL", help: "Target URL (query parameters can also go in --query).") { args, value, _ throws(CLIFailure) in
            args.fields["url"] = .string(value)
        },
        Flag(name: "method", value: "METHOD", help: "GET, POST, PUT, PATCH, DELETE, HEAD or OPTIONS.", short: "X") { args, value, _ throws(CLIFailure) in
            guard methods.contains(value.uppercased()) else { throw .arguments("--method must be one of \(methods.joined(separator: ", ")).") }
            args.fields["method"] = .string(value.uppercased())
        },
        Flag(name: "header", value: "'NAME: VALUE'", help: "A header; repeat for more. Replaces every saved header.", repeatable: true, short: "H") {
            args, value, _ throws(CLIFailure) in args.append(try pair(value, separator: ":", flag: "header"), to: "headers")
        },
        Flag(name: "query", value: "NAME=VALUE", help: "A query parameter; repeat for more. Replaces every saved one.", repeatable: true) {
            args, value, _ throws(CLIFailure) in args.append(try pair(value, separator: "=", flag: "query"), to: "queryParams")
        },
        Flag(name: "body", value: "TEXT", help: "The body text.", short: "d") { args, value, _ throws(CLIFailure) in args.fields["body"] = .string(value) },
        Flag(name: "body-file", value: "PATH", help: "Read the body from a file, or - for standard input.") { args, value, input throws(CLIFailure) in
            args.fields["body"] = .string(try input.text(at: value))
        },
        Flag(name: "body-type", value: "TYPE", help: "none, json, form-data (fields as a=1&b=2, sent as multipart parts), urlencoded, xml or text (default json with a body).") {
            args, value, _ throws(CLIFailure) in
            guard bodyTypes.contains(value) else { throw .arguments("--body-type must be one of \(bodyTypes.joined(separator: ", ")).") }
            args.fields["bodyType"] = .string(value)
        },
        Flag(name: "bearer", value: "TOKEN", help: "Bearer token authentication.") { args, value, _ throws(CLIFailure) in
            args.auth["type"] = .string("bearer")
            args.auth["token"] = .string(value)
        },
        Flag(name: "basic", value: "USER:PASSWORD", help: "Basic authentication.", short: "u") { args, value, _ throws(CLIFailure) in
            let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            args.auth["type"] = .string("basic")
            args.auth["username"] = .string(String(parts[0]))
            if parts.count == 2 { args.auth["password"] = .string(String(parts[1])) }
        },
        Flag(name: "auth", value: "TYPE", help: "none, bearer, basic or oauth2: switch type, keeping saved credentials.") { args, value, _ throws(CLIFailure) in
            guard authTypes.contains(value) else { throw .arguments("--auth must be one of \(authTypes.joined(separator: ", ")).") }
            args.auth["type"] = .string(value)
        }
    ]

    /// A recorded response, for history_create/update.
    static let responseFields: [Flag] = [
        integer("status", "status", "The response's HTTP status.", intoResponse: true),
        Flag(name: "response-body", value: "TEXT", help: "The response body.") { args, value, _ throws(CLIFailure) in args.response["body"] = .string(value) },
        Flag(name: "response-header", value: "'NAME: VALUE'", help: "A response header; repeat for more.", repeatable: true) { args, value, _ throws(CLIFailure) in
            var items = args.response["headers"]?.array ?? []
            items.append(try pair(value, separator: ":", flag: "response-header"))
            args.response["headers"] = .array(items)
        },
        Flag(name: "content-type", value: "TYPE", help: "The response's Content-Type.") { args, value, _ throws(CLIFailure) in
            args.response["contentType"] = .string(value)
        },
        Flag(name: "time-ms", value: "MS", help: "Response time in milliseconds.") { args, value, _ throws(CLIFailure) in
            guard let number = Double(value), number.isFinite, number >= 0 else { throw .arguments("--time-ms must be a number of 0 or more.") }
            args.response["timeMs"] = .number(number)
        },
        string("error", "errorMessage", "MESSAGE", "Why the request failed (no response); empty clears it.")
    ]

    private static let maxBody = integer("max-body", "maxBodyBytes", "Longest body to return, in bytes (default 262144).")

    // MARK: Table

    static let all: [Command] = collectionCommands + requestCommands + environmentCommands + historyCommands + otherCommands

    private static let collectionCommands: [Command] = [
        Command(noun: "collection", verb: "list", tool: "collection_list", summary: "List collections with their IDs and request counts.", usage: [""], flags: [], rendering: .collections),
        Command(
            noun: "collection", verb: "get", tool: "collection_get", summary: "Show a collection and every request in it.", usage: ["--id ID [--no-requests]"],
            flags: [id(help: "Collection ID."), toggle("no-requests", "includeRequests", false, "Leave out the requests.")]),
        Command(
            noun: "collection", verb: "create", tool: "collection_create", summary: "Create an empty collection.", usage: ["--name NAME [--sort-order N]"],
            flags: [string("name", "name", "NAME", "Collection name."), integer("sort-order", "sortOrder", "Position in the sidebar.")]),
        Command(
            noun: "collection", verb: "update", tool: "collection_update", summary: "Rename or move a collection.", usage: ["--id ID [--name NAME] [--sort-order N]"],
            flags: [id(help: "Collection ID."), string("name", "name", "NAME", "New name."), integer("sort-order", "sortOrder", "Position in the sidebar.")]),
        Command(
            noun: "collection", verb: "delete", tool: "collection_delete", summary: "Delete a collection and its requests (History is kept).", usage: ["--id ID"],
            flags: [id(help: "Collection ID.")], rendering: .deleted("collection"))
    ]

    private static let executeFlags: [Flag] =
        [
            id(help: "Saved request to send."), toggle("no-history", "recordHistory", false, "Don't record it in History."), maxBody,
            string("env", "environmentId", "ID|default", "Resolve {{variables}} with this environment of the collection (default: the one it uses)."),
            id("collection", "collectionId", "For --url: the collection whose environments resolve its {{variables}}."),
            option("include", short: "i", "Print the status line and headers before the body."),
            option("fail", short: "f", "Exit with status 22 when the response status is 400 or more."),
            option("text", "For a streamed LLM reply, print the text its events assemble to instead of the raw stream.")
        ] + requestFields

    private static let requestCreateFlags: [Flag] = [id("collection", "collectionId", "Collection to add it to.")] + requestFields
    private static let requestUpdateFlags: [Flag] = [id(help: "Request ID."), id("collection", "collectionId", "Move it to this collection.")] + requestFields

    private static let requestCommands: [Command] = [
        Command(
            noun: "request", verb: "list", tool: "request_list", summary: "List saved requests, in one collection or all.", usage: ["[--collection ID]"],
            flags: [id("collection", "collectionId", "Only this collection's requests.")], rendering: .requests),
        Command(noun: "request", verb: "get", tool: "request_get", summary: "Show a saved request.", usage: ["--id ID"], flags: [id(help: "Request ID.")]),
        Command(
            noun: "request", verb: "create", tool: "request_create",
            summary: "Save a new request (in the first collection unless --collection).", usage: ["[--collection ID] --url URL [request fields]"],
            flags: requestCreateFlags),
        Command(
            noun: "request", verb: "update", tool: "request_update", summary: "Change a saved request; only the given fields change.",
            usage: ["--id ID [--collection ID] [request fields]"],
            flags: requestUpdateFlags),
        Command(
            noun: "request", verb: "delete", tool: "request_delete", summary: "Delete a saved request (History is kept).", usage: ["--id ID"], flags: [id(help: "Request ID.")],
            rendering: .deleted("request")),
        Command(
            noun: "request", verb: "execute", tool: "request_execute",
            summary: "Send a saved request (--id) or an ad-hoc one (--url) and print the response body; it is recorded in History.",
            usage: ["--id ID [output options]", "--url URL [request fields] [output options]"],
            flags: executeFlags, rendering: .execute)
    ]

    private static let environmentCommands: [Command] = [
        Command(
            noun: "environment", verb: "list", tool: "environment_list", summary: "List a collection's environments, Default first.", usage: ["--collection ID"],
            flags: [id("collection", "collectionId", "Collection ID.")], rendering: .environments),
        Command(
            noun: "environment", verb: "get", tool: "environment_get", summary: "Show an environment and its variables (secret values hidden).", usage: ["--id ID"],
            flags: [id(help: "Environment ID.")]),
        Command(
            noun: "environment", verb: "create", tool: "environment_create", summary: "Add an environment that overrides the collection's Default.",
            usage: ["--collection ID --name NAME [--var NAME=VALUE …] [--secret NAME=VALUE …] [--color COLOR] [--select]"],
            flags: [id("collection", "collectionId", "Collection ID."), string("name", "name", "NAME", "Environment name, such as Staging."), color()] + variableFlags + [
                toggle("select", "select", true, "Make the collection's requests use it.")
            ]),
        Command(
            noun: "environment", verb: "update", tool: "environment_update", summary: "Change an environment; --var/--secret replace all its variables.",
            usage: ["--id ID [--name NAME] [--color COLOR] [--var NAME=VALUE …] [--secret NAME=VALUE …]"],
            flags: [id(help: "Environment ID."), string("name", "name", "NAME", "New name (not for Default)."), color()] + variableFlags),
        Command(
            noun: "environment", verb: "delete", tool: "environment_delete", summary: "Delete an environment (not Default).", usage: ["--id ID"],
            flags: [id(help: "Environment ID.")], rendering: .deleted("environment")),
        Command(
            noun: "environment", verb: "select", tool: "environment_select", summary: "Choose the environment a collection's requests use.",
            usage: ["--collection ID [--id ID|default]"],
            flags: [id("collection", "collectionId", "Collection ID."), string("id", "environmentId", "ID|default", "Environment ID, or default (the default) for Default only.")])
    ]

    private static let historyCreateFlags: [Flag] =
        [id("request", "requestId", "The saved request it belongs to."), string("timestamp", "timestamp", "DATE", "When it was sent, ISO 8601 (default now).")]
        + requestFields + responseFields
    private static let historyUpdateFlags: [Flag] = [id(help: "History entry ID.")] + requestFields + responseFields

    private static let historyCommands: [Command] = [
        Command(
            noun: "history", verb: "list", tool: "history_list", summary: "List History, newest first.", usage: ["[--limit N] [--offset N] [--request ID]"],
            flags: [
                integer("limit", "limit", "Entries to show (default 50, at most 500)."), integer("offset", "offset", "Entries to skip."),
                id("request", "requestId", "Only entries sent from this saved request.")
            ], rendering: .history),
        Command(
            noun: "history", verb: "get", tool: "history_get", summary: "Show a History entry: the request sent and the response.", usage: ["--id ID [--max-body N]"],
            flags: [id(help: "History entry ID."), maxBody]),
        Command(
            noun: "history", verb: "create", tool: "history_create", summary: "Add a History entry without sending anything.",
            usage: ["--url URL [request fields] [--status N --response-body TEXT …] [--timestamp DATE] [--request ID]"],
            flags: historyCreateFlags),
        Command(
            noun: "history", verb: "update", tool: "history_update", summary: "Change a History entry; only the given fields change.",
            usage: ["--id ID [request fields] [response fields]"], flags: historyUpdateFlags),
        Command(
            noun: "history", verb: "delete", tool: "history_delete", summary: "Delete a History entry.", usage: ["--id ID"], flags: [id(help: "History entry ID.")],
            rendering: .deleted("history entry")),
        Command(
            noun: "history", verb: "clear", tool: "history_clear", summary: "Delete every History entry, or one saved request's.", usage: ["[--request ID]"],
            flags: [id("request", "requestId", "Only this saved request's entries.")], rendering: .deleted("history entry"))
    ]

    private static let otherCommands: [Command] = [
        Command(
            noun: "tools", verb: "list", tool: nil, summary: "List the MCP tools the app offers.", usage: [""], flags: [], rendering: .tools),
        Command(
            noun: "call", verb: "tool", tool: nil, summary: "Call any MCP tool with raw JSON arguments.", usage: ["TOOL [--args JSON]"],
            flags: [string("args", "args", "JSON", "The tool's arguments as a JSON object (default {}).")]),
        Command(
            noun: "cli", verb: "install-link", tool: nil, summary: "Link this command into a directory on your PATH (local; needs no app).",
            usage: ["[--directory DIR] [--force]"],
            flags: [string("directory", "directory", "DIR", "Where to put the postwoman link (default ~/.local/bin)."), option("force", "Replace another link there.")]),
        Command(
            noun: "cli", verb: "remove-link", tool: nil, summary: "Remove the link install-link made (local).", usage: ["[--directory DIR]"],
            flags: [string("directory", "directory", "DIR", "Where the link is (default ~/.local/bin).")])
    ]

    static func command(_ noun: String, _ verb: String) -> Command? { all.first { $0.noun == noun && $0.verb == verb } }
    static var nouns: [String] {
        var seen: [String] = []
        for command in all where !seen.contains(command.noun) { seen.append(command.noun) }
        return seen
    }
}

/// Global options, accepted anywhere on the line.
struct GlobalOptions: Equatable, Sendable {
    var server: String?
    var token: String?
    var tokenFile: String?
    var json = false
}

enum CLIRequest: Sendable {
    case help(noun: String?, verb: String?)
    case version
    case run(Command, ToolArguments, GlobalOptions, positional: String?)
}

enum CLIArguments {
    static func parse(_ arguments: [String], input: CLIInput) throws(CLIFailure) -> CLIRequest {
        var global = GlobalOptions()
        var words: [String] = []
        var rest: [String] = []
        var wantsHelp = false
        var index = 0
        // Globals first, wherever they appear; everything else keeps its order.
        while index < arguments.count {
            var argument = arguments[index]
            // `--server=URL`, as every command flag can be written.
            var inline: String?
            if let equals = argument.firstIndex(of: "="), ["--server", "--agent-token", "--agent-token-file"].contains(String(argument[..<equals])) {
                inline = String(argument[argument.index(after: equals)...])
                argument = String(argument[..<equals])
            }
            func next() throws(CLIFailure) -> String {
                if let inline { return inline }
                index += 1
                guard index < arguments.count else { throw .arguments("\(argument) needs a value.") }
                return arguments[index]
            }
            switch argument {
            case "--json": global.json = true
            case "--help", "-h": wantsHelp = true
            case "--version":
                if words.isEmpty, rest.isEmpty { return .version }
                rest.append(argument)
            case "--server": global.server = try next()
            case "--agent-token": global.token = try next()
            case "--agent-token-file": global.tokenFile = try next()
            default:
                if argument.hasPrefix("-") || !rest.isEmpty || words.count >= 2 { rest.append(argument) } else { words.append(argument) }
            }
            index += 1
        }
        if words.first == "help" {
            let topic = Array(words.dropFirst()) + rest
            return .help(noun: topic.first, verb: topic.dropFirst().first)
        }
        guard let noun = words.first else {
            // Not the overview with exit 0: a script with a misplaced or mistyped option must not look as if it had run.
            if !wantsHelp, let stray = rest.first { throw .arguments("Unknown option \(stray) before the command. Options go after it: postwoman NOUN VERB [options].") }
            return .help(noun: nil, verb: nil)
        }
        if noun == "tools", words.count == 1 { words.append("list") }
        // `call TOOL`: the tool name is the second word.
        var positional: String?
        if noun == "call" {
            if wantsHelp { return .help(noun: "call", verb: nil) }
            guard words.count == 2 else { throw .arguments("Name the tool: postwoman call TOOL [--args JSON].") }
            positional = words[1]
            words[1] = "tool"
        }
        guard CLICommands.nouns.contains(noun) else { throw .arguments("Unknown command \(noun).") }
        if wantsHelp { return .help(noun: noun, verb: words.count > 1 ? words[1] : nil) }
        guard words.count == 2 else { throw .arguments("Say what to do with \(noun): \(verbs(noun)).") }
        guard let command = CLICommands.command(noun, words[1]) else { throw .arguments("Unknown command \(noun) \(words[1]). Try \(verbs(noun)).") }
        return .run(command, try flags(rest, command: command, input: input), global, positional: positional)
    }

    private static func verbs(_ noun: String) -> String { CLICommands.all.filter { $0.noun == noun }.map(\.verb).joined(separator: ", ") }

    static func flags(_ arguments: [String], command: Command, input: CLIInput) throws(CLIFailure) -> ToolArguments {
        var result = ToolArguments()
        var seen: Set<String> = []
        var index = 0
        while index < arguments.count {
            var argument = arguments[index]
            var inline: String?
            if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                inline = String(argument[argument.index(after: equals)...])
                argument = String(argument[..<equals])
            }
            let flag: Flag?
            if argument.hasPrefix("--") {
                flag = command.flags.first { $0.name == argument.dropFirst(2) }
            } else if argument.count == 2, argument.hasPrefix("-") {
                flag = command.flags.first { $0.short == argument.last }
            } else {
                throw .arguments("Unexpected \(argument) for \(command.name).")
            }
            guard let flag else { throw .arguments("\(command.name) has no option \(argument).") }
            guard flag.repeatable || !seen.contains(flag.name) else { throw .arguments("--\(flag.name) is given twice.") }
            seen.insert(flag.name)
            var value = ""
            if flag.value != nil {
                if let inline {
                    value = inline
                } else {
                    index += 1
                    guard index < arguments.count else { throw .arguments("--\(flag.name) needs a value (\(flag.value!)).") }
                    value = arguments[index]
                }
            } else if inline != nil {
                throw .arguments("--\(flag.name) takes no value.")
            }
            try flag.apply(&result, value, input)
            index += 1
        }
        if seen.contains("body"), seen.contains("body-file") { throw .arguments("Pass --body or --body-file, not both.") }
        return result
    }
}
