import SwiftUI

/// Settings → Updates: the running version, Check Now, and the automatic-check and beta choices.
struct UpdateSettingsView: View {
    let updates: UpdateSettingsModel

    var body: some View {
        Form {
            Section("Current version") {
                LabeledContent {
                    Button("Check Now") { updates.checkNow() }.disabled(!updates.canCheck)
                } label: {
                    SettingsLabel(updates.version, help: lastCheckText)
                }
            }
            Section("Automatic updates") {
                Toggle(isOn: Binding(get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) })) {
                    SettingsLabel(
                        "Automatically check for updates", help: "Checks once a day. Reqs only downloads the update list; it sends no usage data.")
                }
                Toggle(isOn: Binding(get: { updates.includeBetas }, set: { updates.setIncludeBetas($0) })) {
                    SettingsLabel("Include beta versions", help: "Offers pre-release builds as well as stable ones.")
                }
            }
        }
        .settingsFormStyle()
        .onAppear { updates.refresh() }
    }

    private var lastCheckText: String { Self.lastCheckText(updates.lastCheck) }

    /// The version row's help: when Sparkle last checked, or that it never has.
    static func lastCheckText(_ date: Date?) -> String {
        guard let date else { return "Never checked" }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// The app menu's Check for Updates… item; disabled while Sparkle is busy.
struct CheckForUpdatesButton: View {
    let updates: UpdateSettingsModel

    var body: some View {
        Button("Check for Updates…") { updates.checkNow() }.disabled(!updates.canCheck)
    }
}
