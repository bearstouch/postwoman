import Darwin
import Foundation
import Security

/// The MCP server settings in Settings → Remote Agent. Off by default; the address is an IP literal,
/// never a hostname, so binding cannot depend on name resolution.
struct RemoteAgentSettings: Codable, Equatable, Sendable {
    /// Trellis uses 7777, so both apps can serve at once.
    static let defaultPort: UInt16 = 7778
    static let portRange: ClosedRange<UInt16> = 1024...65_535
    var mcpEnabled = false
    var bindAddress = "127.0.0.1"
    var port = Self.defaultPort

    init(mcpEnabled: Bool = false, bindAddress: String = "127.0.0.1", port: UInt16 = Self.defaultPort) {
        self.mcpEnabled = mcpEnabled; self.bindAddress = bindAddress; self.port = port
    }

    private enum CodingKeys: String, CodingKey { case mcpEnabled, bindAddress, port }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mcpEnabled = try c.decodeIfPresent(Bool.self, forKey: .mcpEnabled) ?? false
        bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? "127.0.0.1"
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? Self.defaultPort
    }

    var isValid: Bool { Self.portRange.contains(port) && IPAddressLiteral(bindAddress) != nil }
    /// Only loopback binds are reachable without an explicit network confirmation.
    var isLoopback: Bool { IPAddressLiteral(bindAddress)?.isLoopback ?? false }
    /// `http://127.0.0.1:7778/mcp`; IPv6 literals are bracketed.
    var endpointURL: String { Self.endpointURL(address: bindAddress, port: port) }

    static func endpointURL(address: String, port: UInt16) -> String {
        let host = address.contains(":") ? "[\(address)]" : address
        return "http://\(host):\(port)/mcp"
    }

    /// A URL clients on this Mac can reach: a wildcard bind is shown as its loopback address.
    var clientURL: String {
        switch bindAddress {
        case "0.0.0.0": Self.endpointURL(address: "127.0.0.1", port: port)
        case "::": Self.endpointURL(address: "::1", port: port)
        default: endpointURL
        }
    }

    // MARK: - Saving

    static let defaultsKey = "remoteAgent.settings"

    /// The saved settings; unreadable data falls back to the defaults (server off).
    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey), let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// A parsed IPv4 or IPv6 literal.
enum IPAddressLiteral: Equatable, Sendable {
    case v4(in_addr_t)
    case v6([UInt8])

    init?(_ text: String) {
        guard !text.isEmpty, text.utf8.count <= 45, !text.contains("%") else { return nil }
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            self = .v4(v4.s_addr)
        } else if inet_pton(AF_INET6, text, &v6) == 1 {
            self = .v6(withUnsafeBytes(of: &v6) { Array($0) })
        } else {
            return nil
        }
    }

    var isLoopback: Bool {
        switch self {
        case .v4(let address): UInt32(bigEndian: address) >> 24 == 127
        case .v6(let bytes): bytes == [UInt8](repeating: 0, count: 15) + [1]
        }
    }

    /// Tailscale's ranges, `100.64.0.0/10` and `fd7a:115c:a1e0::/48`, labelled in the Listen on picker.
    var isTailnet: Bool {
        switch self {
        case .v4(let address): UInt32(bigEndian: address) >> 22 == (100 << 2 | 1)
        case .v6(let bytes): Array(bytes.prefix(6)) == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]
        }
    }
}

/// What the MCP server is doing now, shown in Settings → Remote Agent.
enum RemoteAgentStatus: Equatable, Sendable {
    case stopped
    case running(url: String)
    case failed(reason: String)
}

/// A local interface address offered in the Listen on picker.
struct NetworkInterfaceAddress: Equatable, Hashable, Sendable {
    let interface: String
    let address: String

    /// Up, non-loopback IPv4/IPv6 addresses. IPv6 link-local addresses need a scope ID, which the
    /// settings do not store, so they are left out.
    static func current() -> [Self] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [Self] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !text.contains("%"), !text.lowercased().hasPrefix("fe80") else { continue }
            result.append(Self(interface: String(cString: entry.pointee.ifa_name), address: text))
        }
        return Array(Set(result)).sorted { ($0.interface, $0.address) < ($1.interface, $1.address) }
    }
}

/// Ready-to-paste client configuration. A snippet never holds the real token: a `<TOKEN>` placeholder
/// or an environment variable name.
enum MCPClientSetup: String, CaseIterable, Sendable {
    case claudeCode, codex, opencode, json

    static let tokenVariable = "POSTWOMAN_TOKEN"

    func snippet(url: String) -> String {
        switch self {
        case .claudeCode: "claude mcp add --transport http postwoman \(url) --header \"Authorization: Bearer <TOKEN>\""
        case .opencode: "opencode mcp add postwoman --global --url \(url) --header \"Authorization=Bearer <TOKEN>\""
        case .codex: "[mcp_servers.postwoman]\nurl = \"\(url)\"\nbearer_token_env_var = \"\(Self.tokenVariable)\"\n"
        case .json:
            """
            {
              "mcpServers": {
                "postwoman": {
                  "type": "http",
                  "url": "\(url)",
                  "headers": { "Authorization": "Bearer <TOKEN>" }
                }
              }
            }

            """
        }
    }
}

/// The agent access token: `pwm_` and 32 random bytes in base64url. Kept in a file readable only by
/// this user, inside the app's sandbox container (or the dev store directory for unbundled runs).
/// PostWoman has no grants as Trellis does, so this one token gives an agent full access.
enum RemoteAgentToken {
    static let prefix = "pwm_"

    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "No secure random bytes.")
        let base64 = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return prefix + base64
    }

    static var defaultURL: URL {
        let folder = Bundle.main.bundleURL.pathExtension == "app" ? "PostWoman" : "PostWoman Dev"
        return URL.applicationSupportDirectory.appending(path: folder, directoryHint: .isDirectory).appending(path: "remote-agent-token")
    }

    /// The saved token, or a new one saved now.
    static func loadOrCreate(at url: URL = defaultURL) -> String {
        if let saved = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            saved.hasPrefix(prefix), saved.count >= 40
        {
            return saved
        }
        return regenerate(at: url)
    }

    /// Replaces the token. The caller must also end the sessions opened with the old one.
    @discardableResult
    static func regenerate(at url: URL = defaultURL) -> String {
        let token = generate()
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        manager.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }
}
