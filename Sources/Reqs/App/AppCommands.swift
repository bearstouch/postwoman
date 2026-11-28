import SwiftUI

/// Defines the application menu commands and keyboard shortcuts for Reqs.
/// This struct configures the main menu bar items that allow users to perform
/// common actions like creating requests, sending requests, and managing environments.
/// Commands communicate with views using NotificationCenter to maintain loose coupling.
struct AppCommands: Commands {
    /// Nil when this build has no update feed; the menu item is left out.
    let updates: UpdateSettingsModel?

    /// The command menu structure containing File, Request, and Environment menus.
    /// Each menu item posts notifications that are observed by relevant views.
    var body: some Commands {
        // The standard About panel, with linked license and copyright credits (as in Trellis)
        CommandGroup(replacing: .appInfo) {
            Button("About Reqs") {
                AboutPanel.show()
            }
            if let updates {
                CheckForUpdatesButton(updates: updates)
            }
        }

        // File menu replacements for creating new items
        CommandGroup(replacing: .newItem) {
            Button("New Request") {
                NotificationCenter.default.post(name: .createNewRequest, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Folder") {
                NotificationCenter.default.post(name: .createNewFolder, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()
        }

        // Request menu with actions for working with API requests
        CommandMenu("Request") {
            Button("Send Request") {
                NotificationCenter.default.post(name: .sendRequest, object: nil)
            }
            .keyboardShortcut(.return, modifiers: .command)

            Divider()

            Button("Save Request") {
                NotificationCenter.default.post(name: .saveRequest, object: nil)
            }
            .keyboardShortcut("s", modifiers: .command)

            Button("Duplicate Request") {
                NotificationCenter.default.post(name: .duplicateRequest, object: nil)
            }
            .keyboardShortcut("d", modifiers: .command)

            Divider()

            Button("Generate Code...") {
                NotificationCenter.default.post(name: .generateCode, object: nil)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
        }

        // Environment menu: the current collection's environments
        CommandMenu("Environment") {
            ForEach(EnvironmentShortcut.all) { shortcut in
                Button(shortcut.title) { shortcut.post() }
                    .keyboardShortcut(shortcut.key, modifiers: .control)
            }

            Divider()

            Button("New Environment…") {
                NotificationCenter.default.post(name: .newEnvironment, object: nil)
            }

            Button("Manage Environments…") {
                NotificationCenter.default.post(name: .manageEnvironments, object: nil)
            }
            .keyboardShortcut("e", modifiers: .command)
        }
    }
}

/// An Environment menu item that picks the current collection's environment by position: ⌃0 Default only, ⌃1…⌃9 the others.
struct EnvironmentShortcut: Identifiable, Sendable {
    /// 0 is Default only; 1… the collection's other environments in order (`.selectEnvironment`'s `userInfo["index"]`).
    let index: Int

    var id: Int { index }

    var title: String { index == 0 ? "Use Default Only" : "Use Environment \(index)" }

    /// The digit, pressed with Control.
    var key: KeyEquivalent { KeyEquivalent(Character("\(index)")) }

    /// Posts `.selectEnvironment` for this position.
    func post(to center: NotificationCenter = .default) {
        center.post(name: .selectEnvironment, object: nil, userInfo: ["index": index])
    }

    /// ⌃0 to ⌃9, in menu order.
    static let all = (0..<10).map { EnvironmentShortcut(index: $0) }
}

/// Extension providing notification names used for inter-view communication.
/// These notifications allow menu commands to trigger actions in views without
/// direct coupling, enabling a more modular architecture.
extension Notification.Name {
    /// Posted when the user wants to create a new API request.
    static let createNewRequest = Notification.Name("createNewRequest")

    /// Posted when the user wants to create a new folder for organizing requests.
    static let createNewFolder = Notification.Name("createNewFolder")

    /// Posted when the user wants to send/execute the current API request.
    static let sendRequest = Notification.Name("sendRequest")

    /// Posted when the user wants to save changes to the current request.
    static let saveRequest = Notification.Name("saveRequest")

    /// Posted when the user wants to duplicate the current request.
    static let duplicateRequest = Notification.Name("duplicateRequest")

    /// Posted when the user wants to generate code for the current request.
    static let generateCode = Notification.Name("generateCode")

    /// Posted when a folder should be expanded (e.g., when a request is added to it).
    static let expandFolder = Notification.Name("expandFolder")
}
