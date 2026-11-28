import Foundation

public enum CLI {
    /// Must match `AppVersion.release` (checked by `AppVersionTests`).
    public static let version = "0.11.0"

    /// Runs one invocation and returns the process exit status. Never retries a tool call.
    public static func run(_ arguments: [String], environment: CLIEnvironment) async -> Int32 {
        let json = arguments.contains("--json")
        let input = CLIInput(readFile: environment.readFile, readStdin: environment.readStdin)
        do throws(CLIFailure) {
            switch try CLIArguments.parse(arguments, input: input) {
            case .help(let noun, let verb):
                let text = try CLIHelp.text(noun: noun, verb: verb)
                environment.stdout(json ? envelope(.object(["help": .string(text)])) : text)
                return 0
            case .version:
                environment.stdout(json ? envelope(.object(["version": .string(version)])) : "reqs \(version)")
                return 0
            case .run(let command, let toolArguments, let global, let positional):
                let result = try await execute(command, toolArguments, global, positional: positional, environment: environment)
                if json {
                    environment.stdout(envelope(result))
                    if case .execute = command.rendering, toolArguments.options.contains("fail"), (result["response"]?["status"]?.number ?? 0) >= 400 {
                        return CLIOutput.failedResponseStatus
                    }
                    return 0
                }
                if command.noun == "cli" { return printLink(result, environment: environment) }
                return CLIOutput.render(result, command: command, options: toolArguments.options, environment: environment)
            }
        } catch {
            report(error, json: json, arguments: arguments, environment: environment)
            return error.exitStatus
        }
    }

    private static func execute(
        _ command: Command, _ arguments: ToolArguments, _ global: GlobalOptions, positional: String?, environment: CLIEnvironment
    ) async throws(CLIFailure) -> JSONValue {
        switch (command.noun, command.verb) {
        case ("cli", "install-link"): return try CLILinkCommands.install(arguments, environment: environment)
        case ("cli", "remove-link"): return try CLILinkCommands.remove(arguments, environment: environment)
        default: break
        }
        let candidates = try ConnectionResolver.candidates(server: global.server, token: global.token, tokenFile: global.tokenFile, environment: environment)
        let client = try await MCPClient.connect(candidates, version: version, environment: environment)
        do throws(CLIFailure) {
            let result: JSONValue
            if command.noun == "tools" {
                result = .object(["tools": .array(try await client.listTools())])
            } else if command.noun == "call" {
                result = try await client.callTool(positional ?? "", arguments: try rawArguments(arguments.root["args"]?.string))
            } else {
                // request execute without --id sends an ad-hoc request: its fields go under `request`.
                let nest = command.tool == "request_execute" && arguments.root["id"] == nil
                if nest, arguments.fields["url"] == nil { throw CLIFailure.arguments("Pass --id (a saved request) or --url (an ad-hoc one).") }
                if command.tool == "request_execute", !nest, !arguments.fields.isEmpty || !arguments.auth.isEmpty {
                    throw CLIFailure.arguments("--id sends the saved request as it is. Change it first with 'request update', or leave out --id to send an ad-hoc request.")
                }
                result = try await client.callTool(command.tool ?? "", arguments: arguments.merged(nestFields: nest))
            }
            await client.close()
            return result
        } catch {
            await client.close()
            throw error
        }
    }

    private static func rawArguments(_ text: String?) throws(CLIFailure) -> [String: JSONValue] {
        guard let text else { return [:] }
        guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
            throw .arguments("--args must be a JSON object, such as '{\"limit\": 5}'.")
        }
        return object
    }

    private static func printLink(_ result: JSONValue, environment: CLIEnvironment) -> Int32 {
        let link = CLIOutput.text(result["link"])
        if let removed = result["removed"] {
            environment.stdout(removed == .bool(true) ? "Removed \(link)." : "There is no link at \(link).")
        } else {
            environment.stdout(result["changed"] == .bool(true) ? "Linked \(link) → \(CLIOutput.text(result["target"]))" : "\(link) already links here.")
            if let hint = result["hint"]?.string { environment.stderr(hint) }
        }
        return 0
    }

    private static func envelope(_ result: JSONValue) -> String { JSONValue.object(["ok": .bool(true), "result": result]).compact }

    private static func report(_ failure: CLIFailure, json: Bool, arguments: [String], environment: CLIEnvironment) {
        if json {
            var error: [String: JSONValue] = ["code": .string(failure.code), "message": .string(failure.message), "exitStatus": .number(Double(failure.exitStatus))]
            if let details = failure.details { error["details"] = details }
            environment.stdout(JSONValue.object(["ok": .bool(false), "error": .object(error)]).compact)
            return
        }
        environment.stderr("reqs: \(failure.message) (\(failure.code))")
        if let history = failure.details?["historyId"]?.string { environment.stderr("Recorded in History as \(history).") }
        if failure.code == "INVALID_ARGUMENTS" || failure.code == "INVALID_PARAMS" { environment.stderr(CLIHelp.hint(arguments)) }
    }
}
