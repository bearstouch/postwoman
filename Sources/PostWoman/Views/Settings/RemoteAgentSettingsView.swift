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

    private var candidate: RemoteAgentSettings { RemoteAgentSettingsForm.candidate(draft, port: port) }

    var body: some View {
        VStack(spacing: 0) {
            form
            HairlineDivider()
            HStack {
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Apply") {
                    let settings = candidate
                    if RemoteAgentSettingsForm.needsNetworkConfirmation(settings, saved: controller.settings) {
                        confirmingNetwork = true
                    } else {
                        commit(settings)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!RemoteAgentSettingsForm.canApply(draft: draft, port: port, saved: controller.settings, status: controller.status))
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .alert("Allow connections from the network?", isPresented: $confirmingNetwork) {
            Button("Cancel", role: .cancel) {}
            Button("Allow Network Access", role: .destructive) { commit(candidate) }
        } message: {
            Text(RemoteAgentSettingsForm.networkWarning(address: draft.bindAddress))
        }
        .alert("Regenerate the access token?", isPresented: $confirmingRegenerate) {
            Button("Cancel", role: .cancel) {}
            Button("Regenerate", role: .destructive) {
                controller.regenerateToken()
                revealToken = false
                message = RemoteAgentSettingsForm.regeneratedMessage
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
                    ForEach(RemoteAgentSettingsForm.addressOptions(interfaces: interfaces, selected: draft.bindAddress), id: \.address) {
                        Text($0.label).tag($0.address)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Listen on")
                        Text(RemoteAgentSettingsForm.exposureNote(for: draft.bindAddress)).font(.subheadline)
                            .foregroundStyle(draft.isLoopback ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.warning))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityHint("The network address the MCP server accepts connections on.")
                LabeledContent {
                    TextField("Port", value: $port, format: .number.grouping(.never))
                        .labelsHidden().multilineTextAlignment(.trailing).frame(maxWidth: 90)
                        .textFieldStyle(.themed)
                } label: {
                    SettingsLabel("Port (1024–65535)", help: RemoteAgentSettingsForm.portHelp(port))
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
                        Text(verbatim: RemoteAgentSettingsForm.shownToken(controller.token, revealed: revealToken))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1).truncationMode(.middle)
                            .accessibilityLabel(RemoteAgentSettingsForm.tokenAccessibilityLabel(controller.token, revealed: revealToken))
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
                            ForEach(MCPClientSetup.allCases, id: \.self) { setup in
                                Button(RemoteAgentSettingsForm.menuTitle(setup)) { copy(setup.snippet(url: controller.clientURL)) }
                            }
                            if let command = MCPClientSetup.cliInstallCommand(bundlePath: Bundle.main.bundlePath) {
                                Divider()
                                Button("Command-line tool (install link)") { copy(command) }
                            }
                        }
                        .fixedSize()
                        .disabled(!controller.settings.mcpEnabled)
                    }
                } label: {
                    SettingsLabel("Connect an agent", help: RemoteAgentSettingsForm.connectHelp)
                }
            }
        }
        .settingsFormStyle()
    }

    private var statusRow: some View {
        let (symbol, text) = RemoteAgentSettingsForm.statusLine(controller.status)
        return Label(text, systemImage: symbol)
            .textSelection(.enabled)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Server status: \(text)")
    }

    private func reset(to settings: RemoteAgentSettings) {
        draft = settings
        port = Int(settings.port)
    }

    private func commit(_ settings: RemoteAgentSettings) {
        message = RemoteAgentSettingsForm.commitMessage(saved: controller.apply(settings))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = RemoteAgentSettingsForm.copiedMessage
    }
}

/// The decisions behind Settings → Remote Agent (when Apply is enabled and what it does, what each row says), kept
/// out of the view so tests can check them.
enum RemoteAgentSettingsForm {
    static let regeneratedMessage = "New token created. Agents using the old one must be set up again."
    static let copiedMessage = "Copied."
    static let connectHelp =
        "Replace <TOKEN> with the access token, or set \(MCPClientSetup.tokenVariable) for Codex. The snippets never contain the token itself. The postwoman command finds the token on its own."

    static func isValidPort(_ port: Int) -> Bool {
        port >= Int(RemoteAgentSettings.portRange.lowerBound) && port <= Int(RemoteAgentSettings.portRange.upperBound)
    }

