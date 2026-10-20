# Developer Walkthrough

This guide helps developers navigate the PostWoman codebase and understand how to make changes.

## Quick Start

```bash
swift build                 # build (Swift Package Manager)
swift run PostWoman         # run unbundled
scripts/run-app.sh          # run as a sandboxed .build/PostWoman.app
open Package.swift          # or open the package in Xcode
```

## Project Structure Overview

```
Sources/PostWoman/
├── App/                    # Application entry point and configuration
│   ├── PostWomanApp.swift  # @main entry, SwiftData ModelContainer setup
│   ├── ContentView.swift   # Root 3-column NavigationSplitView
│   └── AppCommands.swift   # Menu bar commands and keyboard shortcuts
│
├── Models/                 # SwiftData models (database schema)
│   ├── APIRequest.swift    # HTTP request configuration
│   ├── Folder.swift        # Collection/folder container
│   ├── RequestHistory.swift# Executed request logs
│   ├── HTTPMethod.swift    # GET, POST, PUT, etc. enum
│   ├── ContentType.swift   # Body content type enum
│   ├── AuthenticationType.swift # None, Bearer, Basic, OAuth
│   └── KeyValuePair.swift  # Reusable key-value for headers/params
│
├── Views/
│   ├── Sidebar/            # Left panel components
│   ├── RequestEditor/      # Center panel - request configuration
│   ├── ResponseViewer/     # Bottom panel - response display
│   ├── CodeGeneration/     # Code export modal
│   └── Shared/             # Reusable UI components
│
├── Services/               # Business logic layer
│   ├── HTTPClient.swift    # Network request execution
│   ├── AuthenticationHandler.swift
│   ├── ExportImportService.swift
│   └── CodeGenerator/      # cURL, Swift, Python generators
│
└── Utilities/
    └── JSONFormatter.swift # JSON pretty-printing
```

## Understanding the UI Architecture

PostWoman uses a **3-column NavigationSplitView**:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              Toolbar                                     │
├──────────────┬───────────────┬──────────────────────────────────────────┤
│   SIDEBAR    │    CONTENT    │              DETAIL                       │
│              │               │                                           │
│  • History   │  Request List │  ┌─────────────────────────────────────┐  │
│              │  for selected │  │ Request Name          [folder]      │  │
│  Collections │  folder       │  ├─────────────────────────────────────┤  │
│  • Folder 1  │               │  │ [GET ▼] [URL input field] [Send]    │  │
│  • Folder 2  │  OR           │  ├─────────────────────────────────────┤  │
│  • Folder 3  │               │  │ Params │ Headers │ Body │ Auth      │  │
│              │  History List │  │─────────────────────────────────────│  │
│              │               │  │ [Tab content area]                  │  │
│              │               │  ├─────────────────────────────────────┤  │
│              │               │  │ Response Viewer (VSplitView)        │  │
│              │               │  │ Status │ Body │ Headers             │  │
│              │               │  └─────────────────────────────────────┘  │
└──────────────┴───────────────┴──────────────────────────────────────────┘
```

**View File Locations:**
- Sidebar column: `Views/Sidebar/FolderRowView.swift`, `HistoryListView.swift`
- Content column: `Views/Sidebar/FolderRequestsListView.swift`
- Detail column: `Views/RequestEditor/RequestEditorView.swift`
- Response area: `Views/ResponseViewer/ResponseViewerView.swift`

## Data Flow

### 1. Application Startup

```
PostWomanApp.swift
       │
       ├─► Creates ModelContainer with schemas:
       │   • Folder.self
       │   • APIRequest.self
       │   • RequestHistory.self
       │
       └─► Loads ContentView
                │
                └─► @Query fetches all Folders
                    @State tracks selectedRequest
```

### 2. Request Execution Flow

```
User clicks "Send"
       │
       ▼
RequestEditorView.sendRequest()
       │
       ├─► Sets isLoading = true
       │
       ▼
HTTPClient.execute(request:)  [@MainActor - reads SwiftData models]
       │
       ├─► Build URL with query params
       ├─► Apply headers
       ├─► AuthenticationHandler.apply()
       ├─► Set body if present
       └─► URLSession.data(for:)
              │
              ▼
       HTTPResponse returned
              │
              ▼
RequestEditorView
       │
       ├─► Updates response state
       └─► Calls saveToHistory() → creates RequestHistory
```

### 3. Menu Command Flow

Menu commands use `NotificationCenter` for loose coupling:

```
AppCommands.swift                     ContentView / RequestEditorView
      │                                        │
      │  NotificationCenter.post(.sendRequest) │
      ├───────────────────────────────────────►│
      │                                        │
      │                               .onReceive(.sendRequest)
      │                                        │
      │                                        ▼
      │                               sendRequest() called
```

**Available Notifications:**
| Notification | Keyboard Shortcut | Handler |
|--------------|-------------------|---------|
| `.createNewRequest` | ⌘N | ContentView |
| `.createNewFolder` | ⇧⌘N | ContentView |
| `.sendRequest` | ⌘Return | RequestEditorView |
| `.saveRequest` | ⌘S | RequestEditorView |
| `.duplicateRequest` | ⌘D | RequestEditorView |
| `.generateCode` | ⇧⌘G | RequestEditorView |

## Common Development Tasks

### Adding a New HTTP Method

1. **Edit `Models/HTTPMethod.swift`:**
```swift
enum HTTPMethod: String, Codable, CaseIterable {
    case get = "GET"
    case post = "POST"
    // Add your new method:
    case newMethod = "NEWMETHOD"

