import SwiftUI
import SwiftData

/// The main application structure for PostWoman, a native macOS REST API client.
/// This app provides a Postman-like interface for testing REST APIs with features
/// including request organization, environment variables, and code generation.
@main
struct PostWomanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The shared SwiftData model container that manages all persistent data.
    /// Contains schemas for all core data models used throughout the application.
    /// Creates and configures the SwiftData model container with all application schemas.
    /// This container manages persistent storage for:
    /// - Folders: Hierarchical organization of API requests
    /// - APIRequest: Individual HTTP request configurations
    /// - RequestHistory: Logs of executed requests and responses
    var sharedModelContainer: ModelContainer = {
        // Define the data schema containing all SwiftData models
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
    }()

    /// The main application scene containing the primary window and settings.
    /// Configures the app with SwiftData model container, custom commands,
    /// and window styling optimized for the REST API testing workflow.
    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(.postWomanPink)
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
                .tint(.postWomanPink)
        }

        Window("About PostWoman", id: "about") {
            AboutView()
                .tint(.postWomanPink)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// Gives unbundled runs (`swift run`, VS Code debugging) the Dock icon and activation a packaged app gets from its bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Bundle.main.bundleURL.pathExtension != "app" else { return }
        NSApp.setActivationPolicy(.regular)
        // Bundle.module is only read here: packaged apps use Contents/Resources/AppIcon.icns and do not ship the resource bundle.
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png", subdirectory: "AppIcon"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate()
    }
}

/// The main settings view that provides access to application configuration.
/// Currently contains general settings but can be extended with additional tabs
/// for advanced configuration options.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
        }
        .frame(width: 450, height: 250)
    }
}

/// General application settings view providing configuration for default request behavior.
/// Allows users to customize default timeout values that affect all HTTP requests.
struct GeneralSettingsView: View {
    /// The default timeout value in seconds for HTTP requests, persisted across app launches.
    @AppStorage("defaultTimeout") private var defaultTimeout: Double = 30.0

    var body: some View {
        Form {
            Section("Request Defaults") {
                HStack {
                    Text("Default Timeout (seconds)")
                    Spacer()
                    TextField("Timeout", value: $defaultTimeout, format: .number)
                        .frame(width: 300)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
        .padding()
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
