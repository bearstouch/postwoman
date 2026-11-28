import Foundation

/// Filesystem effects of `cli install-link` and `cli remove-link`, injected for tests.
public struct CLILinks: Sendable {
    /// Where an existing symbolic link points; nil when the path is not a symbolic link.
    public var destination: @Sendable (String) -> String?
    public var exists: @Sendable (String) -> Bool
    public var createDirectory: @Sendable (String) throws -> Void
    public var createLink: @Sendable (_ path: String, _ target: String) throws -> Void
    public var remove: @Sendable (String) throws -> Void

    public init(
        destination: @escaping @Sendable (String) -> String?, exists: @escaping @Sendable (String) -> Bool, createDirectory: @escaping @Sendable (String) throws -> Void,
        createLink: @escaping @Sendable (String, String) throws -> Void, remove: @escaping @Sendable (String) throws -> Void
    ) {
        self.destination = destination; self.exists = exists; self.createDirectory = createDirectory; self.createLink = createLink; self.remove = remove
    }

    public static let live = CLILinks(
        destination: { try? FileManager.default.destinationOfSymbolicLink(atPath: $0) },
        exists: { path in
            var info = stat()
            return lstat(path, &info) == 0
        },
        createDirectory: { try FileManager.default.createDirectory(atPath: $0, withIntermediateDirectories: true) },
        createLink: { try FileManager.default.createSymbolicLink(atPath: $0, withDestinationPath: $1) },
        remove: { try FileManager.default.removeItem(atPath: $0) })
}

enum CLILinkCommands {
    static let linkName = "reqs"

    static func directory(_ arguments: ToolArguments, environment: CLIEnvironment) -> String {
        let directory = arguments.root["directory"]?.string ?? "~/.local/bin"
        let expanded = directory.hasPrefix("~") ? environment.home + directory.dropFirst() : directory
        return expanded.hasSuffix("/") && expanded.count > 1 ? String(expanded.dropLast()) : expanded
    }

    static func install(_ arguments: ToolArguments, environment: CLIEnvironment) throws(CLIFailure) -> JSONValue {
        let directory = directory(arguments, environment: environment)
        let path = "\(directory)/\(linkName)"
        let target = environment.executablePath
        guard target.hasPrefix("/") else { throw CLIFailure(code: "LINK_FAILED", message: "Can't tell where this reqs command is.", exitStatus: 1) }
        if environment.links.exists(path) {
            if environment.links.destination(path) == target { return result(path, target, changed: false, environment: environment) }
            guard environment.links.destination(path) != nil else {
                throw CLIFailure(code: "LINK_FAILED", message: "\(path) exists and is not a link. Remove it, or choose another --directory.", exitStatus: 1)
            }
            guard arguments.options.contains("force") else {
                throw CLIFailure(code: "LINK_FAILED", message: "\(path) already links to \(environment.links.destination(path) ?? "?"). Pass --force to replace it.", exitStatus: 1)
            }
            do { try environment.links.remove(path) } catch { throw CLIFailure(code: "LINK_FAILED", message: "Can't replace \(path).", exitStatus: 1) }
        }
        do {
            try environment.links.createDirectory(directory)
            try environment.links.createLink(path, target)
        } catch {
            throw CLIFailure(code: "LINK_FAILED", message: "Can't create \(path): \(error.localizedDescription)", exitStatus: 1)
        }
        return result(path, target, changed: true, environment: environment)
    }

    static func remove(_ arguments: ToolArguments, environment: CLIEnvironment) throws(CLIFailure) -> JSONValue {
        let path = "\(directory(arguments, environment: environment))/\(linkName)"
        guard environment.links.exists(path) else { return .object(["link": .string(path), "removed": .bool(false)]) }
        guard environment.links.destination(path) != nil else {
            throw CLIFailure(code: "LINK_FAILED", message: "\(path) is not a link, so it was left alone.", exitStatus: 1)
        }
        do { try environment.links.remove(path) } catch { throw CLIFailure(code: "LINK_FAILED", message: "Can't remove \(path).", exitStatus: 1) }
        return .object(["link": .string(path), "removed": .bool(true)])
    }

    private static func result(_ path: String, _ target: String, changed: Bool, environment: CLIEnvironment) -> JSONValue {
        let directory = (path as NSString).deletingLastPathComponent
        let onPath = (environment.variable("PATH") ?? "").split(separator: ":").contains { String($0) == directory }
        var value: [String: JSONValue] = ["link": .string(path), "target": .string(target), "changed": .bool(changed), "onPath": .bool(onPath)]
        if !onPath { value["hint"] = .string("Add \(directory) to PATH, for example: echo 'export PATH=\"\(directory):$PATH\"' >> ~/.zshrc") }
        return .object(value)
    }
}
