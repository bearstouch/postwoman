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
    /// - CollectionEnvironment: Each collection's Default and other environments ({{variables}})
    let sharedModelContainer: ModelContainer

    /// The MCP server agents use (Settings → Remote Agent). It works on the same main context as the windows.
    @State private var remoteAgent: RemoteAgentController

    /// Sparkle, only in packaged builds with an update feed (Settings → Updates, Check for Updates…).
    @State private var updates: UpdateSettingsModel?

    init() {
        let container = Self.makeModelContainer()
        sharedModelContainer = container
        AppSchema.migrate(container.mainContext)
        let remoteAgent = RemoteAgentController(container: container)
        remoteAgent.start()
        _remoteAgent = State(initialValue: remoteAgent)
        _updates = State(initialValue: SparkleUpdater().map { UpdateSettingsModel(updater: $0) })
    }

    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema(AppSchema.models)

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
            AppCommands(updates: updates)
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1300, height: 850)

        Settings {
            SettingsView(updates: updates)
                .environment(remoteAgent)
                .themedScene()
        }
        .modelContainer(sharedModelContainer)
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
