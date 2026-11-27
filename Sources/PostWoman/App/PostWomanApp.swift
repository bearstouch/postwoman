import SwiftUI
import SwiftData

/// The main application structure for PostWoman, a native macOS REST API client.
/// This app provides a Postman-like interface for testing REST APIs with features
/// including request organization, environment variables, and code generation.
@main
struct PostWomanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The shared SwiftData model container that manages all persistent data:
    /// - Folders: Hierarchical organization of API requests
    /// - APIRequest: Individual HTTP request configurations
    /// - RequestHistory: Logs of executed requests and responses
    let sharedModelContainer: ModelContainer

    /// The MCP server agents use (Settings → Remote Agent). It works on the same main context as the windows.
    @State private var remoteAgent: RemoteAgentController

    init() {
        let container = Self.makeModelContainer()
        sharedModelContainer = container
        let remoteAgent = RemoteAgentController(container: container)
        remoteAgent.start()
        _remoteAgent = State(initialValue: remoteAgent)
    }

    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([
            Folder.self,
            APIRequest.self,
            RequestHistory.self
        ])

        // Configure the model container for persistent storage on disk. Packaged apps are sandboxed and
        // keep the default store in their container; unbundled runs (`swift run`) are not, so they get
        // their own store instead of the shared ~/Library/Application Support/default.store.
        let modelConfiguration: ModelConfiguration
        if Bundle.main.bundleURL.pathExtension == "app" {
            modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        } else {
            let directory = URL.applicationSupportDirectory.appending(path: "PostWoman Dev", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            modelConfiguration = ModelConfiguration(schema: schema, url: directory.appending(path: "PostWoman.store"))
        }

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    /// The main application scene containing the primary window and settings.
    /// Configures the app with SwiftData model container, custom commands,
    /// and window styling optimized for the REST API testing workflow.
    var body: some Scene {
        WindowGroup {
            ContentView()
                .themedScene()
        }
        .modelContainer(sharedModelContainer)
        .commands {
            AppCommands()
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1300, height: 850)

        Settings {
            SettingsView()
                .environment(remoteAgent)
                .themedScene()
        }

        Window("About PostWoman", id: "about") {
            AboutView()
                .themedScene()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// Applies the saved appearance at launch, and gives unbundled runs (`swift run`, VS Code debugging) the Dock icon
/// and activation a packaged app gets from its bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemeStore.shared.applyAppearance()
        guard Bundle.main.bundleURL.pathExtension != "app" else { return }
        NSApp.setActivationPolicy(.regular)
        // Bundle.module is only read here: packaged apps use Contents/Resources/AppIcon.icns and do not ship the resource bundle.
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png", subdirectory: "AppIcon"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate()
    }
}

/// Custom About view displaying app information with clickable license link.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private let appVersion = AppVersion.current
    private let licenseURL = URL(string: "https://github.com/bearstouch/postwoman/blob/master/LICENSE")!

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)

            Text("PostWoman 💅")
                .font(.title)
                .fontWeight(.bold)

            Text("Version \(appVersion)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Made with ❤️ by Bearstouch")
                .font(.body)

            Link("View License on GitHub", destination: licenseURL)
                .font(.body)

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .padding(.top, 8)
        }
        .padding(32)
        .frame(width: 320)
    }
}
