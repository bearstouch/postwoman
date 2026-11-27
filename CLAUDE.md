# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/claude-code) when working with this codebase.

## Project Overview

PostWoman 💅 is a native macOS REST API client built with SwiftUI and SwiftData. It's a Postman clone designed for testing REST APIs with folder organization and code generation.

## Toolchain and commands

Requires Xcode 26 / Swift 6.2 (Swift 6 language mode, strict concurrency), macOS 14+. The app is a
Swift package (`Package.swift`); there is no `.xcodeproj` (open `Package.swift` in Xcode if needed).

```sh
swift build                                    # build (must be warning-free)
swift test                                     # XCTest suite
swift test --filter PostWomanTests.CURLGeneratorTests   # one test class
swift format -i -r Sources Tests               # format (config: .swift-format)
swift format lint --strict -r Sources Tests    # lint: must print nothing
swift run PostWoman                            # run unbundled (store: ~/Library/Application Support/PostWoman Dev)
swift run postwoman-cli help                   # the CLI (bundled as Contents/Helpers/postwoman); needs the app's MCP server on
scripts/run-app.sh [--build-only]              # assemble, ad-hoc sign (sandboxed, com.bearstouch.postwoman.dev), verify (and open) .build/PostWoman.app
scripts/package-release.sh                     # Universal 2 DMG; ad-hoc unless POSTWOMAN_SIGN_IDENTITY / POSTWOMAN_NOTARY_PROFILE
scripts/package-thin-release.sh                # Apple silicon + Intel DMGs from dist/PostWoman.app
scripts/generate-app-icon.sh                   # iconset + AppIcon.icns (+ swift run icon) from Design/AppIcon/PostWoman*.svg
```

Always run format + lint + build + test before committing. CI (`.github/workflows/ci.yml`) runs
the same steps on `macos-26`, and fails on any warning in `Sources/`.

## Releases

- Version, bundle identifier, minimum macOS and architectures live in `release/manifest.json`.
  `AppVersion.release` must match it (`AppVersionTests`); bump both and add a `## [x.y.z]`
  section to `CHANGELOG.md` (it becomes the GitHub release notes).
- Push tag `vX.Y.Z` (must equal the manifest version) to run `.github/workflows/release.yml`:
  test, sign (Developer ID secrets optional, else ad-hoc + pre-release), package the three DMGs,
  notarize when credentials exist, publish with `SHA256SUMS.txt` and `release-evidence.json`.
- The app is signed with the hardened runtime and `release/PostWoman.entitlements` (App Sandbox,
  network client, user-selected files). The SwiftData store lives in that container, which is keyed by
  the bundle identifier `com.bearstouch.postwoman`: changing it orphans users' data. Releases up
  to 0.9.0 used `com.postwoman.app`.
- SwiftPM has no asset catalog: the icon is `Design/AppIcon/AppIcon.icns` (copied into the bundle)
  and the accent (pink by default) is `Color.appAccent`, applied with `.themedScene()` at each scene root.
  Use it instead of `Color.accentColor`.

### Themes
- Colors come from the light and dark `ThemePalette` chosen in Settings → Appearance, held by the observable
  `ThemeStore.shared` (UserDefaults keys in `ThemeStore.Key`). SwiftUI views use `Theme.*` (`Utilities/AppStyle.swift`),
  which reads the store so views redraw on change; AppKit code views use `CodePalette`, which resolves while drawing,
  and redraw when the `themeRevision` passed to them changes. Never hard-code a surface or syntax color.
- `Utilities/ThemeCatalog.swift` is generated from Trellis's `Sources/TrellisCore/Resources/Themes/*.theme.json`
  (UI colors → surfaces, ANSI colors → JSON syntax, nudged to 4.5:1 on the field). `ThemeStoreTests` checks contrast.
- Every line is the theme's border color (`Theme.hairline`): use `HairlineDivider()` instead of `Divider()` (except
  in menus) and `.textFieldStyle(.themed)` instead of `.roundedBorder`. Split views get `.themedSplitDividers()` on
  a pane inside them, and windows get `ThemedWindowChrome()` (no system titlebar separator).

### Remote Agent (MCP server)
- `RemoteAgent/` ports Trellis's `TrellisMCP`: `MCPHTTP.swift` (bounded HTTP/1.1 parser), `MCPListener.swift` (TCP, one thread
  per connection, 16 connections), `MCPEndpoint.swift` (Streamable HTTP at `/mcp`: Origin and loopback Host checks, sessions,
  bearer token on every request, auth rate limit) and `MCPTools.swift` (the tool catalog: names, closed schemas, annotations).
- `MCPToolHandler` runs every tool on the main actor against the main SwiftData context, so the windows update at once. Before an
  agent deletes models it posts `.remoteAgentWillDelete` so `ContentView` drops selections of them. Credentials are write-only.
