# Changelog

All notable changes to PostWoman are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed
- Dark mode: the request list and History no longer draw a white background behind white text
- Responses show standard status text ("200 OK" instead of "200 no error")
- Short response bodies and generated code start at the top left instead of floating in the middle
- The History column is titled "History"

### Changed
- A dark appearance in the style of Trellis: near-black panes, hairline borders, softer method and status colors, a framed body editor and a glowing Send button. Light mode keeps the system look

## [0.9.1] - 2026-10-20

### Changed
- Build with Swift Package Manager (`Package.swift`, Swift 6 language mode) instead of an Xcode project
- CI lints with `swift format`, builds warning-free, runs the new XCTest suite and assembles the app bundle on macOS 26
- Releases build Universal 2, Apple silicon and Intel DMGs with hardened runtime, optional Developer ID signing and notarization, checksums and release evidence; the version comes from `release/manifest.json`
- `HTTPClient` runs on the main actor so SwiftData models are no longer read off the main thread
- Bundle identifier is now `com.bearstouch.postwoman` (was `com.postwoman.app`). The app gets a new sandbox container, so collections and history from 0.9.0 do not carry over; export collections from 0.9.0 (folder menu → Export) and import them in 0.9.1
- About window and app copyright now credit Bearstouch, and the license link points to github.com/bearstouch/postwoman

## [1.0.0] - 2026-01-15

### Added

#### Core Features
- **REST API Testing** - Full support for GET, POST, PUT, PATCH, DELETE HTTP methods
- **Request Editor** - Configure URL, headers, query parameters, request body, and authentication
- **Response Viewer** - View response status, headers, and formatted JSON body with syntax highlighting
- **Request History** - Automatic logging of all requests with date grouping and restore capability

#### Organization
- **Folder Collections** - Organize requests into folder collections
- **Notes App Style Sidebar** - Clean, intuitive sidebar with folders in primary column
- **Folder Selection** - Visual highlight for selected folders with automatic request placement
- **Auto-expand Folders** - Folders automatically expand when creating requests inside them

#### Authentication
- **Bearer Token** - JWT and OAuth token support
- **Basic Auth** - Username and password with Base64 encoding

#### Code Generation
- **cURL Export** - Generate command-line ready cURL commands
- **Swift Export** - Generate URLSession implementation code
- **Python Export** - Generate Python requests library code
- **Terminal-like UI** - Code generator with terminal-inspired appearance

#### Import/Export
- **Collection Export** - Export folder collections to JSON files
- **Collection Import** - Import folder collections from JSON files

#### User Interface
- **Three-column Layout** - NavigationSplitView with sidebar, content, and detail columns
- **Keyboard Shortcuts** - Full keyboard support (⌘N, ⇧⌘N, ⌘↩, ⌘S, ⌘D, ⇧⌘G)
- **Clean Design** - White backgrounds for folder and history views
- **300px Sidebar** - Optimized initial sidebar width

### Technical
- Built with SwiftUI 5.0 and SwiftData
- Actor-based HTTPClient using URLSession with async/await
- macOS 14.0 (Sonoma) minimum requirement
- Swift 5.9+
