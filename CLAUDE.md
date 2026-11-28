# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/claude-code) when working with this codebase.

## Project Overview

Reqs is a native macOS REST API client built with SwiftUI and SwiftData. It's a Postman alternative designed for testing REST APIs with folder organization and code generation.

## Toolchain and commands

Requires Xcode 26 / Swift 6.2 (Swift 6 language mode, strict concurrency), macOS 14+. The app is a
Swift package (`Package.swift`); there is no `.xcodeproj` (open `Package.swift` in Xcode if needed).

```sh
swift build                                    # build (must be warning-free)
swift test                                     # XCTest suite
swift test --filter ReqsTests.CURLGeneratorTests   # one test class
swift format -i -r Sources Tests               # format (config: .swift-format)
swift format lint --strict -r Sources Tests    # lint: must print nothing
swift run Reqs                            # run unbundled (store: ~/Library/Application Support/Reqs Dev)
swift run reqs-cli help                   # the CLI (bundled as Contents/Helpers/reqs); needs the app's MCP server on
scripts/run-app.sh [--build-only]              # assemble, ad-hoc sign (sandboxed, com.bearstouch.reqs.dev), verify (and open) .build/Reqs.app
scripts/package-release.sh                     # Universal 2 DMG; ad-hoc unless REQS_SIGN_IDENTITY / REQS_NOTARY_PROFILE
scripts/package-thin-release.sh                # Apple silicon + Intel DMGs from dist/Reqs.app
python3 -I scripts/test-update-appcast.py      # appcast generator checks (CI runs them)
scripts/generate-app-icon.sh                   # iconset + AppIcon.icns (+ swift run icon) from Design/AppIcon/Reqs*.svg
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
- The app is signed with the hardened runtime and `release/Reqs.entitlements` (App Sandbox,
  network client, user-selected files). The SwiftData store lives in that container, which is keyed by
  the bundle identifier `com.bearstouch.reqs`: changing it orphans users' data. Releases up
  to 0.9.0 used `com.postwoman.app`, then `com.bearstouch.postwoman` as PostWoman.
- The app was called PostWoman (bundle ID `com.bearstouch.postwoman`) up to 0.11.0. Reqs has its own bundle ID, so it is
  a separate app with its own container: PostWoman's data stays with PostWoman (users move collections with Export/Import),
  and PostWoman can't update itself into Reqs.
- SwiftPM has no asset catalog: the icon is `Design/AppIcon/AppIcon.icns` (copied into the bundle)
  and the accent (electric blue by default; pink, the old default, is still a choice) is `Color.appAccent`, applied with `.themedScene()` at each scene root.
  Use it instead of `Color.accentColor`.

### Updates (Sparkle)
- Ported from Trellis. `Services/Updates/`: `UpdateFeed` (needs an HTTPS `SUFeedURL` and an `SUPublicEDKey` in Info.plist), `UpdatePreferences`
  (beta opt-in, `ReqsIncludeBetaUpdates`), the `SoftwareUpdater` protocol and `UpdateSettingsModel`; `SparkleUpdater` is the only Sparkle code.
  Builds without a feed (`swift run`, `scripts/run-app.sh`, tests) get no updater: no menu item, no Settings → Updates, no network.
- `scripts/package-release.sh` writes the feed keys only when `release/manifest.json` has `sparklePublicKey`. The feed is
  `appcast.xml` on the orphan `appcast` branch, which `release.yml` updates (`scripts/update-appcast.py`, tested by
  `scripts/test-update-appcast.py`) for notarized tag builds when the `SPARKLE_ED_PRIVATE_KEY` secret is set.
- Unlike Trellis, Reqs is sandboxed: Sparkle installs through `Installer.xpc` (`SUEnableInstallerLauncherService`, and the
  `com.bearstouch.reqs-spks`/`-spki` mach-lookup exceptions in the entitlements). `scripts/sign-sparkle.sh` drops `Downloader.xpc`
  (the app has network.client), thins and signs the framework inside-out. Ad-hoc package builds add `disable-library-validation`.
- `CFBundleShortVersionString` is the numeric `X.Y.Z`, `CFBundleVersion` `X.Y.Z.<build>` (alpha.N = N, beta.N = 30+N, rc.N = 60+N,
  release = 100; Sparkle compares it), and `ReqsVersion` the full version that `AppVersion.current` shows.

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
- `MCPToolHandler` runs every tool on the main actor against the main SwiftData context, so the windows update at once. It saves
  pending changes before a tool runs, so the rollback after a tool error undoes only the tool's own writes, never the user's. Before an
  agent deletes models it posts `.remoteAgentWillDelete` so `ContentView` drops selections of them. Credentials are write-only.
- Settings live in UserDefaults (`remoteAgent.settings`); the token (`pwm_…`) is a 0600 file in Application Support.
  `RemoteAgentController` (environment object of the Settings scene) applies them; it is started in `ReqsApp.init`.
- Adding a tool: declare it in `MCPTools.all` and handle it in `MCPToolHandler.run`; `MCPServerTests` checks every tool is dispatched.
- Listening needs `com.apple.security.network.server` in `release/Reqs.entitlements`.

### CLI (`reqs`)
- `Sources/ReqsCLI` (library) + `ReqsCLIMain` (product `reqs-cli`, renamed `reqs` in the bundle; the names
  differ only so they don't clash with `Reqs` in `.build`). It is an MCP client of the app: no app code is shared, so it
  has its own `JSONValue`. Every side effect goes through `CLIEnvironment`, so tests use fakes.
- `CLICommands.all` maps each `noun verb` to a tool and its flags. Adding an MCP tool means adding a command:
  `CLIContractTests` fails otherwise, and checks every flag builds arguments the tool's schema accepts.
- It finds the token and URL in the app's container (`AppLocation`: release, dev, `swift run`), trying each until one answers.
- The scripts sign `Contents/Helpers/reqs` (hardened runtime, not sandboxed) before sealing the app. `CLI.version` must
  match `AppVersion.release`.

## Architecture

### Data Models (SwiftData)

All models are in `Sources/Reqs/Models/`:

- **`Folder`** - A collection: a flat list of requests and its environments (no nested folders)
- **`APIRequest`** - Request configuration (URL, method, headers, body, auth)
- **`RequestHistory`** - Request/response logging (what was sent, resolved, secrets left as `{{name}}`, plus `environmentName`)
- **`CollectionEnvironment`** - A collection's `{{variable}}` set (`[Variable]`). Every `Folder` has one `isDefault` environment
  (made by `ensureDefaultEnvironment()`, and at launch by `AppSchema.migrate`) plus overrides; `Folder.selectedEnvironmentID`
  (nil = Default only) picks the override. `AppSchema.models` is the one model list (app, previews, tests)

### Variables
- `VariableResolver` (`Services/Variables/`) resolves `{{name}}`: the selected environment's enabled variables over Default's;
  unknown names are sent as written. `Folder.variableResolver` builds it. Send, `request_execute` and Generate Code resolve a
  `RequestSnapshot` (plain values, `RequestFields`), never the `@Model`; `HTTPClient.execute` sends what it is given.
- Secrets (`Variable.isSecret`) are masked in the UI, `redactSecrets: true` for History and code, exported empty, and
  write-only over MCP (reads return `value: null`).

### Key Services

Located in `Sources/Reqs/Services/`:

- **`HTTPClient`** - `@MainActor` URLSession wrapper for executing requests (it reads SwiftData models, which belong to the main context; never pass `@Model` objects to other actors)
- **`AuthenticationHandler`** - Applies Bearer/Basic auth to requests (`basicCredentials`: a field never typed counts as empty; the generators use it too)
- **`MultipartForm`** - A Form Data body keeps its fields as `a=1&b=2` (`FormBody`); sending and generated code turn them into
  `multipart/form-data` parts, unless the request sets its own Content-Type (then the body goes as written)
- **`RequestTimeout`** - The timeout from Settings → General (`defaultTimeout`, 1…600 s), read by `HTTPClient` at each send. Requests
  also bypass URLCache (`.reloadIgnoringLocalCacheData`), and response text follows the declared charset (`HTTPClient.text`)
- **`CodeGenerator/`** - Generates cURL, Swift, Python code from requests
- **`Streaming/`** - Streamed responses. `HTTPClient.execute(request:onProgress:)` runs a data task with a per-task
  `StreamingTaskDelegate` (chunks + metrics). For `text/event-stream`/NDJSON (`StreamKind`) it feeds `StreamEventParser`
  and `StreamTextAssembler` (LLM deltas → `StreamInfo.text`), calls `onProgress` ~10×/s, and on cancellation returns the
  partial response with `stream.end == .stopped`. `RequestHistory.responseStreamData` keeps the encoded `StreamInfo`

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

Every window hears these, so each view checks `commandWindow.acceptsCommands` (`App/CommandTarget.swift`: only the frontmost
main window acts) before handling one. `ContentDetailView` gives the editor `.id(request.id)`: its `@State` must never carry
over to another request.

### SwiftData Relationships
- `Folder` has cascade delete rules for its `requests` and `environments`

## Code style

- Match the surrounding code: compact, dense Swift (220 columns, 4-space indent, `.swift-format`); short
  `guard … else { …; return }` bodies are normal. `///` doc comments say what a type or property is for and *why*;
  inline comments are sparse.
