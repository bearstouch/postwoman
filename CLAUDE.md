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
scripts/run-app.sh [--build-only]              # assemble, ad-hoc sign (sandboxed, com.bearstouch.postwoman.dev), verify (and open) .build/PostWoman.app
scripts/package-release.sh                     # Universal 2 DMG; ad-hoc unless POSTWOMAN_SIGN_IDENTITY / POSTWOMAN_NOTARY_PROFILE
scripts/package-thin-release.sh                # Apple silicon + Intel DMGs from dist/PostWoman.app
scripts/generate-app-icon.sh                   # AppIcon.icns (+ swift run icon) from Design/AppIcon/AppIcon.iconset
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
  and the pink accent is `Color.postWomanPink`, applied with `.tint` at each scene root. Use it
  instead of `Color.accentColor`.

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
│   └── Shared/                # Reusable components
├── Services/                  # Business logic
└── Utilities/                 # Helpers (JSONFormatter, AppStyle)
Tests/PostWomanTests/          # XCTest (@testable import PostWoman)
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
