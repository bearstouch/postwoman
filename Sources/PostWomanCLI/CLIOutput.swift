import Foundation

/// Prints results for people; `--json` prints `{"ok": true, "result": …}` instead.
enum CLIOutput {
    /// The exit status `request execute --fail` uses for a 4xx/5xx response, as curl does.
    static let failedResponseStatus: Int32 = 22

    /// Prints `result` and returns the exit status.
    static func render(_ result: JSONValue, command: Command, options: Set<String>, environment: CLIEnvironment) -> Int32 {
        switch command.rendering {
        case .json:
            environment.stdout(result.pretty)
        case .collections:
            let rows = (result["collections"]?.array ?? []).map { [text($0["id"]), text($0["name"]), text($0["requestCount"])] }
            table(["ID", "NAME", "REQUESTS"], rows, empty: "No collections.", environment: environment)
        case .requests:
            let rows = (result["requests"]?.array ?? []).map { [text($0["id"]), text($0["method"]), text($0["name"]), text($0["url"])] }
            table(["ID", "METHOD", "NAME", "URL"], rows, empty: "No requests.", environment: environment)
        case .environments:
            let selected = result["selectedEnvironmentId"]?.string
            let rows = (result["environments"]?.array ?? []).map { environment -> [String] in
                let isDefault = environment["isDefault"] == .bool(true)
                let inUse = isDefault ? selected == nil : environment["id"]?.string == selected
                let note = isDefault ? "always" : inUse ? "yes" : ""
                return [text(environment["id"]), text(environment["name"]), String(environment["variables"]?.array?.count ?? 0), note]
            }
            table(["ID", "NAME", "VARIABLES", "IN USE"], rows, empty: "No environments.", environment: environment)
        case .history:
            let rows = (result["entries"]?.array ?? []).map { entry in
                [text(entry["id"]), when(entry["timestamp"]), text(entry["method"]), entry["status"].flatMap(\.number).map(number) ?? "error", text(entry["url"])]
            }
            table(["ID", "SENT", "METHOD", "STATUS", "URL"], rows, empty: "No history.", environment: environment)
            if let next = result["nextOffset"]?.number, let total = result["total"]?.number {
                environment.stderr("Showing \(rows.count) of \(number(total)). Next page: --offset \(number(next))")
            }
        case .deleted(let kind):
            if case .number(let count)? = result["deleted"] {
                let noun = count == 1 ? kind : kind.hasSuffix("y") ? String(kind.dropLast()) + "ies" : kind + "s"
                environment.stdout("Deleted \(number(count)) \(noun).")
            } else {
                let extra = result["deletedRequests"]?.number.map { " and its \(number($0)) request\($0 == 1 ? "" : "s")" } ?? ""
                environment.stdout("Deleted \(kind) \(text(result["deleted"]))\(extra).")
            }
        case .tools:
            let rows = (result["tools"]?.array ?? []).map { tool -> [String] in
                let description = text(tool["description"])
                let first = description.split(separator: ".", maxSplits: 1).first.map { String($0) + "." } ?? description
                return [text(tool["name"]), first]
            }
            table(["TOOL", "DESCRIPTION"], rows, empty: "No tools.", environment: environment)
        case .execute:
            return execute(result, options: options, environment: environment)
        }
        return 0
    }

    /// The body on stdout, like curl; a one-line summary on stderr, so pipes get only the body.
    private static func execute(_ result: JSONValue, options: Set<String>, environment: CLIEnvironment) -> Int32 {
        let response = result["response"] ?? .null
        let status = response["status"]?.number ?? 0
        let statusLine = "\(number(status)) \(text(response["statusText"]))"
        if options.contains("include") {
            var head = "HTTP \(statusLine)"
            for header in response["headers"]?.array ?? [] { head += "\n\(text(header["key"])): \(text(header["value"]))" }
            environment.stdout(head + "\n")
        }
        let stream = response["stream"]
        if options.contains("text"), let text = stream?["text"]?.string {
            environment.stdout(text)
        } else if let body = response["body"]?.string {
            environment.stdout(body)
        } else if let note = response["bodyNote"]?.string {
            environment.stderr(note)
        }
        var summary = [statusLine]
        if let time = response["timeMs"]?.number { summary.append("\(number(time.rounded())) ms") }
        if let size = response["size"]?.number { summary.append(bytes(size)) }
        if let stream, stream != .null {
            let count = stream["eventCount"]?.number ?? 0
            summary.append("\(count == 1 ? "1 event" : "\(number(count)) events") \(text(stream["end"]))")
        }
        if let name = result["environment"]?.string { summary.append(name) }
        if let history = result["historyId"]?.string { summary.append("history \(history)") }
        environment.stderr(summary.joined(separator: " · "))
        let unresolved = (result["unresolvedVariables"]?.array ?? []).compactMap(\.string)
        if !unresolved.isEmpty {
            environment.stderr("Sent as written (no environment defines them): " + unresolved.map { "{{\($0)}}" }.joined(separator: ", "))
        }
        if case .string(let error)? = stream?["error"] { environment.stderr("The stream was interrupted: \(error)") }
        if options.contains("text"), stream?["text"]?.string == nil { environment.stderr("No LLM text in the response, so the body is shown.") }
        if response["bodyTruncated"] == .bool(true) { environment.stderr("The body was cut; pass a larger --max-body (up to 900000) for more.") }
        return options.contains("fail") && status >= 400 ? failedResponseStatus : 0
    }

    static func text(_ value: JSONValue?) -> String {
        switch value {
        case .string(let text)?: text
        case .number(let value)?: number(value)
        case .bool(let flag)?: String(flag)
        case nil, .null?: "-"
        case let other?: other.compact
        }
    }

    private static func when(_ value: JSONValue?) -> String {
        guard let text = value?.string, let date = try? Date(text, strategy: .iso8601) else { return "-" }
        return date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }

    /// A JSON number as people write it: whole numbers without a fraction, even past `Int.max`; non-finite ones as `inf`/`nan`.
    static func number(_ value: Double) -> String {
        if let whole = Int(exactly: value) { return String(whole) }
        if value.isFinite, value.rounded() == value { return String(format: "%.0f", value) }
        return String(value)
    }

    private static func bytes(_ count: Double) -> String {
        guard let whole = Int64(exactly: count), whole >= 1024 else { return "\(number(count)) B" }
        return ByteCountFormatter.string(fromByteCount: whole, countStyle: .file)
    }

    /// Left-aligned columns; the last one is never padded.
    private static func table(_ header: [String], _ rows: [[String]], empty: String, environment: CLIEnvironment) {
        guard !rows.isEmpty else {
            environment.stderr(empty)
            return
        }
        let all = [header] + rows
        let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
        for row in all {
            let cells = row.enumerated().map { column, cell in
                column == row.count - 1 ? cell : cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }
            environment.stdout(cells.joined(separator: "  "))
        }
    }
}