- Concurrency: `@MainActor` for views, `HTTPClient` and `MCPToolHandler` (they touch SwiftData models). Pass plain
  `Sendable` value types (`RequestSnapshot`, `HTTPResponse`, `StreamInfo`) across tasks, never `@Model` objects. Delegates
  URLSession calls on its own queue are `Sendable`, with state behind `OSAllocatedUnfairLock`.
- UI: `Theme.*` colors and `Color.appAccent`, never hard-coded colors; `HairlineDivider()`, `.textFieldStyle(.themed)`,
  `.themedSplitDividers()` (see Themes). Name a view's body text `responseBody`, not `body`.
- Accessibility in every view: icon-only buttons get `.help` and `.accessibilityLabel`; selected state and status are
  never shown by color alone.
- MCP error codes are SCREAMING_SNAKE strings (`INVALID_PARAMS`, `REQUEST_FAILED`); tool output is JSON with camelCase keys.
  The CLI prints data on stdout and summaries/notes on stderr, like curl.
- User-facing text is plain and specific ("Sent as written, because…"); no marketing tone.

## Tests

- XCTest in `Tests/ReqsTests`, one class per area (`CURLGeneratorTests`, `StreamEventParserTests`…), with descriptive
  test names that state the behavior (`testStoppingAStreamKeepsWhatArrived`). Keep existing names stable.
