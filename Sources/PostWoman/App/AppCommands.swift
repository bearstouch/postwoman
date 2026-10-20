import SwiftUI

/// Defines the application menu commands and keyboard shortcuts for PostWoman.
/// This struct configures the main menu bar items that allow users to perform
/// common actions like creating requests, sending requests, and managing environments.
/// Commands communicate with views using NotificationCenter to maintain loose coupling.
struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    /// The command menu structure containing File, Request, and Environment menus.
    /// Each menu item posts notifications that are observed by relevant views.
    var body: some Commands {
        // Replace the default About menu item with custom About window
        CommandGroup(replacing: .appInfo) {
            Button("About PostWoman") {
                openWindow(id: "about")
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

    }
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