    var color: Color {
        switch self {
        // Add color for UI badge:
        case .newMethod: return .purple
        }
    }
}
```

2. That's it! The method picker uses `CaseIterable` so it auto-appears.

### Adding a New Authentication Type

1. **Add case to `Models/AuthenticationType.swift`:**
```swift
enum AuthenticationType: String, Codable, CaseIterable {
    case none = "None"
    case bearer = "Bearer Token"
    case basic = "Basic Auth"
    case newAuth = "New Auth"  // Add this
}
```

2. **Add UI in `Views/RequestEditor/AuthTabView.swift`:**
```swift
case .newAuth:
    TextField("API Key", text: $apiKey)
```

3. **Handle in `Services/AuthenticationHandler.swift`:**
```swift
case .newAuth:
    request.setValue("key \(apiKey)", forHTTPHeaderField: "X-API-Key")
```

4. **Add storage property in `Models/APIRequest.swift` if needed:**
```swift
var authApiKey: String?
```

### Adding a New Code Generator

1. **Create generator in `Services/CodeGenerator/`:**
```swift
// NewLanguageGenerator.swift
struct NewLanguageGenerator {
    static func generate(from request: APIRequest) -> String {
        // Build code string
        return "// Generated code"
    }
}
```

2. **Add to `Views/CodeGeneration/CodeGeneratorView.swift`:**
```swift
enum CodeLanguage: String, CaseIterable {
    case curl = "cURL"
    case swift = "Swift"
    case newLang = "New Language"  // Add this
}

private func generateCode() -> String {
    switch selectedLanguage {
    case .newLang:
        return NewLanguageGenerator.generate(from: request)
    }
}
```

### Adding a New Request Tab

1. **Add tab case to the enum (likely in RequestEditorView or RequestTabView):**
```swift
enum RequestTab: String, CaseIterable {
    case params, headers, body, auth
    case newTab  // Add this
}
```

2. **Create the tab view in `Views/RequestEditor/`:**
```swift
// NewTabView.swift
struct NewTabView: View {
    @Binding var someData: [SomeType]

    var body: some View {
        // Your UI
    }
}
```

3. **Add to switch in `RequestEditorView.tabContent`:**
```swift
case .newTab:
    NewTabView(someData: $request.someData)
```

### Adding New Model Properties

1. **Add property to the model:**
```swift
// In APIRequest.swift
var newProperty: String = ""
```

2. **SwiftData handles migration automatically** for simple additions with defaults.

3. **Add UI binding where needed:**
```swift
TextField("Label", text: $request.newProperty)
```

## Key Conventions

### Naming
- Use `responseBody` instead of `body` in views to avoid conflicts with SwiftUI's `body` property
- Model files match class names: `Folder.swift` contains `class Folder`

### State Management
- `@Query` for fetching SwiftData collections
- `@Bindable` for two-way binding to SwiftData models in views
- `@State` for local view state
- `@Environment(\.modelContext)` for database operations

### SwiftData Relationships
```swift
// Folder has cascade delete - deleting folder removes all requests
@Relationship(deleteRule: .cascade, inverse: \APIRequest.folder)
var requests: [APIRequest]?

// Request references folder (inverse relationship)
var folder: Folder?
```

## Debugging Tips

### View the SwiftData Database
The database is stored at:
```
~/Library/Containers/com.bearstouch.postwoman/Data/Library/Application Support/       # installed app
~/Library/Containers/com.bearstouch.postwoman.dev/Data/Library/Application Support/   # scripts/run-app.sh
~/Library/Application Support/PostWoman Dev/                                   # swift run
```

### Common Issues

**"Request not updating"** - Ensure you're using `@Bindable` for SwiftData models:
```swift
@Bindable var request: APIRequest  // ✓ Correct
var request: APIRequest            // ✗ Won't update UI
```

**"Menu shortcut not working"** - Check that the view is receiving the notification:
```swift
.onReceive(NotificationCenter.default.publisher(for: .yourNotification)) { _ in
    // Handler
}
```

## Testing Changes

```bash
swift format -i -r Sources Tests               # format
swift format lint --strict -r Sources Tests    # lint: must print nothing
swift build                                    # must be warning-free
swift test                                     # XCTest suite
swift test --filter PostWomanTests.CURLGeneratorTests   # one test class

# Clean build (if having cache issues)
rm -rf .build && swift build
```

## File Quick Reference

| Task | Primary Files |
|------|---------------|
| Change app window/settings | `App/PostWomanApp.swift` |
| Modify sidebar/navigation | `App/ContentView.swift`, `Views/Sidebar/` |
| Edit request form | `Views/RequestEditor/RequestEditorView.swift` |
| Change HTTP execution | `Services/HTTPClient.swift` |
| Add keyboard shortcuts | `App/AppCommands.swift` |
| Modify response display | `Views/ResponseViewer/` |
| Change data models | `Models/` |
| Add code export format | `Services/CodeGenerator/`, `Views/CodeGeneration/` |