- Assert observable behavior and failure safety: what the user, History, an agent or the CLI would see, and that a failure
  leaves earlier state intact (rollback on tool errors, partial responses kept).
- Keep tests deterministic and offline:
  - SwiftData: `ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))`.
  - Network: a `URLProtocol` stub in an ephemeral `URLSessionConfiguration` passed to `HTTPClient(session:)`
    (`StreamingStubProtocol`), or an `MCPListener` on `127.0.0.1:0` as a real target server.
  - CLI: fake `CLIEnvironment` (no real files, sockets or stdout).
  - Views: decisions live in internal types or `static func`s beside the view (`ResponseBodyFormat`, `SidebarActions`,
    `EnvironmentActions`, `ContentSelection`, `RemoteAgentSettingsForm`…) and get unit tests; the view itself is hosted with
    `ViewHosting` (`Tests/ReqsTests/ViewHostingSupport.swift`) in light and dark, and tests assert what VoiceOver gets
    (labels, help, values, `isSelected`) and that no secret is exposed. Toolbars and list rows need a titled window.
  - UserDefaults: a suite with a unique name (`"Area.\(UUID().uuidString)"`), removed afterwards; never a fixed name, which other runs share.
- A bug fix comes with a test that fails without it (run it against the old code once). Generated code is checked by running it:
  cURL through `/bin/sh`, Python with `python3 -I -W error` against a stubbed `requests`, Swift compiled with `swiftc` behind a stub.
