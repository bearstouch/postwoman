import Foundation
import Observation
import SwiftData

/// Owns the MCP listener and endpoint for the current settings. Applying always stops the old
/// listener first, so at most one address is ever bound.
final class MCPServer: @unchecked Sendable {
    private let serverVersion: String
    private let callTool: MCPEndpoint.ToolCall
    private let lock = NSLock()
    private var listener: MCPListener?
    private var endpoint: MCPEndpoint?

    init(serverVersion: String, callTool: @escaping MCPEndpoint.ToolCall) {
        self.serverVersion = serverVersion; self.callTool = callTool
    }

    /// Stops any running listener, then starts one when enabled. Returns the new status.
    func apply(_ settings: RemoteAgentSettings, token: String) -> RemoteAgentStatus {
        stop()
        guard settings.mcpEnabled else { return .stopped }
        guard settings.isValid else { return .failed(reason: MCPListenerError.invalidAddress.message(port: settings.port)) }
        let endpoint = MCPEndpoint(token: token, serverVersion: serverVersion, loopbackOnly: settings.isLoopback, callTool: callTool)
        let listener = MCPListener { request in await endpoint.handle(request) }
        do {
            let port = try listener.start(address: settings.bindAddress, port: settings.port)
            lock.withLock {
                self.listener = listener; self.endpoint = endpoint
            }
            return .running(url: RemoteAgentSettings.endpointURL(address: settings.bindAddress, port: port))
        } catch {
            return .failed(reason: error.message(port: settings.port))
        }
    }

    func stop() {
        let (listener, endpoint) = lock.withLock { () -> (MCPListener?, MCPEndpoint?) in
            defer { self.listener = nil; self.endpoint = nil }
            return (self.listener, self.endpoint)
        }
        listener?.stop()
        if let endpoint { Task { await endpoint.closeAll() } }
    }

    /// A new token ends every session opened with the old one, without restarting the listener.
    func setToken(_ token: String) async {
        await lock.withLock { endpoint }?.setToken(token)
    }
}

/// The Remote Agent state Settings shows: saved settings, the server's status and the agent token.
@MainActor @Observable
final class RemoteAgentController {
    private(set) var settings: RemoteAgentSettings
    private(set) var status: RemoteAgentStatus = .stopped
    private(set) var token: String

    @ObservationIgnored private let server: MCPServer
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let tokenURL: URL

    init(container: ModelContainer, defaults: UserDefaults = .standard, tokenURL: URL = RemoteAgentToken.defaultURL) {
        self.defaults = defaults; self.tokenURL = tokenURL
        settings = RemoteAgentSettings.load(from: defaults)
        token = RemoteAgentToken.loadOrCreate(at: tokenURL)
        let handler = MCPToolHandler(container: container)
        server = MCPServer(serverVersion: AppVersion.current) { name, arguments in await handler.call(name, arguments) }
    }

    /// Starts the server if it was left on. A saved value that can't be used shows why instead of failing launch.
    func start() {
        status = server.apply(settings, token: token)
    }

    /// Saves and applies new settings; false (and nothing changes) when they are invalid.
    @discardableResult
    func apply(_ new: RemoteAgentSettings) -> Bool {
        guard new.isValid else { return false }
        settings = new
        new.save(to: defaults)
        status = server.apply(new, token: token)
        return true
    }

    /// A new token; agents using the old one get 401 from their next request.
    func regenerateToken() {
        token = RemoteAgentToken.regenerate(at: tokenURL)
        let token = token
        Task { await server.setToken(token) }
    }

    func stop() {
        server.stop()
        status = .stopped
    }

    /// The URL to give clients on this Mac.
    var clientURL: String { settings.clientURL }

    func networkInterfaces() -> [NetworkInterfaceAddress] { NetworkInterfaceAddress.current() }
}