- Settings live in UserDefaults (`remoteAgent.settings`); the token (`pwm_…`) is a 0600 file in Application Support.
  `RemoteAgentController` (environment object of the Settings scene) applies them; it is started in `PostWomanApp.init`.
- Adding a tool: declare it in `MCPTools.all` and handle it in `MCPToolHandler.run`; `MCPServerTests` checks every tool is dispatched.
- Listening needs `com.apple.security.network.server` in `release/PostWoman.entitlements`.

### CLI (`postwoman`)
- `Sources/PostWomanCLI` (library) + `PostWomanCLIMain` (product `postwoman-cli`, renamed `postwoman` in the bundle; the names
  differ only so they don't clash with `PostWoman` in `.build`). It is an MCP client of the app: no app code is shared, so it
  has its own `JSONValue`. Every side effect goes through `CLIEnvironment`, so tests use fakes.
- `CLICommands.all` maps each `noun verb` to a tool and its flags. Adding an MCP tool means adding a command:
  `CLIContractTests` fails otherwise, and checks every flag builds arguments the tool's schema accepts.
- It finds the token and URL in the app's container (`AppLocation`: release, dev, `swift run`), trying each until one answers.
- The scripts sign `Contents/Helpers/postwoman` (hardened runtime, not sandboxed) before sealing the app. `CLI.version` must
  match `AppVersion.release`.

## Architecture

### Data Models (SwiftData)

All models are in `Sources/PostWoman/Models/`:

- **`Folder`** - Collection containers with nested hierarchy (parent/subfolders relationship)
- **`APIRequest`** - Request configuration (URL, method, headers, body, auth)
- **`RequestHistory`** - Request/response logging

### Key Services

Located in `Sources/PostWoman/Services/`:

- **`HTTPClient`** - `@MainActor` URLSession wrapper for executing requests (it reads SwiftData models, which belong to the main context; never pass `@Model` objects to other actors)
- **`AuthenticationHandler`** - Applies Bearer/Basic auth to requests
- **`CodeGenerator/`** - Generates cURL, Swift, Python code from requests

### View Structure

The app uses a 3-column `NavigationSplitView`:

1. **Primary**: Workspace categories (History) and Collections (Folder list)
2. **Content**: Request list for the selected folder or History list
3. **Detail**: Request editor and response viewer

## Important Conventions

### Naming
- Response body property in views is named `responseBody` to avoid conflicts with SwiftUI's `body` computed property

### Notifications
Menu commands use `NotificationCenter` to communicate with views:
- `.createNewRequest`
- `.createNewFolder`
- `.sendRequest`
- `.saveRequest`
- `.duplicateRequest`
- `.generateCode`

### SwiftData Relationships
- `Folder` has cascade delete rules for both `subfolders` and `requests`

## File Organization

```
Sources/PostWoman/
├── App/
│   ├── PostWomanApp.swift      # @main entry, ModelContainer setup, unbundled-run AppDelegate
│   ├── AppVersion.swift        # Release version (matches release/manifest.json)
│   ├── ContentView.swift       # Root NavigationSplitView
│   └── AppCommands.swift       # Menu commands and shortcuts
├── Models/                     # SwiftData @Model classes
├── Views/
│   ├── Sidebar/               # HistoryListView, FolderRequestsListView, FolderRowView, etc.
│   ├── RequestEditor/         # URLBarView, tab views
│   ├── ResponseViewer/        # Response display components
│   ├── CodeGeneration/        # Code generator sheet
│   ├── Settings/              # Settings window (General, Appearance)
│   └── Shared/                # Reusable components
├── RemoteAgent/               # MCP server (listener, endpoint, tools)
├── Services/                  # Business logic
└── Utilities/                 # Helpers (JSONFormatter, AppStyle, ThemeStore, ThemeCatalog)
Sources/PostWomanCLI/          # the postwoman command (MCP client); PostWomanCLIMain/main.swift runs it
Tests/PostWomanTests/          # XCTest (@testable import PostWoman, PostWomanCLI)
release/                       # manifest.json, PostWoman.entitlements
scripts/                       # run-app, package-release, package-thin-release, make-dmg, generate-app-icon
Design/                        # AppIcon (iconset + icns), DMG background (make-background.swift)
```

## Common Tasks

### Adding a New HTTP Method
1. Add case to `HTTPMethod` enum in `Models/HTTPMethod.swift`
2. Assign a color for the method badge

### Adding a New Code Generator
1. Create new generator struct in `Services/CodeGenerator/`
2. Add case to `CodeLanguage` enum in `CodeGeneratorView.swift`
3. Call generator in `generateCode()` function

### Adding a New Auth Type
1. Add case to `AuthenticationType` enum
2. Add UI in `AuthTabView.swift`
3. Handle in `AuthenticationHandler.swift`