- Contract tests that must keep passing: `MCPServerTests` (every tool dispatched, closed schemas), `CLIContractTests`
  (every MCP tool has a command and valid flags), `AppVersionTests` (versions match the manifest), `ThemeStoreTests` (contrast).
- Each new parser, generator or service gets unit tests for its edge cases (chunk boundaries, encodings, empty input);
  each new MCP field gets an `MCPToolHandler` assertion.

## Change workflow

1. Read the code involved and this file. For larger features, plan first: files to touch, existing helpers to reuse,
   tests, and how to verify it end to end.
2. Implement with tests (observable behavior + failure safety). Keep the app, MCP tools and CLI in step: a capability
   added to the app's send path should reach `request_execute` and `reqs` too.
3. Format, lint, build, test, all clean: `swift format -i -r Sources Tests`, `swift format lint --strict -r Sources Tests`
   (no output), `swift build` (no warnings), `swift test`.
4. For non-trivial changes, run an independent review (fresh eyes: correctness, races, leaks, data loss, security of the
   MCP server and secrets, regressions, test gaps). Fix what matters, then format, lint, build and test again.
5. Check UI changes in the real app (`scripts/run-app.sh`); a local test server (e.g. a small Python `http.server`) stands
   in for real APIs.
6. Record what was verified and what wasn't. Update `CHANGELOG.md` (`## [Unreleased]`, or the next version section) for
   anything user-visible, and this file when architecture or conventions change.
7. Commit on `develop` with a short imperative subject ("Add environments for each collection, with {{variables}}") and a
   body explaining what changed for the user; `master` gets it through a pull request. Releases follow "Releases" above.

Honesty rules: say what was actually run and observed. Checks that can't be done here (VoiceOver, notarization, Sparkle
installs, Intel or older macOS, real third-party APIs) are reported as **not verified**, never as passed. Report blockers
instead of faking results.

## File Organization

```
Sources/Reqs/
├── App/
│   ├── ReqsApp.swift      # @main entry, ModelContainer setup, unbundled-run AppDelegate
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
Sources/ReqsCLI/          # the reqs command (MCP client); ReqsCLIMain/main.swift runs it
Tests/ReqsTests/          # XCTest (@testable import Reqs, ReqsCLI)
release/                       # manifest.json, Reqs.entitlements
scripts/                       # run-app, package-release, package-thin-release, make-dmg, generate-app-icon
Design/                        # AppIcon (iconset + icns), DMG background (make-background.swift)
```

## Common Tasks

### Adding a New HTTP Method
1. Add case to `HTTPMethod` enum in `Models/HTTPMethod.swift` (case order is the menu order; raw values are stored and exported)
2. Assign a color for the method badge, and say in `sendsBody` whether it carries a body (GET and HEAD don't: everything that sends
   or generates a body checks `RequestFields.sendsBody`)
3. Add it to `CLICommands.methods` (`CLIContractTests` checks it matches `MCPTools.methods`) and to the cURL and Python
   generators' tests, which run the generated code (cURL needs `-I` for HEAD, not `-X HEAD`)

### Adding a New Code Generator
1. Create new generator struct in `Services/CodeGenerator/`
2. Add case to `CodeLanguage` enum in `CodeGeneratorView.swift`
3. Call generator in `generateCode()` function

### Adding a New Auth Type
1. Add case to `AuthenticationType` enum
2. Add UI in `AuthTabView.swift`
3. Handle in `AuthenticationHandler.swift`
