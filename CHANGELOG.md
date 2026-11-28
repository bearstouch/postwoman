# Changelog

All notable changes to Reqs (formerly PostWoman) are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.12.0] - 2026-11-28

### Changed
- PostWoman is now **Reqs**: a new name, a new flat icon (a list of saved requests on electric blue) and an electric blue accent. Pink is still available in Settings → Appearance
- Reqs is a new app with its own bundle identifier (`com.bearstouch.reqs`), so it installs next to PostWoman and starts empty. To bring collections over, right-click each one in PostWoman, choose Export Collection…, and import the file in Reqs with + → Import Collection…. History, secret values and settings stay in PostWoman, and PostWoman keeps working
- PostWoman doesn't update itself to Reqs: download Reqs from https://github.com/bearstouch/reqs/releases. Once Reqs releases publish an update feed, PostWoman's Check for Updates says Reqs is available and links there instead of offering an install
- The command-line tool is now `reqs` (`REQS_URL`, `REQS_TOKEN`, `REQS_TOKEN_FILE`), and MCP clients see the server as `reqs`. Reqs has its own agent token: copy it from Settings → Remote Agent and update your agent configs
- The project moved to https://github.com/bearstouch/reqs (the old address redirects) and its page to https://bearstouch.com/reqs
- The Reqs theme's JSON keys are blue and literals (`true`, `null`) violet; the Pink environment color stays pink whatever the accent
- A request or History entry with a body and no query parameters opens on the Body tab instead of an empty Params tab
- A GET request is sent without its body, like HEAD (URLSession can't send one): the Body tab says so and keeps the body for another method, and History and generated code leave it out
- Settings → General → Default timeout now applies to every request (1 to 600 seconds; it was always 30), including `request_execute` and `reqs request execute`, which no longer give up on a slow answer after 90 seconds (only a stream is stopped then)
- Basic authentication is sent when only the username or only the password was typed (an API key as the username, say); the other part is empty
- `reqs` fails with exit status 2 on an option placed before the command (`reqs -X POST request execute …`) or a mistyped global option, instead of printing the overview and exiting 0

### Fixed
- Selecting another request no longer shows the previous request's response, missing-variables notice or form fields, no longer keeps Send blocked by the previous request's send, and an edit in a form body no longer writes the previous request's fields into the newly selected one
- A failed tool call from an agent (an unknown ID, a bad argument, a request that got no response) no longer discards what you had just created or edited in the app but autosave hadn't stored yet
- A GET whose body was typed for another method is sent, instead of failing with "resource exceeds maximum size"
- Send always asks the server: a response that allowed caching is no longer shown again from the local cache as if it were fresh
- Form Data bodies are sent as `multipart/form-data` parts with a boundary (they went out URL-encoded under a multipart label no server could parse). Generated cURL uses `--form-string`, generated Python `files=`, and generated Swift builds the parts. A `{{variable}}` in a field is resolved inside that field, whatever its value contains
- Generated cURL passes the body with `--data-raw`, so a body starting with `@` is sent as text instead of being read from a file
- Generated cURL sends each header once with its last value, and the request's Bearer or Basic authentication replaces a written `Authorization` header, as in the app
- Generated Python sends the body type's `Content-Type` for XML, plain text and URL-encoded bodies, and keeps repeated query parameters (`id=1&id=2` was sent as `id=2`)
- Opening the Body tab of a form body no longer respells it (`name=John+Doe` became `name=John%2BDoe`, a literal plus), choosing a form body type by mistake no longer replaces a JSON body, and the fields follow a body an agent changes while the tab is open
- A response in another charset (`charset=ISO-8859-1`, UTF-16, also when the name is quoted) is decoded with it instead of being reported as "isn't UTF-8 text"
- History records no request body when the body type is None (it kept the text left from another type), and the Body tab no longer counts it
- History shows a bearer token as dots, like the Basic password and the editor's token field
- With History selected and no entry chosen, the toolbar shows the environment the request on screen is sent with, instead of "No Environment"
- With more than one window open, a menu command (New Request, Send, Duplicate, Save, Generate Code, the Environment menu) acts in the front window only
- `environment_update` keeps a saved secret whose name was typed with a leading or trailing space when an agent sends it back without a value
- `history_create` refuses (`NOT_ALLOWED`) an entry older than everything a full History keeps, instead of reporting an ID for an entry that was deleted at once
- A URL pasted with whitespace around it (a trailing space or newline) is sent without it, instead of ending in `%20` or being refused as invalid
- New Folder, an imported collection and `collection_create` go after the last collection even after deletions, instead of above or level with an existing one
- Importing a collection gives its variables, headers and parameters IDs of their own (a second import, or a hand-edited file, could make two rows share one, so deleting one deleted both), and keeps the first environment selected when two share the selected one's name
- Generated cURL sends a header with an empty value (`-H 'Name;'`); generated Python sends a JSON body of `null` instead of no body
- `history_create` and `history_update` refuse a `timeMs` over a day (a huge one made the entry unreadable), and clearing an entry's `errorMessage` marks a 2xx entry successful again
- `reqs` accepts `--server=URL`, `--agent-token=…` and `--agent-token-file=…`, and ignores an empty `REQS_URL`
- `reqs` tables no longer cut a name with an emoji or a combining accent in the middle
- `reqs` tries the app whose Remote Agent is on first, so a leftover token from another build no longer uses up the server's failed sign-in limit after a few commands

## [0.11.0] - 2026-11-27

### Added
- PATCH, HEAD and OPTIONS requests, in the method menu, for agents (`request_*` tools) and in the CLI (`-X PATCH`). A HEAD request is sent without its body (the Body tab says so, and keeps the body for when you choose another method), and History records it without one. Generated cURL uses `-I` for HEAD, and generated Python follows redirects for HEAD as the app does. Collections with these methods can't be imported by earlier versions, and going back to an earlier version after using them isn't supported
- Streaming responses, such as LLM APIs with `"stream": true` (OpenAI, Anthropic, Ollama, Gemini). A `text/event-stream` or NDJSON response appears as it arrives, and a new Events tab lists each event with its arrival time and full data. For LLM replies, the Body's Text view joins the deltas into the reply, and Timing shows the first byte and first token. Send becomes Stop (⌘.) while a request runs, and a stopped stream keeps what arrived, in History too. Generated cURL adds `-N` when a request asks for a stream. Agents get `response.stream` from `request_execute` (events, text, end; streams stop after 90 s), and `postwoman request execute --text` prints the reply text
- Check for Updates, as in Trellis: PostWoman → Check for Updates… and Settings → Updates (Check Now, automatic daily checks, beta versions) install new releases in place with Sparkle. Nothing reaches the network until you check or turn automatic checks on, and no usage data is sent. Only notarized releases are offered; each one is verified against PostWoman's EdDSA key. Bundles now carry a numeric `CFBundleVersion` (`X.Y.Z.100` for a release, lower for its pre-releases)
- Environments for each collection, so one request works against Local, Staging and Production. Write `{{name}}` in a request's URL, params, headers, body or auth. Every collection has a Default environment that always applies; pick another from the toolbar's environment menu (or Environment → ⌃1…⌃9, Manage Environments ⌘E), and it overrides Default only for the variables it sets. The URL bar shows the resolved address, with each variable colored by where it comes from (red when nothing defines it); after sending, a notice lists variables sent as written. Secret variables are masked, left as `{{name}}` in History and generated code, exported empty, and write-only for agents. Generate Code can fill in the variables. Environments are exported and imported with their collection. Agents get `environment_*` MCP tools and an `environmentId` for `request_execute`; the CLI gets `postwoman environment …` and `request execute --env`
- The `postwoman` command-line tool, shipped in the app at `Contents/Helpers/postwoman`: manage collections, requests and History and send requests from the shell through the app's MCP server (`postwoman request execute --id …`, `postwoman history list`, `postwoman call TOOL --args JSON`). It finds the agent token on its own, prints tables or `--json`, and has stable exit statuses. `postwoman cli install-link` puts it on PATH, and Settings → Remote Agent → Copy Client Setup copies that command
- Settings → Remote Agent: an MCP server (off by default, like Trellis's Remote Control) that lets agents such as Claude Code, Codex and OpenCode list, create, update and delete collections, requests and history entries, and send requests (recorded in History). It listens on loopback (port 7778) unless you confirm a network address, needs the access token shown in Settings on every request, and offers ready-to-paste client setups. Saved credentials are write-only over MCP. The app now has the sandbox's incoming-connections entitlement

### Changed
- The response tabs (Body, Events, Headers, Cookies, Timing) are icons, with their names as tooltips, so they no longer wrap in a narrow pane
- A new layered app icon: a paper plane flying off a stack of request cards
- About PostWoman opens the standard macOS About panel, with credits linking the MIT License and bearstouch
- Importing a collection file made by a newer PostWoman (or with a format version it doesn't know) is refused with a message saying so, instead of importing part of it

### Fixed
- Params no longer replace a query already in the URL: `https://api.test/items?page=1` with a `limit` param sends `?page=1&limit=10`
- `+`, `&`, `=` and `#` in a param's name or value are percent-encoded, so `a+b` is no longer read as `a b` by the server and `a&b=c` stays one value. The app, generated cURL and generated Swift build the same URL
- Generated cURL works with a `'` in the URL, a header, a token or a password, and spells out `-X GET` when a GET has a body (curl sent it as a POST)
- Generated Python keeps JSON strings as written (`"nullable"` became `"Noneable"`), keeps key order and numbers, and escapes every string, so bodies, URLs and header names with quotes or backslashes no longer break the script
- Generated Swift escapes every string, so a JSON body containing `\n` or `\(`, or a URL or param with a quote, compiles and sends the same bytes, and it keeps the URL's own query
- A response body that is a single JSON value (`true`, `42`, `"ok"`) is shown as JSON, and JSON with a trailing comma (`[1,]`) is no longer treated as valid
- Timings round before choosing a unit: 9.96 ms reads "10 ms" instead of "10.0 ms", and 999.6 ms reads "1.00 s" instead of "1000 ms"; sizes just under a megabyte read "1.0 MB" instead of "1024.0 KB"
- A URL with a space, braces or brackets after its host keeps the escapes already in it (`?q=%2F b` was sent as `q=%252F%20b`), and generated cURL for such a URL (for example with `{{name}}` or `filter[a]=1`) is no longer refused by curl
- Opening the Body tab of a form body no longer rewrites it: `&`, `=` and `+` in a field are encoded, so `q=a%26b` stays one field instead of becoming `q=a&b`
- Duplicate in the request list keeps the request's credentials (Bearer token, Basic username and password, OAuth settings), and ⌘D makes the same copy ("<name> Copy", after the last request)
- New, duplicated and restored requests go after the last request of their collection, so two requests no longer share a place in the list
- Deleting the selected collection clears the window instead of leaving "Folder not found" and its deleted request on screen
- History shows "Failed", with the error as its tooltip, for a request that got no response
- Generated Python sends a JSON body that doesn't parse as written, with `Content-Type: application/json`, instead of as a JSON string
- A body the server labels only `; charset=utf-8` is no longer labelled "charset=utf-8", and a body that isn't UTF-8 text says why it isn't shown instead of "No response body"
- VoiceOver: the selected request tab, response tab, code language and stream event are announced as selected; icon-only buttons are read by what they do (Prettify, Stop, Clear History, Copy, Delete, the environment editor's controls) instead of by their symbol names; key-value rows name their checkbox, fields and delete button; each response header row offers Copy Name, Copy Value and Copy Header as actions; and collection rows read their request count ("3 requests")

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
