import Foundation
import XCTest

@testable import PostWomanCLI

/// Prints `result` as `noun verb` would without `--json`.
private func render(_ result: JSONValue, _ noun: String, _ verb: String, options: Set<String> = []) throws -> (status: Int32, stdout: String, stderr: String) {
    let command = try XCTUnwrap(CLICommands.command(noun, verb))
    let output = CLIOutputBox()
    let status = CLIOutput.render(result, command: command, options: options, environment: makeCLIEnvironment(output: output))
    return (status, output.stdout, output.stderr)
}

private func execute(_ response: [String: JSONValue], extra: [String: JSONValue] = [:], options: Set<String> = []) throws -> (status: Int32, stdout: String, stderr: String) {
    var result = extra
    result["response"] = .object(response)
    return try render(.object(result), "request", "execute", options: options)
}

private func list(_ key: String, _ items: [[String: JSONValue]]) -> JSONValue { .object([key: .array(items.map(JSONValue.object))]) }

final class CLIRenderingTests: XCTestCase {
    // MARK: Tables

    func testCollectionsPrintAsAlignedColumns() throws {
        let result = try render(
            list(
                "collections",
                [
                    ["id": .string("C1"), "name": .string("Work"), "requestCount": .number(3)],
                    ["id": .string("C-long-id"), "name": .string("Café ☕"), "requestCount": .number(0)]
                ]), "collection", "list")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, ["ID         NAME    REQUESTS", "C1         Work    3", "C-long-id  Café ☕  0"].joined(separator: "\n"))
        XCTAssertEqual(result.stderr, "")
    }

    func testNamesWithEmojiAreNeitherCutNorMisaligned() throws {
        let result = try render(
            list(
                "collections",
                [
                    ["id": .string("C1"), "name": .string("API 💅"), "requestCount": .number(3)],
                    ["id": .string("C2"), "name": .string("Cafe\u{301} x"), "requestCount": .number(1)],
                    ["id": .string("C3"), "name": .string("👨‍👩‍👧 fam"), "requestCount": .number(2)]
                ]), "collection", "list")
        XCTAssertEqual(result.stdout, ["ID  NAME    REQUESTS", "C1  API 💅   3", "C2  Cafe\u{301} x  1", "C3  👨‍👩‍👧 fam   2"].joined(separator: "\n"))
        XCTAssertFalse(result.stdout.contains("\u{FFFD}"), "No name is cut in the middle of a character")
    }

    func testMissingCellsPrintAsADash() throws {
        let result = try render(list("collections", [["id": .string("C")]]), "collection", "list")
        XCTAssertEqual(result.stdout, "ID  NAME  REQUESTS\nC   -     -")
    }

    func testTheLastColumnIsNeverPadded() throws {
        let result = try render(
            list(
                "requests",
                [
                    ["id": .string("R1"), "method": .string("GET"), "name": .string("List users"), "url": .string("https://api.example.com/users?page=1&size=100")],
                    ["id": .string("R2"), "method": .string("DELETE"), "name": .string("Drop"), "url": .string("{{base}}/x")]
                ]), "request", "list")
        XCTAssertEqual(
            result.stdout,
            ["ID  METHOD  NAME        URL", "R1  GET     List users  https://api.example.com/users?page=1&size=100", "R2  DELETE  Drop        {{base}}/x"].joined(separator: "\n"))
        XCTAssertFalse(result.stdout.components(separatedBy: "\n").contains { $0.hasSuffix(" ") })
    }

    func testEmptyListsSaySoOnStderrAndPrintNothing() throws {
        let cases: [(String, String, String, String)] = [
            ("collection", "list", "collections", "No collections."), ("request", "list", "requests", "No requests."),
            ("environment", "list", "environments", "No environments."), ("history", "list", "entries", "No history."), ("tools", "list", "tools", "No tools.")
        ]
        for (noun, verb, key, note) in cases {
            for result in [list(key, []), .object([:]), .null] {
                let printed = try render(result, noun, verb)
                XCTAssertEqual(printed.status, 0, "\(noun) \(verb)")
                XCTAssertEqual(printed.stdout, "", "\(noun) \(verb) \(result.compact)")
                XCTAssertEqual(printed.stderr, note, "\(noun) \(verb) \(result.compact)")
            }
        }
    }

    func testEnvironmentsShowWhichOneIsInUse() throws {
        let environments: [[String: JSONValue]] = [
            ["id": .string("D1"), "name": .string("Default"), "isDefault": .bool(true), "variables": .array([.object([:]), .object([:])])],
            ["id": .string("E2"), "name": .string("Staging"), "isDefault": .bool(false), "variables": .array([.object([:])])],
            ["id": .string("E3"), "name": .string("Prod"), "isDefault": .bool(false)]
        ]
        var selected = list("environments", environments)
        if case .object(var object) = selected {
            object["selectedEnvironmentId"] = .string("E2")
            selected = .object(object)
        }
        XCTAssertEqual(
            try render(selected, "environment", "list").stdout,
            ["ID  NAME     VARIABLES  IN USE", "D1  Default  2          always", "E2  Staging  1          yes", "E3  Prod     0          "].joined(separator: "\n"))
        XCTAssertEqual(
            try render(list("environments", environments), "environment", "list").stdout,
            ["ID  NAME     VARIABLES  IN USE", "D1  Default  2          always", "E2  Staging  1          ", "E3  Prod     0          "].joined(separator: "\n"),
            "With none selected, only Default is in use")
    }

    func testHistoryShowsWhenItWasSentAndErrorsWithoutAStatus() throws {
        let sent = "2026-11-27T10:15:30Z"
        let when = try Date(sent, strategy: .iso8601).formatted(
            .dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        let result = try render(
            list(
                "entries",
                [
                    ["id": .string("H1"), "timestamp": .string(sent), "method": .string("GET"), "status": .number(200), "url": .string("https://x.test")],
                    ["id": .string("H2"), "timestamp": .string("yesterday"), "method": .string("POST"), "url": .string("https://y.test")]
                ]), "history", "list")
        let rows = result.stdout.components(separatedBy: "\n")
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows[0].hasPrefix("ID  SENT"))
        XCTAssertTrue(rows[1].hasPrefix("H1  \(when)"), rows[1])
        XCTAssertTrue(rows[1].hasSuffix("GET     200     https://x.test"), rows[1])
        XCTAssertTrue(rows[2].hasPrefix("H2  -"), "An unreadable timestamp prints a dash: \(rows[2])")
        XCTAssertTrue(rows[2].hasSuffix("POST    error   https://y.test"), "No status means it failed: \(rows[2])")
        XCTAssertEqual(result.stderr, "", "No next page, no note")
    }

    func testHistoryPagingNoteGoesToStderr() throws {
        let page: JSONValue = .object([
            "entries": .array([.object(["id": .string("H1"), "status": .number(204)])]), "total": .number(120), "nextOffset": .number(50)
        ])
        let result = try render(page, "history", "list")
        XCTAssertEqual(result.stderr, "Showing 1 of 120. Next page: --offset 50")
        XCTAssertFalse(result.stdout.contains("Showing"))
        let last = try render(.object(["entries": .array([.object(["id": .string("H1")])]), "total": .number(1)]), "history", "list")
        XCTAssertEqual(last.stderr, "", "The last page has no next offset")
    }

    func testToolsShowTheFirstSentenceOfEachDescription() throws {
        let result = try render(
            list(
                "tools",
                [
                    ["name": .string("request_execute"), "description": .string("Sends a request. It is recorded in History.")],
                    ["name": .string("x"), "description": .string("No period")], ["name": .string("empty"), "description": .string("")]
                ]), "tools", "list")
        XCTAssertEqual(
            result.stdout, ["TOOL             DESCRIPTION", "request_execute  Sends a request.", "x                No period.", "empty            "].joined(separator: "\n"))
    }

    // MARK: Messages

    func testDeletionsSayWhatWasDeleted() throws {
        let cases: [(String, String, JSONValue, String)] = [
            ("collection", "delete", .object(["deleted": .string("C1"), "deletedRequests": .number(2)]), "Deleted collection C1 and its 2 requests."),
            ("collection", "delete", .object(["deleted": .string("C1"), "deletedRequests": .number(1)]), "Deleted collection C1 and its 1 request."),
            ("collection", "delete", .object(["deleted": .string("C1"), "deletedRequests": .number(0)]), "Deleted collection C1 and its 0 requests."),
            ("collection", "delete", .object(["deleted": .string("C1")]), "Deleted collection C1."),
            ("request", "delete", .object(["deleted": .string("R1")]), "Deleted request R1."),
            ("environment", "delete", .object(["deleted": .string("E1")]), "Deleted environment E1."),
            ("history", "delete", .object(["deleted": .string("H1")]), "Deleted history entry H1."),
            ("history", "clear", .object(["deleted": .number(0)]), "Deleted 0 history entries."),
            ("history", "clear", .object(["deleted": .number(1)]), "Deleted 1 history entry."),
            ("history", "clear", .object(["deleted": .number(25)]), "Deleted 25 history entries."),
            ("history", "delete", .object([:]), "Deleted history entry -.")
        ]
        for (noun, verb, result, expected) in cases {
            let printed = try render(result, noun, verb)
            XCTAssertEqual(printed.stdout, expected, "\(noun) \(verb) \(result.compact)")
            XCTAssertEqual(printed.stderr, "")
            XCTAssertEqual(printed.status, 0)
        }
    }

    func testOtherResultsPrintAsPrettySortedJSON() throws {
        let result: JSONValue = .object(["url": .string("https://x.test/a"), "b": .array([.number(1), .number(2)]), "a": .bool(true), "name": .string("Café 🍕")])
        for (noun, verb) in [("request", "get"), ("collection", "create"), ("environment", "select"), ("call", "tool"), ("history", "get")] {
            let printed = try render(result, noun, verb)
            XCTAssertEqual(
                printed.stdout, "{\n  \"a\" : true,\n  \"b\" : [\n    1,\n    2\n  ],\n  \"name\" : \"Café 🍕\",\n  \"url\" : \"https://x.test/a\"\n}", "\(noun) \(verb)")
        }
        XCTAssertEqual(try render(.null, "request", "get").stdout, "null")
    }

    func testCellTextForEveryKindOfValue() {
        let cases: [(JSONValue?, String)] = [
            (.string("a b"), "a b"), (.string(""), ""), (.number(3), "3"), (.number(-2), "-2"), (.number(2.5), "2.5"), (.number(0), "0"), (.bool(true), "true"),
            (.bool(false), "false"), (nil, "-"), (.null, "-"), (.array([.number(1), .string("a")]), #"[1,"a"]"#),
            (.object(["b": .number(1), "a": .string("x/y")]), #"{"a":"x/y","b":1}"#)
        ]
        for (value, expected) in cases { XCTAssertEqual(CLIOutput.text(value), expected, "\(String(describing: value))") }
    }

    func testNumbersTooLargeForAnIntPrintAsText() {
        let cases: [(Double, String)] = [
            (1e20, "100000000000000000000"), (-1e20, "-100000000000000000000"), (9_223_372_036_854_775_808, "9223372036854775808"), (1e20 + 0.5, "100000000000000000000"),
            (.infinity, "inf"), (-.infinity, "-inf"), (.nan, "nan"), (-0.0, "0")
        ]
        for (number, expected) in cases { XCTAssertEqual(CLIOutput.text(.number(number)), expected, "\(number)") }
    }

    func testLargeNumbersInResultsPrintInsteadOfCrashing() throws {
        let page: JSONValue = .object([
            "entries": .array([.object(["id": .string("H1"), "status": .number(1e20), "url": .string("u")]), .object(["id": .string("H2"), "status": .number(.nan)])]),
            "total": .number(1e20), "nextOffset": .number(.infinity)
        ])
        let history = try render(page, "history", "list")
        XCTAssertTrue(history.stdout.contains("100000000000000000000"), history.stdout)
        XCTAssertEqual(history.stderr, "Showing 2 of 100000000000000000000. Next page: --offset inf")
        XCTAssertEqual(try render(.object(["deleted": .number(1e20)]), "history", "clear").stdout, "Deleted 100000000000000000000 history entries.")
        XCTAssertEqual(
            try render(.object(["deleted": .string("C1"), "deletedRequests": .number(1e20)]), "collection", "delete").stdout,
            "Deleted collection C1 and its 100000000000000000000 requests.")
        let huge = try execute(
            ["status": .number(1e20), "statusText": .string("Odd"), "timeMs": .number(1e20), "size": .number(1e20), "stream": .object(["eventCount": .number(1e20), "end": .string("completed")])],
            options: ["fail"])
        XCTAssertEqual(huge.stderr, "100000000000000000000 Odd · 100000000000000000000 ms · 100000000000000000000 B · 100000000000000000000 events completed")
        XCTAssertEqual(huge.status, 22, "A status of 400 or more fails with --fail, however large")
        let odd = try execute(["status": .number(.nan), "statusText": .string("S"), "timeMs": .number(-.infinity), "size": .number(.nan)], options: ["fail"])
        XCTAssertEqual(odd.stderr, "nan S · -inf ms · nan B")
        XCTAssertEqual(odd.status, 0)
    }

    // MARK: request execute

    func testExecutePrintsTheBodyOnStdoutAndASummaryOnStderr() throws {
        let result = try execute(
            ["status": .number(200), "statusText": .string("OK"), "body": .string(#"{"a":1}"#), "timeMs": .number(12.4), "size": .number(7)],
            extra: ["historyId": .string("H1"), "environment": .string("Staging")])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, #"{"a":1}"#)
        XCTAssertEqual(result.stderr, "200 OK · 12 ms · 7 B · Staging · history H1")
    }

    func testSummaryLeavesOutWhatTheResponseLacks() throws {
        XCTAssertEqual(try execute(["status": .number(404), "statusText": .string("Not Found")]).stderr, "404 Not Found")
        XCTAssertEqual(try execute(["status": .number(200)]).stderr, "200 -")
        XCTAssertEqual(try execute(["status": .number(200), "statusText": .string("OK"), "timeMs": .number(0.6)]).stderr, "200 OK · 1 ms")
        XCTAssertEqual(try execute(["status": .number(200), "statusText": .string("OK"), "size": .number(1023)]).stderr, "200 OK · 1023 B")
        XCTAssertEqual(try execute(["status": .number(200), "statusText": .string("OK"), "size": .number(2048)]).stderr, "200 OK · 2 KB")
        XCTAssertEqual(try execute(["status": .number(200), "statusText": .string("OK"), "stream": .null]).stderr, "200 OK", "A null stream is no stream")
        XCTAssertEqual(try execute(["status": .number(200), "statusText": .string("OK")]).stdout, "", "No body, nothing on stdout")
    }

    func testIncludePrintsTheStatusLineAndHeadersBeforeTheBody() throws {
        let result = try execute(
            [
                "status": .number(201), "statusText": .string("Created"), "body": .string("done"),
                "headers": .array([
                    .object(["key": .string("Content-Type"), "value": .string("text/plain")]), .object(["key": .string("X-Note"), "value": .string("café")])
                ])
            ], options: ["include"])
        XCTAssertEqual(result.stdout, "HTTP 201 Created\nContent-Type: text/plain\nX-Note: café\n\ndone", "A blank line between headers and body, like curl -i")
        XCTAssertEqual(result.stderr, "201 Created")
        let headerless = try execute(["status": .number(204), "statusText": .string("No Content")], options: ["include"])
        XCTAssertEqual(headerless.stdout, "HTTP 204 No Content\n")
    }

    func testFailExitsWith22OnlyForErrorStatuses() throws {
        for (status, expected) in [(200, 0), (302, 0), (399, 0), (400, 22), (404, 22), (500, 22), (503, 22)] as [(Int, Int32)] {
            let response: [String: JSONValue] = ["status": .number(Double(status)), "statusText": .string("S"), "body": .string("b")]
            XCTAssertEqual(try execute(response, options: ["fail"]).status, expected, "\(status)")
            XCTAssertEqual(try execute(response).status, 0, "Without --fail every response exits 0: \(status)")
            XCTAssertEqual(try execute(response, options: ["fail"]).stdout, "b", "The body is printed either way")
        }
        XCTAssertEqual(try execute([:], options: ["fail"]).status, 0)
    }

    func testABodyNoteStandsInForAMissingBody() throws {
        let result = try execute(["status": .number(200), "statusText": .string("OK"), "bodyNote": .string("Binary body (12 bytes), not shown.")])
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "Binary body (12 bytes), not shown.\n200 OK")
        let both = try execute(["status": .number(200), "statusText": .string("OK"), "body": .string("b"), "bodyNote": .string("note")])
        XCTAssertEqual(both.stdout, "b")
        XCTAssertEqual(both.stderr, "200 OK", "A body wins over its note")
    }

    func testStreamsSummarizeTheirEventsAndPrintAssembledText() throws {
        let stream: JSONValue = .object(["eventCount": .number(3), "end": .string("completed"), "text": .string("Hello there")])
        let response: [String: JSONValue] = ["status": .number(200), "statusText": .string("OK"), "body": .string("data: {}\n\ndata: [DONE]"), "stream": stream]
        let raw = try execute(response)
        XCTAssertEqual(raw.stdout, "data: {}\n\ndata: [DONE]")
        XCTAssertEqual(raw.stderr, "200 OK · 3 events completed")
        let text = try execute(response, options: ["text"])
        XCTAssertEqual(text.stdout, "Hello there")
        XCTAssertEqual(text.stderr, "200 OK · 3 events completed")

        let one = try execute(["status": .number(200), "statusText": .string("OK"), "stream": .object(["eventCount": .number(1), "end": .string("stopped")])])
        XCTAssertEqual(one.stderr, "200 OK · 1 event stopped")
        let none = try execute(["status": .number(200), "statusText": .string("OK"), "stream": .object([:])])
        XCTAssertEqual(none.stderr, "200 OK · 0 events -")
    }

    func testTextWithoutLLMTextFallsBackToTheBody() throws {
        let result = try execute(["status": .number(200), "statusText": .string("OK"), "body": .string("plain")], options: ["text"])
        XCTAssertEqual(result.stdout, "plain")
        XCTAssertEqual(result.stderr, "200 OK\nNo LLM text in the response, so the body is shown.")
    }

    func testNotesFollowTheSummaryInOrder() throws {
        let result = try execute(
            [
                "status": .number(200), "statusText": .string("OK"), "body": .string("partial"), "bodyTruncated": .bool(true),
                "stream": .object(["eventCount": .number(2), "end": .string("failed"), "error": .string("The network connection was lost.")])
            ], extra: ["unresolvedVariables": .array([.string("host"), .string("token")]), "historyId": .string("H2")], options: ["text"])
        XCTAssertEqual(result.stdout, "partial")
        XCTAssertEqual(
            result.stderr,
            [
                "200 OK · 2 events failed · history H2", "Sent as written (no environment defines them): {{host}}, {{token}}",
                "The stream was interrupted: The network connection was lost.", "No LLM text in the response, so the body is shown.",
                "The body was cut; pass a larger --max-body (up to 900000) for more."
            ].joined(separator: "\n"))
        let quiet = try execute(["status": .number(200), "statusText": .string("OK"), "bodyTruncated": .bool(false)], extra: ["unresolvedVariables": .array([])])
        XCTAssertEqual(quiet.stderr, "200 OK", "No unresolved variables and an uncut body add no notes")
    }
}
