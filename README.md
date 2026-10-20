# PostWoman

A native macOS REST API client built with SwiftUI and SwiftData. A lightweight Postman alternative designed specifically for macOS.

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange)
![SwiftUI](https://img.shields.io/badge/SwiftUI-5.0+-green)
![License](https://img.shields.io/badge/License-MIT-yellow)

## Features

### Core Functionality
- **REST API Testing** - Support for GET, POST, PUT, DELETE methods
- **Folder Organization** - Organize requests into nested collections
- **Request Editor** - Configure URL, headers, query parameters, body, and authentication
- **Response Viewer** - View response status, headers, and formatted JSON body

### Authentication
- **Bearer Token** - JWT and OAuth token support
- **Basic Auth** - Username/password with Base64 encoding
- **OAuth 2.0** - Configuration structure (implementation in progress)

### Code Generation
Export requests as code in multiple languages:
- **cURL** - Command-line ready
- **Swift** - URLSession implementation
- **Python** - requests library

### Request History
- Automatic logging of all requests
- View past requests grouped by date
- Restore requests from history

## Installation

### Download (Recommended)

Download the latest DMG installer from the [Releases](../../releases) page:

1. Download `PostWoman-X.Y.Z.dmg` (Universal), or the `-apple-silicon` / `-intel` variant
2. Open the DMG file
3. Drag PostWoman to your Applications folder
4. Eject the DMG and launch PostWoman from Applications

### Build from Source

#### Requirements
- macOS 14.0 (Sonoma) or later
- Xcode 26 / Swift 6.2 toolchain (the app builds with Swift Package Manager)

#### Steps

1. Clone the repository:
   ```bash
   git clone https://github.com/bearstouch/postwoman.git
   cd postwoman
   ```

2. Build and run:
   ```bash
   swift run PostWoman            # unbundled, uses its own dev store
   scripts/run-app.sh             # sandboxed .build/PostWoman.app (com.bearstouch.postwoman.dev)
   ```
   Or open `Package.swift` in Xcode (or the folder in VS Code with the Swift extension) and run the `PostWoman` scheme.

3. Test and lint:
   ```bash
   swift test
   swift format lint --strict -r Sources Tests
   ```

#### Build DMG Installers

```bash
scripts/package-release.sh       # Universal 2 DMG in dist/ (+ dist/release-evidence.json)
scripts/package-thin-release.sh  # Apple silicon and Intel DMGs from the Universal app
```

Builds are ad-hoc signed unless `POSTWOMAN_SIGN_IDENTITY` (Developer ID) is set; set
`POSTWOMAN_NOTARY_PROFILE` (a `notarytool` keychain profile) to notarize and staple.
The version comes from `release/manifest.json`.

## Usage

### Creating a Request
1. Click the **+** button in the sidebar
2. Select "New Request" or "New Folder"
3. Enter the URL and select HTTP method
4. Configure headers, parameters, body as needed
5. Press **Cmd+Return** or click "Send"

### Keyboard Shortcuts

| Action | Shortcut |
|--------|----------|
| New Request | Cmd+N |
| New Folder | Shift+Cmd+N |
| Send Request | Cmd+Return |
| Save Request | Cmd+S |
| Duplicate Request | Cmd+D |
| Generate Code | Shift+Cmd+G |

## Project Structure

```
Package.swift               # SwiftPM manifest (executable + tests)
Sources/PostWoman/
├── App/                    # App entry point and main views
├── Models/                 # SwiftData models
├── Views/
│   ├── Sidebar/           # Collection tree and history
│   ├── RequestEditor/     # URL bar and request tabs
│   ├── ResponseViewer/    # Response display
│   └── CodeGeneration/    # Code export
├── Services/
│   ├── HTTPClient.swift   # Networking
│   ├── AuthenticationHandler.swift
│   └── CodeGenerator/     # cURL, Swift, Python generators
└── Utilities/             # JSON formatting, helpers
Tests/PostWomanTests/       # XCTest suite
release/                    # manifest.json (version, bundle id) and entitlements
scripts/                    # app bundle, DMG and release packaging
Design/                     # app icon and DMG background sources
```

## Tech Stack

- **UI Framework**: SwiftUI
- **Data Persistence**: SwiftData
- **Networking**: URLSession with async/await
- **Build**: Swift Package Manager, Swift 6 language mode
- **Target Platform**: macOS 14+

## Contributing

We welcome contributions! Please see our [Contributing Guide](CONTRIBUTING.md) for details on:

- Setting up your development environment
- Our coding standards and conventions
- The pull request process

### Quick Start for Contributors

```bash
# Fork and clone
git clone https://github.com/YOUR_USERNAME/postwoman.git
cd postwoman

# Create a feature branch
git checkout -b feature/your-feature

# Make changes, then submit a PR
```

### Good First Issues

Check out issues labeled [`good first issue`](../../issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22) for beginner-friendly tasks.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Inspired by [Postman](https://www.postman.com/)
- Built with SwiftUI and SwiftData
