# Changelog

All notable changes to PostWoman are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Environments for each collection, so one request works against Local, Staging and Production. Write `{{name}}` in a request's URL, params, headers, body or auth. Every collection has a Default environment that always applies; pick another from the toolbar's environment menu (or Environment → ⌃1…⌃9, Manage Environments ⌘E), and it overrides Default only for the variables it sets. The URL bar shows the resolved address, with each variable colored by where it comes from (red when nothing defines it); after sending, a notice lists variables sent as written. Secret variables are masked, left as `{{name}}` in History and generated code, exported empty, and write-only for agents. Generate Code can fill in the variables. Environments are exported and imported with their collection. Agents get `environment_*` MCP tools and an `environmentId` for `request_execute`; the CLI gets `postwoman environment …` and `request execute --env`
- The `postwoman` command-line tool, shipped in the app at `Contents/Helpers/postwoman`: manage collections, requests and History and send requests from the shell through the app's MCP server (`postwoman request execute --id …`, `postwoman history list`, `postwoman call TOOL --args JSON`). It finds the agent token on its own, prints tables or `--json`, and has stable exit statuses. `postwoman cli install-link` puts it on PATH, and Settings → Remote Agent → Copy Client Setup copies that command
- Settings → Remote Agent: an MCP server (off by default, like Trellis's Remote Control) that lets agents such as Claude Code, Codex and OpenCode list, create, update and delete collections, requests and history entries, and send requests (recorded in History). It listens on loopback (port 7778) unless you confirm a network address, needs the access token shown in Settings on every request, and offers ready-to-paste client setups. Saved credentials are write-only over MCP. The app now has the sandbox's incoming-connections entitlement

### Changed
- A new layered app icon: a paper plane flying off a stack of request cards
- About PostWoman opens the standard macOS About panel, with credits linking the MIT License and bearstouch

## [0.10.0] - 2026-11-27

### Added
- History keeps the full request as sent (name, params, body type, auth) and the response (content type, timing), records failed requests with their error, and shows an entry in a read-only detail view when you select it. Open as Request restores the entry into the first collection
- Response Cookies tab, listing the cookies from `Set-Cookie` headers
- Response Timing tab: a waterfall of DNS, connect, TLS, send, wait and download, plus protocol, TLS version and whether the connection was reused
- Response body code view with line numbers, JSON syntax colors, line wrapping with hanging indents, the find bar, and Save and Copy buttons
- Response Headers filter field with a match count, hover copy, and a Copy Name / Value / Header context menu
- Prettify button for JSON and XML request bodies. JSON keeps its key order, number literals and escapes; invalid bodies are left as they are, and ⌘Z undoes a prettify
- The request body editor has line numbers, JSON syntax colors as you type, and the find bar
- Settings → Appearance, in a new Settings window with a sidebar like Trellis's: choose System, Light or Dark; pick a light theme and a dark theme (PostWoman plus ten inspired by Trellis's themes: Modern, GitHub, One, Nord, Tokyo, Rosé Pine, Solarized, Gruvbox, Dracula and Monokai); pick an accent color (pink by default, or the theme's own); and set the code font size
- Every border, divider and text field outline uses the theme's border color, including the column dividers and the request/response split

### Fixed
- Dark mode: the request list and History no longer draw a white background behind white text
- Typing in the request body no longer turns quotes into smart quotes or `--` into dashes, which made JSON bodies invalid
- Responses show standard status text ("200 OK" instead of "200 no error")
- Pretty mode keeps the server's key order instead of sorting keys
- Short response bodies and generated code start at the top left instead of floating in the middle
- The History column is titled "History"
- `scripts/run-app.sh` quits the running dev build before opening the new one, so the new build actually starts

### Changed
- The response status, time and size sit in the response tab bar (Body, Headers, Cookies, Timing) instead of a separate status bar
- Response headers are shown in a left-aligned name column, with comma-separated token lists as wrapping chips and row separators
- A dark appearance in the style of Trellis: near-black panes, hairline borders, softer method and status colors, a framed body editor and a glowing Send button. Light mode keeps the system look, with white request and response panes

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
