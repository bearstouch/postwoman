import AppKit
import SwiftUI

/// Settings → Remote Agent: the MCP server's switch, interface and port, its status, and the agent
/// token. Edits are a draft until Apply; a non-loopback address needs an explicit confirmation first.
struct RemoteAgentSettingsView: View {
    @Environment(RemoteAgentController.self) private var controller
    @State private var draft = RemoteAgentSettings()
    @State private var port = Int(RemoteAgentSettings.defaultPort)
    @State private var interfaces: [NetworkInterfaceAddress] = []
    @State private var confirmingNetwork = false
    @State private var confirmingRegenerate = false
    @State private var revealToken = false
    @State private var message: String?

    private var candidate: RemoteAgentSettings {
        var settings = draft
        settings.port = UInt16(clamping: port)
        return settings
    }
    private var portValid: Bool { port >= Int(RemoteAgentSettings.portRange.lowerBound) && port <= Int(RemoteAgentSettings.portRange.upperBound) }
    /// A failed start (for example, port in use) can be retried with the same settings once the cause is fixed.
    private var retryable: Bool {
        if case .failed = controller.status { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            form
            HairlineDivider()
            HStack {
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Apply") {
                    let settings = candidate
                    let alreadyExposed = controller.settings.mcpEnabled && controller.settings.bindAddress == settings.bindAddress
                    if settings.mcpEnabled, !settings.isLoopback, !alreadyExposed {
                        confirmingNetwork = true
                    } else {
                        commit(settings)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!portValid || !candidate.isValid || (candidate == controller.settings && !retryable))
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .alert("Allow connections from the network?", isPresented: $confirmingNetwork) {
            Button("Cancel", role: .cancel) {}
            Button("Allow Network Access", role: .destructive) { commit(candidate) }
        } message: {
            Text(
                "Devices that can reach \(draft.bindAddress) will be able to connect. Anyone who obtains the access token can then read and change your collections and history, and send requests from this Mac. Traffic is not encrypted."
            )
        }
        .alert("Regenerate the access token?", isPresented: $confirmingRegenerate) {
            Button("Cancel", role: .cancel) {}
            Button("Regenerate", role: .destructive) {
                controller.regenerateToken()
                revealToken = false
                message = "New token created. Agents using the old one must be set up again."
            }
        } message: {
            Text("Agents using the current token are disconnected and can't connect again until you give them the new one.")
        }
        .onAppear {
            interfaces = controller.networkInterfaces()
            reset(to: controller.settings)
        }
        .onChange(of: controller.settings) { _, value in reset(to: value) }
    }

    /// Spoken and visible, not color-only: how far the chosen address reaches.
    private var exposureNote: String {
        if draft.isLoopback { return "Only programs on this Mac can connect." }
        return IPAddressLiteral(draft.bindAddress)?.isTailnet == true
            ? "Devices in your tailnet can reach this server. Tailscale encrypts the traffic, but the server itself uses plain HTTP."
            : "Other devices on the network can reach this server. Requests use plain HTTP, so the access token is sent unencrypted."
    }

    private var form: some View {
        Form {
            Section("MCP server") {
                Toggle(isOn: $draft.mcpEnabled) {
                    SettingsLabel(
                        "Enable MCP server",
                        help:
                            "Lets agents such as Claude Code manage your collections, requests and history, and send requests, through the Model Context Protocol. Agents sign in with the access token below."
                    )
                }
                Picker(selection: $draft.bindAddress) {
                    ForEach(addressOptions, id: \.address) { Text($0.label).tag($0.address) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Listen on")
                        Text(exposureNote).font(.subheadline).foregroundStyle(draft.isLoopback ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.warning))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityHint("The network address the MCP server accepts connections on.")
                LabeledContent {
                    TextField("Port", value: $port, format: .number.grouping(.never))
                        .labelsHidden().multilineTextAlignment(.trailing).frame(maxWidth: 90)
                        .textFieldStyle(.themed)
                        .accessibilityLabel("Port")
                } label: {
                    SettingsLabel("Port (1024–65535)", help: portValid ? nil : "Use a port from 1024 to 65535.")
                }
            }
            Section("Access token") {
                LabeledContent {
                    HStack {
                        Button(revealToken ? "Hide" : "Show") { revealToken.toggle() }
                        Button("Copy Token") { copy(controller.token) }
                        Button("Regenerate…") { confirmingRegenerate = true }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Agent token")
                        Text(verbatim: revealToken ? controller.token : masked(controller.token))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1).truncationMode(.middle)
                            .accessibilityLabel(revealToken ? "Token \(controller.token)" : "Token hidden")
                        Text("Gives an agent full access to PostWoman. Keep it secret, and regenerate it if it leaks.")
                            .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Section("Status") {
                statusRow
                LabeledContent {
                    HStack {
                        Button("Copy Endpoint URL") { copy(controller.clientURL) }
                            .disabled(!controller.settings.mcpEnabled)
                        Menu("Copy Client Setup") {
                            Button("Claude Code command") { copy(MCPClientSetup.claudeCode.snippet(url: controller.clientURL)) }
                            Button("Codex (config.toml)") { copy(MCPClientSetup.codex.snippet(url: controller.clientURL)) }
                            Button("OpenCode command") { copy(MCPClientSetup.opencode.snippet(url: controller.clientURL)) }
                            Button("Generic MCP JSON") { copy(MCPClientSetup.json.snippet(url: controller.clientURL)) }
                        }
                        .fixedSize()
                        .disabled(!controller.settings.mcpEnabled)
                    }
                } label: {
                    SettingsLabel(
                        "Connect an agent",
                        help: "Replace <TOKEN> with the access token, or set \(MCPClientSetup.tokenVariable) for Codex. The snippets never contain the token itself.")
                }
            }
        }
        .settingsFormStyle()
    }

    private var statusRow: some View {
        let (symbol, text): (String, String) =
            switch controller.status {
            case .stopped: ("stop.circle", "Stopped")
            case .running(let url): ("checkmark.circle.fill", "Running at \(url)")
            case .failed(let reason): ("exclamationmark.triangle.fill", "Not running: \(reason)")
            }
        return Label(text, systemImage: symbol)
            .textSelection(.enabled)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Server status: \(text)")
    }

    private var addressOptions: [(address: String, label: String)] {
        var options: [(address: String, label: String)] = [
            ("127.0.0.1", "Loopback — 127.0.0.1 (this Mac only)"), ("::1", "Loopback IPv6 — ::1 (this Mac only)")
        ]
        options += interfaces.map {
            let tailnet = IPAddressLiteral($0.address)?.isTailnet == true
            return ($0.address, tailnet ? "Tailscale — \($0.address) (\($0.interface))" : "\($0.interface) — \($0.address)")
        }
        options += [("0.0.0.0", "All IPv4 interfaces — 0.0.0.0"), ("::", "All IPv6 interfaces — ::")]
        if !options.contains(where: { $0.address == draft.bindAddress }) { options.append((draft.bindAddress, "\(draft.bindAddress) (unavailable)")) }
        return options
    }

    private func masked(_ token: String) -> String {
        "\(RemoteAgentToken.prefix)••••••••••••••••\(token.suffix(4))"
    }

    private func reset(to settings: RemoteAgentSettings) {
        draft = settings
        port = Int(settings.port)
    }

    private func commit(_ settings: RemoteAgentSettings) {
        message = controller.apply(settings) ? "Remote agent settings saved." : "Choose a valid interface and a port from 1024 to 65535."
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = "Copied."
    }
}