    /// The port row's help: nil while the port is usable.
    static func portHelp(_ port: Int) -> String? { isValidPort(port) ? nil : "Use a port from 1024 to 65535." }

    /// The draft with the port field's value. An out-of-range port is clamped here; `isValidPort` keeps it from being applied.
    static func candidate(_ draft: RemoteAgentSettings, port: Int) -> RemoteAgentSettings {
        var settings = draft
        settings.port = UInt16(clamping: port)
        return settings
    }

    /// Apply is enabled for a valid change, or to retry a failed start (for example, port in use) with the same settings
    /// once the cause is fixed.
    static func canApply(draft: RemoteAgentSettings, port: Int, saved: RemoteAgentSettings, status: RemoteAgentStatus) -> Bool {
        let candidate = candidate(draft, port: port)
        let retryable: Bool
        if case .failed = status { retryable = true } else { retryable = false }
        return isValidPort(port) && candidate.isValid && (candidate != saved || retryable)
    }

    /// Turning on a non-loopback address needs a confirmation, unless the server is already on at that address.
    static func needsNetworkConfirmation(_ settings: RemoteAgentSettings, saved: RemoteAgentSettings) -> Bool {
        let alreadyExposed = saved.mcpEnabled && saved.bindAddress == settings.bindAddress
        return settings.mcpEnabled && !settings.isLoopback && !alreadyExposed
    }

    static func networkWarning(address: String) -> String {
        "Devices that can reach \(address) will be able to connect. Anyone who obtains the access token can then read and change your collections and history, and send requests from this Mac. Traffic is not encrypted."
    }

    /// Spoken and visible, not color-only: how far the chosen address reaches.
    static func exposureNote(for address: String) -> String {
        if RemoteAgentSettings(bindAddress: address).isLoopback { return "Only programs on this Mac can connect." }
        return IPAddressLiteral(address)?.isTailnet == true
            ? "Devices in your tailnet can reach this server. Tailscale encrypts the traffic, but the server itself uses plain HTTP."
            : "Other devices on the network can reach this server. Requests use plain HTTP, so the access token is sent unencrypted."
    }

    /// The Listen on choices: loopback, this Mac's interfaces, the wildcards, and the selected address when it is none of those.
    static func addressOptions(interfaces: [NetworkInterfaceAddress], selected: String) -> [(address: String, label: String)] {
        var options: [(address: String, label: String)] = [
            ("127.0.0.1", "Loopback — 127.0.0.1 (this Mac only)"), ("::1", "Loopback IPv6 — ::1 (this Mac only)")
        ]
        options += interfaces.map {
            let tailnet = IPAddressLiteral($0.address)?.isTailnet == true
            return ($0.address, tailnet ? "Tailscale — \($0.address) (\($0.interface))" : "\($0.interface) — \($0.address)")
        }
        options += [("0.0.0.0", "All IPv4 interfaces — 0.0.0.0"), ("::", "All IPv6 interfaces — ::")]
        if !options.contains(where: { $0.address == selected }) { options.append((selected, "\(selected) (unavailable)")) }
        return options
    }

    /// The token as shown: in full only once revealed, otherwise its prefix and last four characters.
    static func shownToken(_ token: String, revealed: Bool) -> String {
        revealed ? token : "\(RemoteAgentToken.prefix)••••••••••••••••\(token.suffix(4))"
    }

    static func tokenAccessibilityLabel(_ token: String, revealed: Bool) -> String { revealed ? "Token \(token)" : "Token hidden" }

    /// The status row's symbol and text; the text says the state, so it is never shown by the symbol alone.
    static func statusLine(_ status: RemoteAgentStatus) -> (symbol: String, text: String) {
        switch status {
        case .stopped: ("stop.circle", "Stopped")
        case .running(let url): ("checkmark.circle.fill", "Running at \(url)")
        case .failed(let reason): ("exclamationmark.triangle.fill", "Not running: \(reason)")
        }
    }

    static func commitMessage(saved: Bool) -> String {
        saved ? "Remote agent settings saved." : "Choose a valid interface and a port from 1024 to 65535."
    }

    /// The Copy Client Setup menu item for each client.
    static func menuTitle(_ setup: MCPClientSetup) -> String {
        switch setup {
        case .claudeCode: "Claude Code command"
        case .codex: "Codex (config.toml)"
        case .opencode: "OpenCode command"
        case .json: "Generic MCP JSON"
        }
    }
}
