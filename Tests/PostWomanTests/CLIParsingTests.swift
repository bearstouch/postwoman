import Foundation
import XCTest

@testable import PostWomanCLI

/// `--body-file` reads only /tmp/body.json; `-` reads "piped".
private let parsingInput = CLIInput(
    readFile: { path in
        guard path == "/tmp/body.json" else { throw CocoaError(.fileNoSuchFile) }
        return Data(#"{"from":"file"}"#.utf8)
    }, readStdin: { Data("piped".utf8) })

private func parse(_ words: [String]) throws(CLIFailure) -> CLIRequest { try CLIArguments.parse(words, input: parsingInput) }

/// What the parse produced, as one comparable line.
private func describe(_ request: CLIRequest) -> String {
    switch request {
    case .help(let noun, let verb): "help \(noun ?? "-") \(verb ?? "-")"
    case .version: "version"
    case .run(let command, _, _, let positional): "run \(command.name)" + (positional.map { " \($0)" } ?? "")
    }
}

private func outcome(_ words: [String]) -> String {
    do { return describe(try parse(words)) } catch { return "error: \(error.message)" }
}

private func message(_ words: [String]) -> String? {
    do {
        _ = try parse(words)
        return nil
    } catch {
        XCTAssertEqual(error.code, "INVALID_ARGUMENTS", "\(words)")
        XCTAssertEqual(error.exitStatus, 2, "\(words)")
        return error.message
    }
}

private func parsed(_ words: [String]) throws -> (command: Command, arguments: ToolArguments, global: GlobalOptions, positional: String?) {
    guard case .run(let command, let arguments, let global, let positional) = try parse(words) else { throw CLIFailure.arguments("\(words) is not a run") }
    return (command, arguments, global, positional)
}

private func built(_ words: [String], nest: Bool = false) throws -> [String: JSONValue] { try parsed(words).arguments.merged(nestFields: nest) }

/// A value each flag accepts.
private func sample(_ flag: Flag) -> String {
    let samples = [
        "method": "GET", "body-type": "json", "auth": "bearer", "basic": "u:p", "header": "A: b", "response-header": "A: b", "query": "a=b", "time-ms": "1",
        "var": "a=b", "secret": "a=b", "color": "green", "body-file": "/tmp/body.json"
    ]
    return samples[flag.name] ?? (flag.value == "N" ? "1" : "x")
}

/// The words that name a command (`call` takes the tool name in place of its verb).
private func prefix(_ command: Command) -> [String] { command.noun == "call" ? ["call", "some_tool"] : [command.noun, command.verb] }

private func pair(_ key: String, _ value: String) -> JSONValue { .object(["key": .string(key), "value": .string(value)]) }

final class CLIParsingTests: XCTestCase {
    // MARK: Commands

    func testGlobalOptionsAcceptTheEqualsSpellingToo() throws {
        let global = try parsed(["collection", "list", "--server=http://h:1/mcp?x=1", "--agent-token=pwm=x", "--agent-token-file=/tmp/f"]).global
        XCTAssertEqual(global.server, "http://h:1/mcp?x=1")
        XCTAssertEqual(global.token, "pwm=x", "Split at the first = only")
        XCTAssertEqual(global.tokenFile, "/tmp/f")
        XCTAssertEqual(try parsed(["--server=", "collection", "list"]).global.server, "")
    }

    func testAnOptionBeforeTheCommandIsAnErrorNotTheOverview() {
        // It used to print the overview and exit 0, so a script with a misplaced flag "succeeded" without doing anything.
        XCTAssertEqual(
            message(["-X", "POST", "request", "execute", "--url", "http://x"]), "Unknown option -X before the command. Options go after it: postwoman NOUN VERB [options].")
        XCTAssertEqual(message(["--jsno", "collection", "list"]), "Unknown option --jsno before the command. Options go after it: postwoman NOUN VERB [options].")
        XCTAssertEqual(message(["--nope"]), "Unknown option --nope before the command. Options go after it: postwoman NOUN VERB [options].")
        XCTAssertEqual(message(["collection", "list", "--version"]), "collection list has no option --version.")
        // Still fine: nothing at all, help, the version, and global options before the command.
        for words in [[], ["--help"], ["-h"], ["--nope", "--help"], ["--json"]] {
            guard case .help(nil, nil)? = try? parse(words) else { return XCTFail("\(words) shows the overview") }
        }
        guard case .version? = try? parse(["--version"]) else { return XCTFail("--version prints the version") }
        XCTAssertNoThrow(try parsed(["--json", "--server", "h:1", "collection", "list"]))
    }

    func testEveryCommandParsesFromItsWords() {
        for command in CLICommands.all {
            let expected = command.noun == "call" ? "run call tool some_tool" : "run \(command.name)"
            XCTAssertEqual(outcome(prefix(command)), expected)
        }
        XCTAssertEqual(outcome(["tools"]), "run tools list", "tools alone lists them")
    }

    func testUnknownAndIncompleteCommandsListWhatExists() {
        let cases: [([String], String)] = [
            (["nope"], "Unknown command nope."), (["nope", "list"], "Unknown command nope."), (["Request", "list"], "Unknown command Request."),
            (["request"], "Say what to do with request: list, get, create, update, delete, execute."),
            (["collection"], "Say what to do with collection: list, get, create, update, delete."),
            (["environment"], "Say what to do with environment: list, get, create, update, delete, select."),
            (["history"], "Say what to do with history: list, get, create, update, delete, clear."),
            (["cli"], "Say what to do with cli: install-link, remove-link."),
            (["request", "nope"], "Unknown command request nope. Try list, get, create, update, delete, execute."),
            (["tools", "nope"], "Unknown command tools nope. Try list."),
            (["call"], "Name the tool: postwoman call TOOL [--args JSON]."), (["--json", "call", "--args", "{}"], "Name the tool: postwoman call TOOL [--args JSON].")
        ]
        for (words, expected) in cases { XCTAssertEqual(message(words), expected, "\(words)") }
    }

    func testStrayWordsAndMalformedFlagsAreRejected() {
        let cases: [([String], String)] = [
            (["collection", "list", "stray"], "Unexpected stray for collection list."), (["request", "get", "--id", "a", "b"], "Unexpected b for request get."),
            (["call", "a", "b"], "Unexpected b for call tool."), (["request", "execute", "-if"], "Unexpected -if for request execute."),
            (["request", "create", "-XPOST"], "Unexpected -XPOST for request create."), (["request", "create", "-"], "Unexpected - for request create.")
        ]
        for (words, expected) in cases { XCTAssertEqual(message(words), expected, "\(words)") }
    }

    func testUnknownFlagsNameTheCommand() {
        XCTAssertEqual(message(["request", "execute", "--nope"]), "request execute has no option --nope.")
        XCTAssertEqual(message(["request", "execute", "--nope=1"]), "request execute has no option --nope.", "The inline value is not part of the name")
        XCTAssertEqual(message(["request", "execute", "-z"]), "request execute has no option -z.")
        XCTAssertEqual(message(["request", "get", "-X", "GET"]), "request get has no option -X.", "Short flags belong to their command")
        XCTAssertEqual(message(["collection", "list", "--id", "C"]), "collection list has no option --id.")
        XCTAssertEqual(message(["request", "get", "--ID", "x"]), "request get has no option --ID.", "Flags are case-sensitive")
    }

    // MARK: Every flag

    func testEveryFlagAcceptsBothSpellingsAndItsShortForm() throws {
        for command in CLICommands.all {
            for flag in command.flags where flag.value != nil {
                let value = sample(flag)
                let separate = try parsed(prefix(command) + ["--\(flag.name)", value]).arguments
                let inline = try parsed(prefix(command) + ["--\(flag.name)=\(value)"]).arguments
                XCTAssertEqual(separate.merged(nestFields: false), inline.merged(nestFields: false), "\(command.name) --\(flag.name)")
                XCTAssertFalse(separate.merged(nestFields: false).isEmpty, "\(command.name) --\(flag.name) builds something")
                if let short = flag.short {
                    let shortForm = try parsed(prefix(command) + ["-\(short)", value]).arguments
                    XCTAssertEqual(shortForm.merged(nestFields: false), separate.merged(nestFields: false), "\(command.name) -\(short)")
                }
            }
        }
    }

    func testSwitchesTakeNoValue() throws {
        for command in CLICommands.all {
            for flag in command.flags where flag.value == nil {
                XCTAssertNoThrow(try parsed(prefix(command) + ["--\(flag.name)"]), "\(command.name) --\(flag.name)")
                XCTAssertEqual(message(prefix(command) + ["--\(flag.name)=yes"]), "--\(flag.name) takes no value.", "\(command.name)")
                XCTAssertEqual(message(prefix(command) + ["--\(flag.name)="]), "--\(flag.name) takes no value.", "\(command.name)")
            }
        }
    }

    func testAMissingValueNamesItsPlaceholder() {
        for command in CLICommands.all {
            for flag in command.flags {
                guard let placeholder = flag.value else { continue }
                XCTAssertEqual(message(prefix(command) + ["--\(flag.name)"]), "--\(flag.name) needs a value (\(placeholder)).", "\(command.name)")
                if let short = flag.short { XCTAssertEqual(message(prefix(command) + ["-\(short)"]), "--\(flag.name) needs a value (\(placeholder)).") }
            }
        }
    }

    func testAFlagGivenTwiceIsRejectedUnlessRepeatable() throws {
        for command in CLICommands.all {
            for flag in command.flags {
                let once = flag.value == nil ? ["--\(flag.name)"] : ["--\(flag.name)", sample(flag)]
                if flag.repeatable {
                    XCTAssertNoThrow(try parsed(prefix(command) + once + once), "\(command.name) --\(flag.name)")
                } else {
                    XCTAssertEqual(message(prefix(command) + once + once), "--\(flag.name) is given twice.", "\(command.name)")
                }
            }
        }
        XCTAssertEqual(message(["request", "create", "-X", "GET", "--method", "POST"]), "--method is given twice.", "A short and a long spelling are the same flag")
        XCTAssertEqual(message(["request", "create", "--name=a", "--name", "b"]), "--name is given twice.")
    }

    func testRepeatableFlagsKeepTheirOrder() throws {
        let request = try built(["request", "create", "-H", "B: 2", "--query", "z=1", "-H", "A: 1", "--header=C: 3", "--query", "a=2"])
        XCTAssertEqual(request["headers"], .array([pair("B", "2"), pair("A", "1"), pair("C", "3")]))
        XCTAssertEqual(request["queryParams"], .array([pair("z", "1"), pair("a", "2")]))

        let environment = try built(["environment", "update", "--id", "E", "--secret", "s=1", "--var", "v=2", "--secret", "t=3"])
        XCTAssertEqual(
            environment["variables"]?.array?.map { "\($0["key"]?.string ?? "")=\($0["secret"] == .bool(true))" }, ["s=true", "v=false", "t=true"],
            "--var and --secret share one list, in the order given")

        let history = try built(["history", "update", "--id", "H", "--response-header", "X: 1", "--response-header", "Y: 2"])
        XCTAssertEqual(history["response"]?["headers"], .array([pair("X", "1"), pair("Y", "2")]))
    }

    // MARK: Values

    func testValuesThatLookLikeFlagsAreTakenAsValues() throws {
        XCTAssertEqual(try built(["request", "create", "--name", "-X"])["name"], .string("-X"))
        XCTAssertEqual(try built(["request", "create", "-d", "--url"])["body"], .string("--url"))
        XCTAssertEqual(try built(["request", "create", "--body", "-"])["body"], .string("-"), "Only --body-file reads - as stdin")
        let inline = try parsed(["request", "create", "--name=--json"])
        XCTAssertEqual(inline.arguments.fields["name"], .string("--json"))
        XCTAssertFalse(inline.global.json, "An inline value is never a global option")
        // Global options are taken wherever they appear, even where a value was expected.
        XCTAssertEqual(message(["request", "create", "--name", "--json"]), "--name needs a value (NAME).")
        XCTAssertEqual(outcome(["request", "create", "--name", "--help"]), "help request create")
    }

    func testEmptyValuesAreKept() throws {
        XCTAssertEqual(try built(["request", "create", "--name", ""])["name"], .string(""))
        XCTAssertEqual(try built(["request", "create", "--name="])["name"], .string(""))
        XCTAssertEqual(try built(["request", "create", "-H", "X-Empty:"])["headers"], .array([pair("X-Empty", "")]))
        XCTAssertEqual(try built(["request", "create", "--query", "flag="])["queryParams"], .array([pair("flag", "")]))
        XCTAssertEqual(try built(["history", "update", "--id", "H", "--error", ""])["errorMessage"], .string(""), "An empty --error clears it")
        XCTAssertEqual(try built(["environment", "update", "--id", "E", "--var", "k="])["variables"]?.array?.first?["value"], .string(""))
        XCTAssertEqual(message(["request", "create", "-X", ""]), "--method must be one of GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS.")
        XCTAssertEqual(message(["history", "list", "--limit", ""]), "--limit must be a whole number of 0 or more.")
    }

    func testAnInlineValueSplitsAtTheFirstEqualsSign() throws {
        XCTAssertEqual(try built(["request", "get", "--id=a=b"])["id"], .string("a=b"))
        XCTAssertEqual(try built(["request", "create", "--query=a=b=c"])["queryParams"], .array([pair("a", "b=c")]))
        XCTAssertEqual(try built(["call", "t", #"--args={"a":"="}"#])["args"], .string(#"{"a":"="}"#))
    }

    func testMethodsAreCaseInsensitiveAndSentUppercase() throws {
        for (given, sent) in [("get", "GET"), ("post", "POST"), ("Put", "PUT"), ("patch", "PATCH"), ("DELETE", "DELETE"), ("Head", "HEAD"), ("options", "OPTIONS")] {
            XCTAssertEqual(try built(["request", "create", "-X", given])["method"], .string(sent))
        }
        for rejected in ["TRACE", "CONNECT", "GET "] {
            XCTAssertEqual(message(["request", "create", "--method", rejected]), "--method must be one of GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS.", rejected)
        }
    }

    func testHeadersSplitAtTheFirstColonAndTrimSpaces() throws {
        let cases: [(String, JSONValue)] = [
            ("Accept: application/json", pair("Accept", "application/json")), ("  X-Id  :  7  ", pair("X-Id", "7")), ("A:b:c", pair("A", "b:c")),
            ("X: a  b", pair("X", "a  b")), ("Host:localhost:8080", pair("Host", "localhost:8080")), ("X-Emoji: 🍕 café", pair("X-Emoji", "🍕 café"))
        ]
        for (given, expected) in cases { XCTAssertEqual(try built(["request", "create", "-H", given])["headers"], .array([expected]), given) }
        for rejected in ["no colon", ":value", ""] {
            XCTAssertEqual(message(["request", "create", "-H", rejected]), "--header must look like \"Name: value\".", rejected)
            XCTAssertEqual(message(["history", "update", "--id", "H", "--response-header", rejected]), "--response-header must look like \"Name: value\".")
        }
    }

    func testQueryParametersTrimTheNameButKeepTheValueAsWritten() throws {
        XCTAssertEqual(try built(["request", "create", "--query", " q = a b "])["queryParams"], .array([pair("q", " a b ")]))
        XCTAssertEqual(try built(["request", "create", "--query", "redirect=https://x.test/?a=1&b=2"])["queryParams"], .array([pair("redirect", "https://x.test/?a=1&b=2")]))
        for rejected in ["=v", "novalue", ""] { XCTAssertEqual(message(["request", "create", "--query", rejected]), "--query must look like name=value.", rejected) }
    }

    func testBasicAuthSplitsAtTheFirstColon() throws {
        let cases: [(String, JSONValue)] = [
            ("ada", .object(["type": .string("basic"), "username": .string("ada")])),
            ("ada:", .object(["type": .string("basic"), "username": .string("ada"), "password": .string("")])),
            (":pw", .object(["type": .string("basic"), "username": .string(""), "password": .string("pw")])),
            ("ada:pa:ss", .object(["type": .string("basic"), "username": .string("ada"), "password": .string("pa:ss")]))
        ]
        for (given, expected) in cases { XCTAssertEqual(try built(["request", "create", "-u", given])["auth"], expected, given) }
    }

    func testAuthFlagsBuildOneAuthObject() throws {
        XCTAssertEqual(try built(["request", "create", "--bearer", "t"])["auth"], .object(["type": .string("bearer"), "token": .string("t")]))
        XCTAssertEqual(
            try built(["request", "create", "--bearer", "t", "--auth", "none"])["auth"], .object(["type": .string("none"), "token": .string("t")]),
            "--auth switches the type; the flags apply in order")
        for type in CLICommands.authTypes { XCTAssertEqual(try built(["request", "update", "--id", "R", "--auth", type])["auth"], .object(["type": .string(type)])) }
        XCTAssertEqual(message(["request", "create", "--auth", "digest"]), "--auth must be one of none, bearer, basic, oauth2.")
        XCTAssertNil(try built(["request", "create", "--name", "n"])["auth"], "No auth flag, no auth key")
    }

    func testChoicesAreCheckedAndListed() throws {
        for type in CLICommands.bodyTypes { XCTAssertEqual(try built(["request", "create", "--body-type", type])["bodyType"], .string(type)) }
        XCTAssertEqual(message(["request", "create", "--body-type", "yaml"]), "--body-type must be one of none, json, form-data, urlencoded, xml, text.")
        XCTAssertEqual(message(["request", "create", "--body-type", "JSON"]), "--body-type must be one of none, json, form-data, urlencoded, xml, text.", "Case-sensitive")
        for color in CLICommands.environmentColors { XCTAssertEqual(try built(["environment", "update", "--id", "E", "--color", color])["color"], .string(color)) }
        XCTAssertEqual(message(["environment", "create", "--color", "purple"]), "--color must be one of green, orange, red, blue, pink, gray.")
    }

    func testWholeNumberFlagsAcceptOnlyZeroOrMore() throws {
        for (given, expected) in [("0", 0.0), ("7", 7), ("500", 500), ("+5", 5)] {
            XCTAssertEqual(try built(["history", "list", "--limit", given])["limit"], .number(expected), given)
        }
        for rejected in ["-1", "1.5", "abc", " 1", "1e3", "99999999999999999999"] {
            XCTAssertEqual(message(["history", "list", "--offset", rejected]), "--offset must be a whole number of 0 or more.", rejected)
        }
        XCTAssertEqual(try built(["collection", "create", "--name", "n", "--sort-order", "3"])["sortOrder"], .number(3))
        XCTAssertEqual(try built(["history", "get", "--id", "H", "--max-body", "1024"])["maxBodyBytes"], .number(1024))
        XCTAssertEqual(try built(["history", "update", "--id", "H", "--status", "404"])["response"], .object(["status": .number(404)]), "--status goes in the response")
    }

    func testResponseTimeAcceptsFractions() throws {
        XCTAssertEqual(try built(["history", "update", "--id", "H", "--time-ms", "12.5"])["response"]?["timeMs"], .number(12.5))
        XCTAssertEqual(try built(["history", "update", "--id", "H", "--time-ms", "0"])["response"]?["timeMs"], .number(0))
        for rejected in ["-0.1", "fast", ""] {
            XCTAssertEqual(message(["history", "update", "--id", "H", "--time-ms", rejected]), "--time-ms must be a number of 0 or more.", rejected)
        }
    }

    func testResponseTimeMustBeFinite() {
        for rejected in ["inf", "infinity", "1e400", "nan"] {
            XCTAssertEqual(message(["history", "update", "--id", "H", "--time-ms", rejected]), "--time-ms must be a number of 0 or more.", rejected)
        }
    }

    func testVariablesSplitAtTheFirstEqualsSign() throws {
        let variables = try built(["environment", "create", "--var", " base = https://x.test/?a=b", "--secret", "token=a=b"])["variables"]
        XCTAssertEqual(
            variables,
            .array([
                .object(["key": .string("base"), "value": .string(" https://x.test/?a=b"), "secret": .bool(false)]),
                .object(["key": .string("token"), "value": .string("a=b"), "secret": .bool(true)])
            ]))
        XCTAssertEqual(message(["environment", "create", "--var", "=v"]), "--var must look like NAME=VALUE.")
        XCTAssertEqual(message(["environment", "create", "--secret", "novalue"]), "--secret must look like NAME=VALUE.")
    }

    func testBodyComesFromTheFlagAFileOrStandardInput() throws {
        XCTAssertEqual(try built(["request", "create", "-d", #"{"a":1}"#])["body"], .string(#"{"a":1}"#))
        XCTAssertEqual(try built(["request", "create", "--body-file", "/tmp/body.json"])["body"], .string(#"{"from":"file"}"#))
        XCTAssertEqual(try built(["request", "create", "--body-file", "-"])["body"], .string("piped"))
        XCTAssertEqual(try built(["request", "create", "--body-file=-"])["body"], .string("piped"))
        XCTAssertEqual(message(["request", "create", "--body-file", "/missing.json"]), "Can't read /missing.json.")
        XCTAssertEqual(message(["request", "create", "-d", "a", "--body-file", "-"]), "Pass --body or --body-file, not both.")
        XCTAssertEqual(message(["request", "create", "--body-file", "-", "--body", "a"]), "Pass --body or --body-file, not both.")
    }

    func testTogglesSendFixedValuesAndOutputOptionsStayLocal() throws {
        XCTAssertEqual(try built(["collection", "get", "--id", "C", "--no-requests"]), ["id": .string("C"), "includeRequests": .bool(false)])
        XCTAssertEqual(try built(["environment", "create", "--select"])["select"], .bool(true))
        let execute = try parsed(["request", "execute", "--id", "R", "--no-history", "-i", "-f", "--text"])
        XCTAssertEqual(execute.arguments.merged(nestFields: false), ["id": .string("R"), "recordHistory": .bool(false)], "include, fail and text never reach the tool")
        XCTAssertEqual(execute.arguments.options, ["include", "fail", "text"])
        XCTAssertEqual(try parsed(["cli", "install-link", "--force"]).arguments.options, ["force"])
    }

    func testEveryCommandBuildsTheToolsArgumentNames() throws {
        let cases: [([String], [String: JSONValue])] = [
            (["collection", "create", "--name", "N", "--sort-order", "2"], ["name": .string("N"), "sortOrder": .number(2)]),
            (["collection", "update", "--id", "C", "--name", "N"], ["id": .string("C"), "name": .string("N")]),
            (["collection", "delete", "--id", "C"], ["id": .string("C")]), (["request", "list", "--collection", "C"], ["collectionId": .string("C")]),
            (["request", "update", "--id", "R", "--collection", "C", "--url", "u"], ["id": .string("R"), "collectionId": .string("C"), "url": .string("u")]),
            (["request", "execute", "--id", "R", "--env", "default", "--max-body", "10"], ["id": .string("R"), "environmentId": .string("default"), "maxBodyBytes": .number(10)]),
            (["environment", "list", "--collection", "C"], ["collectionId": .string("C")]),
            (["environment", "select", "--collection", "C", "--id", "default"], ["collectionId": .string("C"), "environmentId": .string("default")]),
            (["history", "list", "--limit", "5", "--offset", "10", "--request", "R"], ["limit": .number(5), "offset": .number(10), "requestId": .string("R")]),
            (["history", "clear", "--request", "R"], ["requestId": .string("R")]),
            (["history", "create", "--url", "u", "--timestamp", "2026-11-27T10:00:00Z"], ["url": .string("u"), "timestamp": .string("2026-11-27T10:00:00Z")]),
            (["cli", "install-link", "--directory", "/opt/bin"], ["directory": .string("/opt/bin")]), (["collection", "list"], [:])
        ]
        for (words, expected) in cases { XCTAssertEqual(try built(words), expected, "\(words)") }
    }

    func testHistoryResponseFieldsGoUnderResponse() throws {
        let arguments = try built([
            "history", "create", "--url", "https://x.test", "-X", "post", "--status", "201", "--response-body", "{}", "--response-header", "A: b", "--content-type",
            "application/json", "--time-ms", "5", "--error", "boom", "--request", "R"
        ])
        XCTAssertEqual(
            arguments,
            [
                "url": .string("https://x.test"), "method": .string("POST"), "errorMessage": .string("boom"), "requestId": .string("R"),
                "response": .object([
                    "status": .number(201), "body": .string("{}"), "headers": .array([pair("A", "b")]), "contentType": .string("application/json"), "timeMs": .number(5)
                ])
            ])
    }

    func testMergingNestsRequestFieldsOnlyWhenAsked() {
        var arguments = ToolArguments()
        arguments.root = ["id": .string("R"), "name": .string("root")]
        arguments.fields = ["url": .string("u"), "name": .string("field")]
        arguments.auth = ["type": .string("bearer")]
        XCTAssertEqual(
            arguments.merged(nestFields: false), ["id": .string("R"), "name": .string("field"), "url": .string("u"), "auth": .object(["type": .string("bearer")])],
            "Fields win over root keys of the same name")
        XCTAssertEqual(
            arguments.merged(nestFields: true),
            ["id": .string("R"), "name": .string("root"), "request": .object(["url": .string("u"), "name": .string("field"), "auth": .object(["type": .string("bearer")])])])

        var authOnly = ToolArguments()
        authOnly.auth = ["type": .string("none")]
        XCTAssertEqual(authOnly.merged(nestFields: true), ["request": .object(["auth": .object(["type": .string("none")])])])
        XCTAssertEqual(ToolArguments().merged(nestFields: true), [:], "Nothing to nest, no request key")
    }

    // MARK: Global options

    func testGlobalOptionsAreTakenAnywhereOnTheLine() throws {
        let forms: [[String]] = [
            ["--json", "--server", "s", "--agent-token", "t", "--agent-token-file", "f", "request", "get", "--id", "R"],
            ["request", "--json", "--server", "s", "get", "--agent-token", "t", "--id", "R", "--agent-token-file", "f"],
            ["request", "get", "--id", "R", "--agent-token-file", "f", "--agent-token", "t", "--server", "s", "--json"]
        ]
        for words in forms {
            let run = try parsed(words)
            XCTAssertEqual(run.command.name, "request get", "\(words)")
            XCTAssertEqual(run.global, GlobalOptions(server: "s", token: "t", tokenFile: "f", json: true), "\(words)")
            XCTAssertEqual(run.arguments.merged(nestFields: false), ["id": .string("R")], "\(words)")
        }
        XCTAssertEqual(try parsed(["collection", "list"]).global, GlobalOptions())
        XCTAssertEqual(try parsed(["--server", "a", "collection", "list", "--server", "b"]).global.server, "b", "The last one wins")
    }

    func testGlobalOptionsWithoutAValueAreRejected() {
        for option in ["--server", "--agent-token", "--agent-token-file"] {
            XCTAssertEqual(message(["collection", "list", option]), "\(option) needs a value.")
        }
    }

    func testVersionAndHelpForms() {
        let cases: [([String], String)] = [
            (["--version"], "version"), (["--json", "--version"], "version"), (["--version", "--json"], "version"), (["--version", "collection", "list"], "version"),
            ([], "help - -"), (["help"], "help - -"), (["--help"], "help - -"), (["-h"], "help - -"), (["--json", "--help"], "help - -"),
            (["help", "request"], "help request -"), (["request", "--help"], "help request -"), (["request", "-h"], "help request -"),
            (["help", "request", "get"], "help request get"), (["request", "get", "--help"], "help request get"), (["request", "get", "-h"], "help request get"),
            (["request", "get", "--id", "x", "--help"], "help request get"), (["help", "request", "get", "--id"], "help request get"),
            (["request", "nope", "--help"], "help request nope"), (["request", "get", "--nope", "--help"], "help request get"),
            (["tools", "--help"], "help tools list"), (["call", "--help"], "help call -"), (["call", "x", "--help"], "help call -"), (["help", "call", "x"], "help call x"),
            (["nope", "--help"], "error: Unknown command nope.")
        ]
        for (words, expected) in cases { XCTAssertEqual(outcome(words), expected, "\(words)") }
    }

    func testCallTakesTheToolNameAndRawArguments() throws {
        let call = try parsed(["call", "history_list", "--args", #"{"limit":2}"#, "--json"])
        XCTAssertEqual(call.command.name, "call tool")
        XCTAssertEqual(call.positional, "history_list")
        XCTAssertEqual(call.arguments.root, ["args": .string(#"{"limit":2}"#)], "--args stays text until the call")
        XCTAssertTrue(call.global.json)
        XCTAssertEqual(try parsed(["call", "collection_list"]).arguments.root, [:])
        XCTAssertNil(try parsed(["request", "list"]).positional)
    }
}
