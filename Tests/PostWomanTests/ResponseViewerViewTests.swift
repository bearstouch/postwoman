import AppKit
import SwiftUI
import XCTest

@testable import PostWoman

// The response viewer's views (Sources/PostWoman/Views/ResponseViewer): their decisions as plain functions, and what a hosted
// view shows and tells VoiceOver for realistic responses (JSON, HTML, text, binary, error, empty, live and ended streams).

/// Reads and drives the hosted views' accessibility nodes where `ViewHosting.Element` (a snapshot) isn't enough: pressing
/// buttons, reading enabled state and values, typing into a filter field, and reaching list cells.
@MainActor
private enum AX {
    static func read(_ node: NSObject, _ getter: String) -> Any? {
        node.responds(to: NSSelectorFromString(getter)) ? node.perform(NSSelectorFromString(getter))?.takeUnretainedValue() : nil
    }

    static func label(_ node: NSObject) -> String {
        ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { read(node, $0) as? String }.first { !$0.isEmpty } ?? ""
    }

    static func role(_ node: NSObject) -> NSAccessibility.Role? { (read(node, "accessibilityRole") as? String).map(NSAccessibility.Role.init(rawValue:)) }

    /// Every node under `root`, depth first, as `ViewHosting.elements(in:)` walks them.
    static func nodes(in root: NSView) -> [NSObject] {
        var found: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: Any, depth: Int) {
            guard depth < 60, let node = object as? NSObject, seen.insert(ObjectIdentifier(node)).inserted else { return }
            found.append(node)
            for child in read(node, "accessibilityChildren") as? [Any] ?? [] { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return found
    }

    static func node(_ label: String, role: NSAccessibility.Role? = nil, in root: NSView) -> NSObject? {
        nodes(in: root).first { self.label($0) == label && (role == nil || self.role($0) == role) }
    }

    /// Presses the element labelled `label` as VoiceOver's VO-Space would, then lets SwiftUI apply it.
    @discardableResult
    static func press(_ label: String, role: NSAccessibility.Role? = nil, in root: NSView) -> Bool {
        guard let node = node(label, role: role, in: root), node.responds(to: NSSelectorFromString("accessibilityPerformPress")) else { return false }
        _ = node.perform(NSSelectorFromString("accessibilityPerformPress"))
        ViewHosting.settle()
        return true
    }

    static func isEnabled(_ label: String, in root: NSView) -> Bool? {
        node(label, in: root).flatMap { $0.value(forKey: "accessibilityEnabled") as? Bool }
    }

    /// A radio button's value: 1 when it is the chosen segment.
    static func isChosen(_ label: String, in root: NSView) -> Bool? {
        guard let node = node(label, role: .radioButton, in: root) else { return nil }
        return (node.value(forKey: "accessibilityValue") as? NSNumber)?.boolValue
    }

    static func subviews(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(subviews(of:)) }

    /// Types `text` into the first editable text field, as the field editor would report it.
    static func type(_ text: String, in root: NSView) {
        guard let field = subviews(of: root).compactMap({ $0 as? NSTextField }).first(where: \.isEditable) else { return XCTFail("No text field") }
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        ViewHosting.settle()
    }

    static func textViews(in root: NSView) -> [NSTextView] { subviews(of: root).compactMap { $0 as? NSTextView } }

    /// The elements inside each row of a SwiftUI `List`, whose cells the accessibility walk doesn't enter.
    static func cellElements(in root: NSView) -> [[ViewHosting.Element]] {
        subviews(of: root).filter { String(describing: Swift.type(of: $0)).hasPrefix("CellHostingView") }.map { ViewHosting.elements(in: $0) }
    }
}

/// Holds what a hosted view is given, so a test can change it as the app would (a stream arriving, a new send).
@MainActor
private final class Feed<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

private struct FedView<Value, Content: View>: View {
    @ObservedObject var feed: Feed<Value>
    let content: (Value) -> Content
    var body: some View { content(feed.value) }
}

private enum Fixture {
    static let jsonHeaders = [
        KeyValuePair(key: "content-type", value: "application/json; charset=utf-8"), KeyValuePair(key: "Date", value: "Fri, 27 Nov 2026 17:24:32 GMT"),
        KeyValuePair(key: "Vary", value: "Accept,Accept-Encoding,Origin")
    ]
    static let sessionCookie = ResponseCookie(name: "sid", value: "abc123", domain: "api.example.com", path: "/", expires: nil, isSecure: true, isHTTPOnly: true, sameSite: "Lax")

    static let json = HTTPResponse(
        statusCode: 200, headers: jsonHeaders, body: #"{"id":1,"name":"Ada"}"#, responseTime: 182.4, contentType: "application/json; charset=utf-8", cookies: [sessionCookie],
        bodySize: 21)
    static let html = HTTPResponse(
        statusCode: 404, headers: [KeyValuePair(key: "Content-Type", value: "text/html")], body: "<h1>Not here</h1>", responseTime: 12, contentType: "text/html")
    static let text = HTTPResponse(statusCode: 500, headers: [], body: "Something broke", responseTime: 1500, contentType: "text/plain")
    static let binary = HTTPResponse(statusCode: 200, headers: [], body: nil, responseTime: 30, contentType: "image/png", bodySize: 2048)
    static let empty = HTTPResponse(statusCode: 204, headers: [], body: "", responseTime: 8, contentType: nil)
    static let failure = HTTPResponse.error(URLError(.timedOut))

    static func events(_ count: Int) -> [StreamEvent] {
        (0..<count).map { StreamEvent(index: $0, time: 100 + Double($0) * 40, event: $0 == 0 ? "message_start" : nil, data: #"{"delta":"\#($0)"}"#) }
    }

    static func stream(_ end: StreamEnd, events count: Int = 3, text: String? = "Hello there") -> HTTPResponse {
        HTTPResponse(
            statusCode: 200, headers: [KeyValuePair(key: "Content-Type", value: "text/event-stream")], body: "data: x\n\n", responseTime: 900, contentType: "text/event-stream",
            stream: StreamInfo(kind: .sse, events: events(count), firstByteTime: 80, text: text, firstTextTime: text == nil ? nil : 120, end: end))
    }
}

// MARK: - ResponseViewerView

@MainActor
final class ResponseViewerViewTests: XCTestCase {
    private let wide = CGSize(width: 1000, height: 600)
    private let narrow = CGSize(width: 560, height: 500)

    func testEventsTabIsOfferedOnlyForAStreamedResponse() {
        XCTAssertEqual(ResponseViewerView.ResponseTab.available(for: Fixture.json), [.body, .headers, .cookies, .timing])
        XCTAssertEqual(ResponseViewerView.ResponseTab.available(for: Fixture.stream(.completed)), [.body, .events, .headers, .cookies, .timing])
        XCTAssertEqual(ResponseViewerView.ResponseTab.available(for: Fixture.stream(.streaming, events: 0)), ResponseViewerView.ResponseTab.allCases)
    }

    func testAChosenTabTheResponseLacksFallsBackToBody() {
        XCTAssertEqual(ResponseViewerView.ResponseTab.shown(.events, for: Fixture.json), .body, "Events was chosen for a stream, then a plain response came.")
        XCTAssertEqual(ResponseViewerView.ResponseTab.shown(.events, for: Fixture.stream(.stopped)), .events)
        for tab in [ResponseViewerView.ResponseTab.headers, .cookies, .timing, .body] {
            XCTAssertEqual(ResponseViewerView.ResponseTab.shown(tab, for: Fixture.failure), tab)
        }
    }

    func testTabCountsComeFromTheResponse() {
        let stream = Fixture.stream(.completed, events: 4)
        XCTAssertEqual(ResponseViewerView.ResponseTab.events.count(in: stream), 4)
        XCTAssertNil(ResponseViewerView.ResponseTab.events.count(in: Fixture.json), "No stream, no events count.")
        XCTAssertEqual(ResponseViewerView.ResponseTab.headers.count(in: Fixture.json), 3)
        XCTAssertEqual(ResponseViewerView.ResponseTab.cookies.count(in: Fixture.json), 1)
        XCTAssertEqual(ResponseViewerView.ResponseTab.cookies.count(in: Fixture.failure), 0)
        XCTAssertNil(ResponseViewerView.ResponseTab.body.count(in: Fixture.json))
        XCTAssertNil(ResponseViewerView.ResponseTab.timing.count(in: Fixture.json))
    }

    func testTabLabelsReadTheNameAndCount() {
        XCTAssertEqual(ResponseViewerView.ResponseTab.headers.accessibilityLabel(count: 3), "Headers, 3")
        XCTAssertEqual(ResponseViewerView.ResponseTab.cookies.accessibilityLabel(count: 0), "Cookies, 0", "The badge hides a zero; the label still says it.")
        XCTAssertEqual(ResponseViewerView.ResponseTab.body.accessibilityLabel(count: nil), "Body")
    }

    func testEveryTabHasItsOwnIcon() {
        let images = ResponseViewerView.ResponseTab.allCases.map(\.systemImage)
        XCTAssertEqual(Set(images).count, images.count)
        for image in images { XCTAssertNotNil(NSImage(systemSymbolName: image, accessibilityDescription: nil), image) }
    }

    func testStatusTitleWritesTheCodeAndReasonOrError() {
        XCTAssertEqual(ResponseSummary.statusTitle(Fixture.json), "200 OK")
        XCTAssertEqual(ResponseSummary.statusTitle(Fixture.html), "404 Not Found")
        XCTAssertEqual(ResponseSummary.statusTitle(Fixture.text), "500 Internal Server Error")
        XCTAssertEqual(ResponseSummary.statusTitle(Fixture.failure), "Error", "No status arrived.")
        let teapot = HTTPResponse(statusCode: 418, headers: [], body: nil, responseTime: 0, contentType: nil)
        XCTAssertEqual(ResponseSummary.statusTitle(teapot), "418 " + HTTPURLResponse.localizedString(forStatusCode: 418).capitalized)
    }

    func testBodySizePrefersTheBytesReceived() {
        XCTAssertEqual(ResponseSummary.bodySize(Fixture.binary), 2048, "A body that isn't text still has a size.")
        let compressed = HTTPResponse(statusCode: 200, headers: [], body: String(repeating: "a", count: 5000), responseTime: 0, contentType: nil, bodySize: 300)
        XCTAssertEqual(ResponseSummary.bodySize(compressed), 300)
        let unknown = HTTPResponse(statusCode: 200, headers: [], body: "é😀", responseTime: 0, contentType: nil)
        XCTAssertEqual(ResponseSummary.bodySize(unknown), 6, "UTF-8 bytes, not characters.")
        XCTAssertEqual(ResponseSummary.bodySize(Fixture.failure), Fixture.failure.body?.utf8.count)
        XCTAssertEqual(ResponseSummary.bodySize(HTTPResponse(statusCode: 204, headers: [], body: nil, responseTime: 0, contentType: nil)), 0)
    }

    func testByteSizesUseBytesThenKilobytesThenMegabytes() {
        let cases: [(Int, String)] = [
            (0, "0 B"), (1, "1 B"), (1023, "1023 B"), (1024, "1.0 KB"), (1536, "1.5 KB"), (10_240, "10.0 KB"), (1_048_576, "1.0 MB"), (5_452_595, "5.2 MB"),
            (3_221_225_472, "3072.0 MB")
        ]
        for (bytes, text) in cases {
            XCTAssertEqual(ResponseSummary.formatBytes(bytes), text, "\(bytes)")
        }
    }

    func testTheByteUnitIsChosenAfterRounding() {
        let cases: [(Int, String)] = [(1_048_575, "1.0 MB"), (1_048_525, "1.0 MB"), (1_048_524, "1023.9 KB"), (1_048_576 * 1024 - 1, "1024.0 MB")]
        for (bytes, text) in cases {
            XCTAssertEqual(ResponseSummary.formatBytes(bytes), text, "\(bytes)")
        }
    }

    func testACompletedStreamOfOneEventSaysEventInTheSingular() {
        XCTAssertEqual(ResponseSummary.streamHelp(StreamInfo(kind: .sse, events: Fixture.events(1), end: .completed)), "Server-sent events: 1 event")
        XCTAssertEqual(ResponseSummary.streamHelp(StreamInfo(kind: .ndjson, end: .completed)), "NDJSON: 0 events")
    }

    func testStreamBadgeSaysHowTheStreamEnded() {
        let cases: [(StreamEnd, Int, String, String?, String)] = [
            (.streaming, 0, "Streaming · 0 events", nil, "Server-sent events, still arriving"),
            (.streaming, 1, "Streaming · 1 event", nil, "Server-sent events, still arriving"),
            (.streaming, 7, "Streaming · 7 events", nil, "Server-sent events, still arriving"),
            (.completed, 3, "Stream", "dot.radiowaves.left.and.right", "Server-sent events: 3 events"),
            (.stopped, 2, "Stopped", "stop.circle", "Server-sent events, stopped before the server ended it"),
            (.failed("The network connection was lost."), 2, "Interrupted", "exclamationmark.triangle", "Server-sent events, interrupted: The network connection was lost.")
        ]
        for (end, count, title, symbol, help) in cases {
            let stream = StreamInfo(kind: .sse, events: Fixture.events(count), end: end)
            XCTAssertEqual(ResponseSummary.streamTitle(stream), title, "\(end)")
            XCTAssertEqual(ResponseSummary.streamSymbol(stream), symbol, "\(end)")
            XCTAssertEqual(ResponseSummary.streamHelp(stream), help, "\(end)")
        }
        XCTAssertEqual(ResponseSummary.streamHelp(StreamInfo(kind: .ndjson, end: .streaming)), "NDJSON, still arriving")
    }

    // Rendering

    func testWhileSendingItSaysSo() {
        let hosting = ViewHosting.host(ResponseViewerView(response: Fixture.json, isLoading: true), size: wide)
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("Sending request..."))
        XCTAssertEqual(ViewHosting.buttonLabels(in: hosting), [], "No tabs while the old response is replaced.")
    }

    func testBeforeAnySendItExplainsWhereTheResponseGoes() {
        let hosting = ViewHosting.host(ResponseViewerView(response: nil, isLoading: false), size: narrow, appearance: .darkAqua)
        defer { ViewHosting.close(hosting) }
        let text = ViewHosting.text(in: hosting)
        XCTAssertTrue(text.contains("Response"))
        XCTAssertTrue(text.contains("Send a request to see the response here"))
    }

    func testIconOnlyTabsHaveLabelsAndHelp() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for size in [wide, narrow] {
                let hosting = ViewHosting.host(ResponseViewerView(response: Fixture.json, isLoading: false), size: size, appearance: appearance)
                defer { ViewHosting.close(hosting) }
                let tabs = ViewHosting.elements(in: hosting).filter { $0.role == .button && ["Body", "Headers", "Cookies", "Timing"].contains($0.help) }
                XCTAssertEqual(tabs.map(\.label), ["Body", "Headers, 3", "Cookies, 1", "Timing"], "\(appearance.rawValue) \(size)")
                XCTAssertEqual(tabs.map(\.help), ["Body", "Headers", "Cookies", "Timing"])
            }
        }
    }

    func testAStreamAddsTheEventsTabWithItsCount() {
        let hosting = ViewHosting.host(ResponseViewerView(response: Fixture.stream(.completed, events: 5), isLoading: false), size: wide)
        defer { ViewHosting.close(hosting) }
        let events = ViewHosting.elements(in: hosting).first { $0.role == .button && $0.help == "Events" }
        XCTAssertEqual(events?.label, "Events, 5")
    }

    func testStatusTimeAndSizeAreWrittenOut() {
        let cases: [(HTTPResponse, String, String, String)] = [
            (Fixture.json, "200 OK", "182 ms", "21 B"), (Fixture.html, "404 Not Found", "12 ms", "17 B"), (Fixture.text, "500 Internal Server Error", "1.50 s", "15 B"),
            (Fixture.binary, "200 OK", "30 ms", "2.0 KB")
        ]
        for (response, status, time, size) in cases {
            let hosting = ViewHosting.host(ResponseViewerView(response: response, isLoading: false), size: wide, appearance: .darkAqua)
            defer { ViewHosting.close(hosting) }
            let elements = ViewHosting.elements(in: hosting)
            XCTAssertTrue(elements.contains { $0.label == status }, "Success and failure are read, not only coloured: \(status)")
            XCTAssertEqual(elements.first { $0.help == "Total time" }?.label, time, status)
            XCTAssertEqual(elements.first { $0.help == "Body size" }?.label, size, status)
        }
    }

    func testAFailedRequestShowsErrorAndItsMessageButNoTimes() {
        let hosting = ViewHosting.host(ResponseViewerView(response: Fixture.failure, isLoading: false), size: wide)
        defer { ViewHosting.close(hosting) }
        let elements = ViewHosting.elements(in: hosting)
        XCTAssertTrue(elements.contains { $0.label == "Error" })
        XCTAssertFalse(elements.contains { $0.help == "Total time" || $0.help == "Body size" }, "Nothing was timed or received.")
        XCTAssertEqual(AX.textViews(in: hosting).first?.string, "Error: \(URLError(.timedOut).localizedDescription)")
    }

    func testTheStreamBadgeIsReadInWords() {
        let cases: [(StreamEnd, String, String)] = [
            (.streaming, "Streaming · 3 events", "Server-sent events, still arriving"), (.completed, "Stream", "Server-sent events: 3 events"),
            (.stopped, "Stopped", "Server-sent events, stopped before the server ended it"), (.failed("Lost"), "Interrupted", "Server-sent events, interrupted: Lost")
        ]
        for (end, title, help) in cases {
            let hosting = ViewHosting.host(ResponseViewerView(response: Fixture.stream(end), isLoading: false), size: wide)
            defer { ViewHosting.close(hosting) }
            let badge = ViewHosting.elements(in: hosting).first { $0.label == title }
            XCTAssertEqual(badge?.help, help, "\(end)")
        }
    }

    func testTheStreamBadgeIconIsNotReadAsASymbolName() {
        for end in [StreamEnd.completed, .stopped, .failed("Lost")] {
            let hosting = ViewHosting.host(ResponseViewerView(response: Fixture.stream(end), isLoading: false), size: wide)
            defer { ViewHosting.close(hosting) }
            let symbol = ResponseSummary.streamSymbol(Fixture.stream(end).stream!)!
            XCTAssertFalse(ViewHosting.text(in: hosting).contains(symbol), "VoiceOver would read \u{201C}\(symbol)\u{201D} before the badge's words.")
        }
    }

    func testPressingATabShowsItsContent() {
        let hosting = ViewHosting.host(ResponseViewerView(response: Fixture.json, isLoading: false), size: wide)
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("View mode"), "Body shows first.")
        XCTAssertTrue(AX.press("Headers, 3", in: hosting))
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("3 headers"))
        XCTAssertTrue(AX.press("Cookies, 1", in: hosting))
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("sid") || AX.cellElements(in: hosting).flatMap { $0 }.contains { $0.label == "sid" })
        XCTAssertTrue(AX.press("Timing", in: hosting))
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("total"))
        XCTAssertFalse(ViewHosting.text(in: hosting).contains("View mode"))
    }

    func testABodyThatIsNotTextSaysWhyItIsNotShown() {
        XCTAssertEqual(ResponseSummary.emptyBodyMessage(Fixture.binary), "The body (2.0 KB) isn't UTF-8 text, so it isn't shown")
        XCTAssertEqual(ResponseSummary.emptyBodyMessage(Fixture.empty), "No response body")
        XCTAssertEqual(ResponseSummary.emptyBodyMessage(HTTPResponse(statusCode: 204, headers: [], body: nil, responseTime: 0, contentType: nil)), "No response body")
        XCTAssertEqual(ResponseSummary.emptyBodyMessage(HTTPResponse(statusCode: 200, headers: [], body: nil, responseTime: 0, contentType: nil, bodySize: 0)), "No response body")

        let hosting = ViewHosting.host(ResponseViewerView(response: Fixture.binary, isLoading: false), size: wide)
        defer { ViewHosting.close(hosting) }
        let text = ViewHosting.text(in: hosting)
        XCTAssertTrue(text.contains("The body (2.0 KB) isn't UTF-8 text, so it isn't shown"))
        XCTAssertFalse(text.contains("No response body"), "Not beside a summary that says 2.0 KB arrived.")
    }

    func testTheShownTabIsExposedAsSelected() {
        let hosting = ViewHosting.host(ResponseViewerView(response: Fixture.json, isLoading: false), size: wide)
        defer { ViewHosting.close(hosting) }
        func selected() -> [String] { ViewHosting.elements(in: hosting).filter { $0.role == .button && $0.isSelected == true }.map(\.label) }
        XCTAssertEqual(selected(), ["Body"], "Not only by the pink underline.")
        AX.press("Headers, 3", in: hosting)
        XCTAssertEqual(selected(), ["Headers, 3"])
    }

    func testAPlainResponseAfterAStreamFallsBackFromEventsToBody() {
        let feed = Feed(Fixture.stream(.completed))
        let hosting = ViewHosting.host(FedView(feed: feed) { ResponseViewerView(response: $0, isLoading: false) }, size: wide)
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(AX.press("Events, 3", in: hosting))
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("3 events"))
        feed.value = Fixture.json
        ViewHosting.settle()
        XCTAssertFalse(ViewHosting.buttonLabels(in: hosting).contains { $0.hasPrefix("Events") })
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("View mode"), "Body is shown instead of an empty Events tab.")
    }

    func testALiveStreamUpdatesItsCountsAsEventsArrive() {
        let feed = Feed(Fixture.stream(.streaming, events: 1))
        let hosting = ViewHosting.host(FedView(feed: feed) { ResponseViewerView(response: $0, isLoading: false) }, size: wide)
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("Streaming · 1 event"))
        feed.value = Fixture.stream(.streaming, events: 4)
        ViewHosting.settle()
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("Streaming · 4 events"))
        XCTAssertTrue(ViewHosting.buttonLabels(in: hosting).contains("Events, 4"))
        feed.value = Fixture.stream(.stopped, events: 4)
        ViewHosting.settle()
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("Stopped"))
    }
}

// MARK: - ResponseBodyView

@MainActor
final class ResponseBodyViewTests: XCTestCase {
    typealias Mode = ResponseBodyView.ViewMode

    func testTextModeIsOfferedOnlyForAnAssembledReply() {
        XCTAssertEqual(ResponseBodyFormat.modes(hasAssembledText: false), [.pretty, .raw])
        XCTAssertEqual(ResponseBodyFormat.modes(hasAssembledText: true), [.text, .pretty, .raw])
    }

    func testAModeThatIsNotOfferedFallsBackToPretty() {
        XCTAssertEqual(ResponseBodyFormat.mode(.text, among: [.pretty, .raw]), .pretty)
        XCTAssertEqual(ResponseBodyFormat.mode(.raw, among: [.pretty, .raw]), .raw)
        XCTAssertEqual(ResponseBodyFormat.mode(.text, among: Mode.allCases), .text)
    }

    func testJSONIsPrettyPrintedByContentTypeOrByItsFirstCharacter() {
        let compact = #"{"b":1,"a":[true,null]}"#
        let pretty = JSONFormatter.prettify(compact)
        XCTAssertNotNil(pretty)
        XCTAssertTrue(ResponseBodyFormat.format(compact, contentType: "application/json") == (pretty!, true))
        XCTAssertTrue(ResponseBodyFormat.format(compact, contentType: nil) == (pretty!, true), "No content type, but it starts with {.")
        XCTAssertTrue(ResponseBodyFormat.format(compact, contentType: "text/plain") == (pretty!, true), "A mislabelled JSON body is still JSON.")
        XCTAssertTrue(ResponseBodyFormat.format("\n  [1,2]", contentType: nil) == (JSONFormatter.prettify("\n  [1,2]")!, true), "Leading whitespace is skipped.")
        XCTAssertTrue(ResponseBodyFormat.format("42", contentType: "application/problem+json") == ("42", true), "A JSON scalar, by its type.")
    }

    func testOtherBodiesAreShownAsReceived() {
        let cases: [(String, String?)] = [
            ("<h1>Hi</h1>", "text/html"), ("42", nil), ("true", "text/plain"), ("{not json", "application/json"), ("[1,2", nil), ("", "application/json"),
            ("caf\u{FFFD} \u{0}", "application/octet-stream")
        ]
        for (body, type) in cases {
            XCTAssertTrue(ResponseBodyFormat.format(body, contentType: type) == (body, false), "\(body) \(type ?? "nil")")
        }
        XCTAssertTrue(ResponseBodyFormat.format(nil, contentType: "application/json") == ("", false), "No body at all (not UTF-8, or none sent).")
    }

    func testAHugeJSONBodyIsStillFormatted() {
        let huge = "[" + (0..<50_000).map { #"{"i":\#($0)}"# }.joined(separator: ",") + "]"
        let result = ResponseBodyFormat.format(huge, contentType: "application/json")
        XCTAssertTrue(result.isJSON)
        XCTAssertGreaterThan(result.text.count, huge.count)
    }

    func testEachModeShowsItsOwnText() {
        XCTAssertEqual(ResponseBodyFormat.displayed(mode: .text, assembledText: "Hi", formatted: "F", raw: "R"), "Hi")
        XCTAssertEqual(ResponseBodyFormat.displayed(mode: .text, assembledText: nil, formatted: "F", raw: "R"), "")
        XCTAssertEqual(ResponseBodyFormat.displayed(mode: .pretty, assembledText: "Hi", formatted: "F", raw: "R"), "F")
        XCTAssertEqual(ResponseBodyFormat.displayed(mode: .raw, assembledText: "Hi", formatted: "F", raw: "R"), "R")
        XCTAssertEqual(ResponseBodyFormat.displayed(mode: .raw, assembledText: nil, formatted: "", raw: nil), "")
    }

    func testContentTypesGetShortNames() {
        let cases: [(String?, Bool, String?)] = [
            ("application/json", false, "JSON"), ("application/json; charset=utf-8", false, "JSON"), ("application/problem+json", false, "JSON"),
            ("application/x-ndjson", false, "JSON"), ("APPLICATION/JSON", false, "JSON"), ("text/html; charset=UTF-8", false, "HTML"), ("application/xhtml+xml", false, "HTML"),
            ("application/xml", false, "XML"), ("text/xml", false, "XML"), ("image/svg+xml", false, "XML"), ("text/plain", false, "Text"), (" Text/Plain ;q=1", false, "Text"),
            ("text/csv", false, "CSV"), ("text/event-stream", false, "EVENT-STREAM"), ("text/css", true, "CSS"), ("application/octet-stream", false, "application/octet-stream"),
            ("image/PNG", false, "image/png"), (nil, false, nil), (nil, true, "JSON"), ("", false, nil), ("", true, "JSON"), ("  ", false, nil)
        ]
        for (type, isJSON, label) in cases {
            XCTAssertEqual(ResponseBodyFormat.contentTypeLabel(type, isJSON: isJSON), label, "\(type ?? "nil") \(isJSON)")
        }
    }

    func testAContentTypeWithoutAMediaTypeIsNotLabelledByItsParameters() {
        XCTAssertNil(ResponseBodyFormat.contentTypeLabel("; charset=utf-8", isJSON: false))
        XCTAssertEqual(ResponseBodyFormat.contentTypeLabel(";charset=utf-8", isJSON: true), "JSON", "Known only from the body.")
        XCTAssertEqual(ResponseBodyFormat.fileExtension(mode: .pretty, label: ResponseBodyFormat.contentTypeLabel("; charset=utf-8", isJSON: true)), "json")
    }

    func testSavedFilesGetAnExtensionForWhatIsShown() {
        let cases: [(Mode, String?, String)] = [
            (.pretty, "JSON", "json"), (.raw, "JSON", "json"), (.pretty, "HTML", "html"), (.raw, "XML", "xml"), (.pretty, "Text", "txt"), (.pretty, "CSV", "txt"),
            (.pretty, "image/png", "txt"), (.pretty, nil, "txt"), (.text, "JSON", "txt")
        ]
        for (mode, label, ext) in cases {
            XCTAssertEqual(ResponseBodyFormat.fileExtension(mode: mode, label: label), ext, "\(mode) \(label ?? "nil")")
        }
    }

    // Rendering

    private func host(_ view: ResponseBodyView, size: CGSize = CGSize(width: 800, height: 400), appearance: NSAppearance.Name = .aqua) -> NSHostingView<AnyView> {
        ViewHosting.host(view, size: size, appearance: appearance)
    }

    func testJSONIsShownPrettyWithItsTypeAndTheModesToPickFrom() {
        let body = #"{"id":1,"name":"Ada"}"#
        let hosting = host(ResponseBodyView(responseBody: body, contentType: "application/json; charset=utf-8"))
        defer { ViewHosting.close(hosting) }
        XCTAssertEqual(AX.textViews(in: hosting).first?.string, JSONFormatter.prettify(body))
        let label = ViewHosting.elements(in: hosting).first { $0.label == "JSON" }
        XCTAssertEqual(label?.help, "application/json; charset=utf-8", "The full type is the label's tooltip.")
        XCTAssertEqual(ViewHosting.elements(in: hosting).filter { $0.role == .radioButton }.map(\.label), ["Pretty", "Raw"])
        XCTAssertEqual(AX.isChosen("Pretty", in: hosting), true)
        XCTAssertEqual(AX.isChosen("Raw", in: hosting), false)
    }

    func testChoosingRawShowsTheBodyAsReceived() {
        let body = #"{"id":1}"#
        let hosting = host(ResponseBodyView(responseBody: body, contentType: "application/json"), appearance: .darkAqua)
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(AX.press("Raw", role: .radioButton, in: hosting))
        XCTAssertEqual(AX.textViews(in: hosting).first?.string, body)
        XCTAssertEqual(AX.isChosen("Raw", in: hosting), true, "The chosen mode is exposed, not only drawn.")
    }

    private func withWrapping<T>(_ wraps: Bool, _ body: () throws -> T) rethrows -> T {
        let key = "responseWrapsLines"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(wraps, forKey: key)
        return try body()
    }

    func testToolbarButtonsAreLabelledWithTheirHelp() {
        let hosting = withWrapping(true) { host(ResponseBodyView(responseBody: "hello", contentType: "text/plain"), size: CGSize(width: 480, height: 300)) }
        defer { ViewHosting.close(hosting) }
        let buttons = ViewHosting.elements(in: hosting).filter { $0.role == .button }
        XCTAssertEqual(buttons.map(\.label), ["Don't wrap lines", "Find in body (⌘F)", "Save body to a file", "Copy body"])
        for button in buttons { XCTAssertEqual(button.label, button.help) }
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("Text"))
        XCTAssertEqual(AX.textViews(in: hosting).first?.string, "hello")
    }

    func testTheWrapButtonSaysWhatPressingItWillDo() {
        let saved = UserDefaults.standard.object(forKey: "responseWrapsLines")
        defer { UserDefaults.standard.set(saved, forKey: "responseWrapsLines") }
        let hosting = withWrapping(true) { host(ResponseBodyView(responseBody: "hello", contentType: nil)) }
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(AX.press("Don't wrap lines", in: hosting))
        XCTAssertTrue(ViewHosting.buttonLabels(in: hosting).contains("Wrap lines"), "The state is in the words, not only the tint.")
        XCTAssertTrue(AX.press("Wrap lines", in: hosting))
        XCTAssertTrue(ViewHosting.buttonLabels(in: hosting).contains("Don't wrap lines"))
    }

    func testAnEmptyBodySaysSoAndDisablesFindSaveAndCopy() {
        for body in [nil, ""] as [String?] {
            let hosting = host(ResponseBodyView(responseBody: body, contentType: nil))
            defer { ViewHosting.close(hosting) }
            XCTAssertTrue(ViewHosting.text(in: hosting).contains("No response body"))
            XCTAssertTrue(AX.textViews(in: hosting).isEmpty)
            for label in ["Find in body (⌘F)", "Save body to a file", "Copy body"] {
                XCTAssertEqual(AX.isEnabled(label, in: hosting), false, label)
            }
        }
    }

    func testTheEmptyMessageCanBeReplaced() {
        let hosting = host(ResponseBodyView(responseBody: nil, contentType: nil, emptyMessage: "No request body"))
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("No request body"))
    }

    func testAnAssembledReplyOpensInTextMode() {
        let hosting = host(ResponseBodyView(responseBody: "data: {\"delta\":\"Hel\"}\n\n", contentType: "text/event-stream", assembledText: "Hello there"))
        defer { ViewHosting.close(hosting) }
        XCTAssertEqual(ViewHosting.elements(in: hosting).filter { $0.role == .radioButton }.map(\.label), ["Text", "Pretty", "Raw"])
        XCTAssertEqual(AX.isChosen("Text", in: hosting), true)
        XCTAssertEqual(AX.textViews(in: hosting).first?.string, "Hello there")
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("EVENT-STREAM"))
    }

    func testTextModeIsChosenWhenTheReplyStartsArriving() {
        let feed = Feed<String?>(nil)
        let hosting = ViewHosting.host(FedView(feed: feed) { ResponseBodyView(responseBody: "data: x\n\n", contentType: "text/event-stream", assembledText: $0) })
        defer { ViewHosting.close(hosting) }
        XCTAssertEqual(AX.isChosen("Pretty", in: hosting), true)
        feed.value = "Hi"
        ViewHosting.settle()
        XCTAssertEqual(AX.isChosen("Text", in: hosting), true)
        XCTAssertEqual(AX.textViews(in: hosting).first?.string, "Hi")
    }

    func testANewBodyIsReformatted() {
        let feed = Feed(#"{"a":1}"#)
        let hosting = ViewHosting.host(FedView(feed: feed) { ResponseBodyView(responseBody: $0, contentType: nil) })
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("JSON"))
        feed.value = "plain words"
        ViewHosting.settle()
        XCTAssertEqual(AX.textViews(in: hosting).first?.string, "plain words")
        XCTAssertFalse(ViewHosting.text(in: hosting).contains("JSON"), "No type and not JSON: no label.")
    }

    func testHTMLAndBinaryTypesAreLabelled() {
        let html = host(ResponseBodyView(responseBody: "<p>x</p>", contentType: "text/html"))
        defer { ViewHosting.close(html) }
        XCTAssertTrue(ViewHosting.text(in: html).contains("HTML"))
        XCTAssertEqual(AX.textViews(in: html).first?.string, "<p>x</p>")
        let binary = host(ResponseBodyView(responseBody: nil, contentType: "image/png"))
        defer { ViewHosting.close(binary) }
        XCTAssertTrue(ViewHosting.text(in: binary).contains("image/png"))
    }
}

// MARK: - ResponseEventsView

@MainActor
final class ResponseEventsViewTests: XCTestCase {
    private let events = [
        StreamEvent(index: 0, time: 182, event: "message_start", data: #"{"type":"message_start"}"#),
        StreamEvent(index: 1, time: 240.4, event: "content_block_delta", data: #"{"delta":{"text":"Hello"}}"#), StreamEvent(index: 2, time: 1310, data: "[DONE]")
    ]

    func testFilterMatchesDataOrNameIgnoringCase() {
        XCTAssertEqual(ResponseEventsView.filter(events, by: "").map(\.index), [0, 1, 2])
        XCTAssertEqual(ResponseEventsView.filter(events, by: "hello").map(\.index), [1])
        XCTAssertEqual(ResponseEventsView.filter(events, by: "MESSAGE_START").map(\.index), [0])
        XCTAssertEqual(ResponseEventsView.filter(events, by: "content_block").map(\.index), [1], "By event name.")
        XCTAssertEqual(ResponseEventsView.filter(events, by: "done").map(\.index), [2])
        XCTAssertEqual(ResponseEventsView.filter(events, by: "nothing").map(\.index), [])
        XCTAssertEqual(ResponseEventsView.filter([], by: "x").map(\.index), [])
    }

    func testPlaceholderSaysWhyNothingIsListed() {
        XCTAssertEqual(ResponseEventsView.placeholder(events: [], filtered: [], isLive: true, searchText: ""), "Waiting for the first event…")
        XCTAssertEqual(ResponseEventsView.placeholder(events: [], filtered: [], isLive: false, searchText: "x"), "No events")
        XCTAssertEqual(ResponseEventsView.placeholder(events: events, filtered: [], isLive: true, searchText: "zz"), "No events match \u{201C}zz\u{201D}")
        XCTAssertNil(ResponseEventsView.placeholder(events: events, filtered: events, isLive: false, searchText: ""))
    }

    func testCountsAndTimesReadNaturally() {
        XCTAssertEqual(ResponseEventsView.countText(0), "0 events")
        XCTAssertEqual(ResponseEventsView.countText(1), "1 event")
        XCTAssertEqual(ResponseEventsView.countText(12), "12 events")
        XCTAssertEqual(events.map(ResponseEventsView.timeText), ["+182 ms", "+240 ms", "+1.31 s"])
        XCTAssertEqual(ResponseEventsView.timeText(StreamEvent(index: 0, time: 0.4, data: "")), "+0.4 ms")
    }

    func testRowPreviewIsOneShortLine() {
        XCTAssertEqual(ResponseEventsView.preview("a\nb\nc"), "a ⏎ b ⏎ c")
        XCTAssertEqual(ResponseEventsView.preview(""), "")
        XCTAssertEqual(ResponseEventsView.preview(String(repeating: "x", count: 1000)).count, 400)
        XCTAssertEqual(ResponseEventsView.preview(String(repeating: "😀", count: 500)).count, 400, "Characters, not bytes.")
    }

    func testDetailPrettyPrintsJSONData() {
        let json = ResponseEventsView.detailText(events[1])
        XCTAssertTrue(json.isJSON)
        XCTAssertEqual(json.text, JSONFormatter.prettify(events[1].data))
        XCTAssertTrue(json.text.contains("\n"))
        let done = ResponseEventsView.detailText(events[2])
        XCTAssertFalse(done.isJSON)
        XCTAssertEqual(done.text, "[DONE]")
        XCTAssertTrue(ResponseEventsView.detailText(StreamEvent(index: 0, time: 0, data: "")) == ("", false))
    }

    // Rendering

    func testEachEventIsListedWithItsNumberTimeNameAndData() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let hosting = ViewHosting.host(ResponseEventsView(events: events), size: CGSize(width: 700, height: 400), appearance: appearance)
            defer { ViewHosting.close(hosting) }
            XCTAssertTrue(ViewHosting.text(in: hosting).contains("3 events"))
            XCTAssertEqual(
                rows(in: hosting), ["1, +182 ms, message_start, {\"type\":\"message_start\"}", "2, +240 ms, content_block_delta, {\"delta\":{\"text\":\"Hello\"}}", "3, +1.31 s, [DONE]"])
        }
    }

    /// The events listed, one combined label per row as VoiceOver reads it.
    private func rows(in hosting: NSView) -> [String] {
        ViewHosting.elements(in: hosting).filter { $0.role == .button && $0.label.contains(", +") }.map(\.label)
    }

    func testNoEventsYetSaysItIsWaiting() {
        let live = ViewHosting.host(ResponseEventsView(events: [], isLive: true), size: CGSize(width: 500, height: 300))
        defer { ViewHosting.close(live) }
        XCTAssertTrue(ViewHosting.text(in: live).contains("Waiting for the first event…"))
        XCTAssertTrue(ViewHosting.text(in: live).contains("0 events"))
        let ended = ViewHosting.host(ResponseEventsView(events: [], isLive: false), size: CGSize(width: 500, height: 300))
        defer { ViewHosting.close(ended) }
        XCTAssertTrue(ViewHosting.text(in: ended).contains("No events"))
    }

    func testFilteringNarrowsTheList() {
        let hosting = ViewHosting.host(ResponseEventsView(events: events), size: CGSize(width: 700, height: 400))
        defer { ViewHosting.close(hosting) }
        AX.type("hello", in: hosting)
        XCTAssertEqual(rows(in: hosting).count, 1)
        XCTAssertTrue(rows(in: hosting).first?.contains("content_block_delta") == true)
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("3 events"), "The count is of all events.")
        AX.type("nothing here", in: hosting)
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("No events match \u{201C}nothing here\u{201D}"))
    }

    func testEventRowsAreButtonsThatOpenTheEventAndShowWhichIsOpen() throws {
        let hosting = ViewHosting.host(ResponseEventsView(events: events), size: CGSize(width: 700, height: 500))
        defer { ViewHosting.close(hosting) }
        let rows = ViewHosting.elements(in: hosting).filter { $0.role == .button && $0.label.contains(", +") }
        XCTAssertEqual(rows.count, 3, "Each event is one element VoiceOver can press.")
        let second = try XCTUnwrap(rows.first { $0.label.contains("content_block_delta") })
        XCTAssertTrue(second.label.hasPrefix("2"), second.label)
        XCTAssertTrue(second.label.contains("+240 ms"), second.label)
        XCTAssertNotEqual(second.isSelected, true)

        XCTAssertTrue(AX.press(second.label, in: hosting))
        let text = ViewHosting.text(in: hosting)
        XCTAssertTrue(text.contains("Event 2"))
        XCTAssertEqual(AX.textViews(in: hosting).first?.string, JSONFormatter.prettify(events[1].data), "The data in full, pretty-printed.")
        XCTAssertEqual(ViewHosting.elements(in: hosting).first { $0.label == second.label }?.isSelected, true, "The open event is selected, not only highlighted.")
        let detailButtons = ViewHosting.elements(in: hosting).filter { $0.role == .button && ["Copy data", "Close"].contains($0.label) }
        XCTAssertEqual(detailButtons.map(\.help), ["Copy data", "Close"])

        XCTAssertTrue(AX.press("Close", in: hosting))
        XCTAssertFalse(ViewHosting.text(in: hosting).contains("Event 2"))
        XCTAssertNotEqual(ViewHosting.elements(in: hosting).first { $0.label == second.label }?.isSelected, true)
    }

    func testClearingTheFilterIsLabelledAndListsEveryEventAgain() {
        let hosting = ViewHosting.host(ResponseEventsView(events: events), size: CGSize(width: 700, height: 400))
        defer { ViewHosting.close(hosting) }
        AX.type("hello", in: hosting)
        let clear = ViewHosting.elements(in: hosting).first { $0.role == .button && $0.help == "Clear filter" }
        XCTAssertEqual(clear?.label, "Clear filter")
        XCTAssertTrue(AX.press("Clear filter", in: hosting))
        XCTAssertEqual(rows(in: hosting).count, 3)
    }

    func testNewEventsAppearAsTheyArrive() {
        let feed = Feed(Array(events.prefix(1)))
        let hosting = ViewHosting.host(FedView(feed: feed) { ResponseEventsView(events: $0, isLive: true) }, size: CGSize(width: 700, height: 400))
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("1 event"))
        feed.value = events
        ViewHosting.settle()
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("3 events"))
        XCTAssertEqual(rows(in: hosting).last, "3, +1.31 s, [DONE]")
    }
}

// MARK: - ResponseHeadersView

@MainActor
final class ResponseHeadersViewTests: XCTestCase {
    private let headers = [
        KeyValuePair(key: "x-request-id", value: "abc123"), KeyValuePair(key: "Content-Type", value: "application/json"),
        KeyValuePair(key: "access-control-expose-headers", value: "X-Request-Id,X-RateLimit-Limit,Retry-After")
    ]

    func testHeadersAreSortedByNameIgnoringCase() {
        XCTAssertEqual(ResponseHeadersView.sorted(headers).map(\.key), ["access-control-expose-headers", "Content-Type", "x-request-id"])
        XCTAssertEqual(ResponseHeadersView.sorted([]).map(\.key), [])
    }

    func testFilterMatchesNamesAndValuesIgnoringCase() {
        XCTAssertEqual(ResponseHeadersView.filter(headers, by: "").count, 3)
        XCTAssertEqual(ResponseHeadersView.filter(headers, by: "CONTENT").map(\.key), ["Content-Type"])
        XCTAssertEqual(ResponseHeadersView.filter(headers, by: "abc").map(\.key), ["x-request-id"], "By value.")
        XCTAssertEqual(ResponseHeadersView.filter(headers, by: "request-id").map(\.key), ["x-request-id", "access-control-expose-headers"])
        XCTAssertEqual(ResponseHeadersView.filter(headers, by: "zzz").count, 0)
    }

    func testCountSaysHowManyMatchWhileFiltering() {
        XCTAssertEqual(ResponseHeadersView.countText(total: 3, matching: 3, isFiltering: false), "3 headers")
        XCTAssertEqual(ResponseHeadersView.countText(total: 3, matching: 1, isFiltering: true), "1 of 3")
        XCTAssertEqual(ResponseHeadersView.countText(total: 3, matching: 0, isFiltering: true), "0 of 3")
        XCTAssertEqual(ResponseHeadersView.countText(total: 0, matching: 0, isFiltering: false), "0 headers")
    }

    func testCopyAllGivesOneSortedLinePerHeader() {
        XCTAssertEqual(
            ResponseHeadersView.copyText(headers),
            "access-control-expose-headers: X-Request-Id,X-RateLimit-Limit,Retry-After\nContent-Type: application/json\nx-request-id: abc123")
        XCTAssertEqual(ResponseHeadersView.copyText([]), "")
    }

    func testPlaceholderSaysWhyNoRowsShow() {
        XCTAssertEqual(ResponseHeadersView.placeholder(total: 0, matching: 0, searchText: ""), "No response headers")
        XCTAssertEqual(ResponseHeadersView.placeholder(total: 2, matching: 0, searchText: "zz"), "No headers match \u{201C}zz\u{201D}")
        XCTAssertNil(ResponseHeadersView.placeholder(total: 2, matching: 1, searchText: "a"))
    }

    func testNameColumnFitsTheLongestNameWithinBounds() {
        XCTAssertEqual(ResponseHeadersView.keyColumnWidth(for: []), 120)
        XCTAssertEqual(ResponseHeadersView.keyColumnWidth(for: [KeyValuePair(key: "Age", value: "1")]), 120)
        XCTAssertEqual(ResponseHeadersView.keyColumnWidth(for: [KeyValuePair(key: String(repeating: "X", count: 200), value: "")]), 260)
        let middle = ResponseHeadersView.keyColumnWidth(for: [KeyValuePair(key: "access-control-expose-headers", value: "")])
        XCTAssertGreaterThan(middle, 120)
        XCTAssertLessThan(middle, 260)
    }

    // Rendering

    func testRowsAreSortedAndListValuesSplitIntoItems() {
        for size in [CGSize(width: 900, height: 400), CGSize(width: 420, height: 400)] {
            let hosting = ViewHosting.host(ResponseHeadersView(headers: headers), size: size, appearance: .darkAqua)
            defer { ViewHosting.close(hosting) }
            let text = ViewHosting.text(in: hosting)
            XCTAssertTrue(text.contains("3 headers"))
            let names = text.filter { ["access-control-expose-headers", "Content-Type", "x-request-id"].contains($0) }
            XCTAssertEqual(names, ["access-control-expose-headers", "Content-Type", "x-request-id"])
            for item in ["X-Request-Id", "X-RateLimit-Limit", "Retry-After", "application/json", "abc123"] { XCTAssertTrue(text.contains(item), item) }
            XCTAssertEqual(ViewHosting.elements(in: hosting).first { $0.label == "access-control-expose-headers" }?.help, "access-control-expose-headers", "A truncated name has it in full.")
        }
    }

    func testCopyAllIsLabelledAndEachRowOffersItsCopiesAsActions() {
        let hosting = ViewHosting.host(ResponseHeadersView(headers: headers), size: CGSize(width: 900, height: 400))
        defer { ViewHosting.close(hosting) }
        let buttons = ViewHosting.elements(in: hosting).filter { $0.role == .button }
        // A row's Copy value button is transparent until the pointer is over the row, and SwiftUI leaves it out of the tree until then.
        XCTAssertEqual(buttons.map(\.label), ["Copy all headers"])
        // So each row offers the copies as actions VoiceOver lists (VO-Command-Space).
        let actions = Self.customActionNames(in: hosting)
        let copies: Set = ["Copy Name", "Copy Value", "Copy Header"]
        XCTAssertGreaterThanOrEqual(actions.filter { copies.isSubset(of: $0) }.count, headers.count, "Every row has the three copies: \(actions)")
        XCTAssertEqual(buttons.first?.help, "Copy all headers")
        XCTAssertEqual(AX.isEnabled("Copy all headers", in: hosting), true)
    }

    /// The custom action names of every accessibility element under `root` that has some.
    private static func customActionNames(in root: NSView) -> [[String]] {
        var found: [[String]] = []
        func visit(_ object: Any, depth: Int) {
            guard depth < 60, let node = object as? NSObject else { return }
            let selector = NSSelectorFromString("accessibilityCustomActions")
            if node.responds(to: selector), let actions = node.perform(selector)?.takeUnretainedValue() as? [NSAccessibilityCustomAction], !actions.isEmpty {
                found.append(actions.map(\.name))
            }
            let children = NSSelectorFromString("accessibilityChildren")
            for child in (node.responds(to: children) ? node.perform(children)?.takeUnretainedValue() as? [Any] : nil) ?? [] { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return found
    }

    func testFilteringShowsTheMatchCount() {
        let hosting = ViewHosting.host(ResponseHeadersView(headers: headers), size: CGSize(width: 900, height: 400))
        defer { ViewHosting.close(hosting) }
        AX.type("content", in: hosting)
        let text = ViewHosting.text(in: hosting)
        XCTAssertTrue(text.contains("1 of 3"))
        XCTAssertTrue(text.contains("Content-Type"))
        XCTAssertFalse(text.contains("x-request-id"))
        AX.type("nope", in: hosting)
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("No headers match \u{201C}nope\u{201D}"))
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("0 of 3"))
    }

    func testClearingTheFilterIsLabelledAndShowsEveryHeaderAgain() {
        let hosting = ViewHosting.host(ResponseHeadersView(headers: headers), size: CGSize(width: 900, height: 400))
        defer { ViewHosting.close(hosting) }
        XCTAssertFalse(ViewHosting.buttonLabels(in: hosting).contains("Clear filter"), "Nothing to clear yet.")
        AX.type("content", in: hosting)
        let clear = ViewHosting.elements(in: hosting).first { $0.role == .button && $0.help == "Clear filter" }
        XCTAssertEqual(clear?.label, "Clear filter")
        XCTAssertTrue(AX.press("Clear filter", in: hosting))
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("3 headers"))
    }

    func testNoHeadersSaysSoAndCannotCopy() {
        let hosting = ViewHosting.host(ResponseHeadersView(headers: []), size: CGSize(width: 600, height: 300))
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("No response headers"))
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("0 headers"))
        XCTAssertEqual(AX.isEnabled("Copy all headers", in: hosting), false)
    }
}

// MARK: - ResponseCookiesView

@MainActor
final class ResponseCookiesViewTests: XCTestCase {
    private func cookie(expires: Date? = nil, secure: Bool = false, httpOnly: Bool = false, sameSite: String? = nil) -> ResponseCookie {
        ResponseCookie(name: "theme", value: "dark", domain: ".example.com", path: "/app", expires: expires, isSecure: secure, isHTTPOnly: httpOnly, sameSite: sameSite)
    }

    func testACookieWithoutExpiryIsASessionCookie() {
        XCTAssertEqual(ResponseCookiesView.expiryText(cookie()), "Session")
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(ResponseCookiesView.expiryText(cookie(expires: date)), "Expires \(date.formatted(date: .abbreviated, time: .shortened))")
    }

    func testFlagsListOnlyTheAttributesSetInOrder() {
        XCTAssertEqual(ResponseCookiesView.flags(cookie()), [])
        XCTAssertEqual(ResponseCookiesView.flags(cookie(secure: true)), ["Secure"])
        XCTAssertEqual(ResponseCookiesView.flags(cookie(httpOnly: true, sameSite: "Strict")), ["HttpOnly", "SameSite=Strict"])
        XCTAssertEqual(ResponseCookiesView.flags(cookie(secure: true, httpOnly: true, sameSite: "None")), ["Secure", "HttpOnly", "SameSite=None"])
    }

    // Rendering

    func testNoCookiesExplainsIt() {
        let hosting = ViewHosting.host(ResponseCookiesView(cookies: []), size: CGSize(width: 500, height: 300), appearance: .darkAqua)
        defer { ViewHosting.close(hosting) }
        let text = ViewHosting.text(in: hosting)
        XCTAssertTrue(text.contains("No cookies"))
        XCTAssertTrue(text.contains("This response didn't set any cookies."))
    }

    func testEachCookieShowsItsValueScopeExpiryAndFlags() {
        let cookies = [Fixture.sessionCookie, cookie(expires: Date(timeIntervalSince1970: 2_000_000_000))]
        for size in [CGSize(width: 900, height: 400), CGSize(width: 420, height: 400)] {
            let hosting = ViewHosting.host(ResponseCookiesView(cookies: cookies), size: size)
            defer { ViewHosting.close(hosting) }
            let rows = AX.cellElements(in: hosting).map { $0.map(\.label).filter { !$0.isEmpty } }
            XCTAssertEqual(rows.count, 2)
            for expected in ["sid", "abc123", "api.example.com/", "Session", "Secure", "HttpOnly", "SameSite=Lax"] {
                XCTAssertTrue(rows.first?.contains(expected) == true, expected)
            }
            for expected in ["theme", "dark", ".example.com/app", ResponseCookiesView.expiryText(cookies[1])] {
                XCTAssertTrue(rows.last?.contains(expected) == true, expected)
            }
            XCTAssertFalse(rows.last?.contains("Secure") == true)
        }
    }

    func testEachCookiesCopyButtonIsLabelled() {
        let hosting = ViewHosting.host(ResponseCookiesView(cookies: [Fixture.sessionCookie]), size: CGSize(width: 700, height: 300))
        defer { ViewHosting.close(hosting) }
        let buttons = AX.cellElements(in: hosting).flatMap { $0 }.filter { $0.role == .button }
        XCTAssertEqual(buttons.map(\.label), ["Copy value"])
        XCTAssertEqual(buttons.map(\.help), ["Copy value"])
    }
}

// MARK: - ResponseTimingView

@MainActor
final class ResponseTimingViewTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1000)

    private func timing(reused: Bool = false, redirects: Int = 0, phases: Bool = true) -> ResponseTiming {
        let at = { (ms: Double) in self.start.addingTimeInterval(ms / 1000) }
        let marks =
            phases
            ? ResponseTiming.Marks(
                domainLookupStart: at(0), domainLookupEnd: at(4), connectStart: at(4), secureConnectionStart: at(20), secureConnectionEnd: at(50), connectEnd: at(50),
                requestStart: at(50), requestEnd: at(52), responseStart: at(160), responseEnd: at(180)) : ResponseTiming.Marks()
        return ResponseTiming(
            taskStart: start, total: 182, marks: marks, networkProtocol: "HTTP/2", isReusedConnection: reused, remoteAddress: "93.184.216.34:443", tlsVersion: "TLS 1.3",
            redirectCount: redirects)
    }

    func testChipsDescribeTheConnection() {
        XCTAssertTrue(
            ResponseTimingView.chips(timing()).map(\.title) == ["HTTP/2", "TLS 1.3", "New connection", "93.184.216.34:443"]
                && ResponseTimingView.chips(timing()).map(\.monospaced) == [false, false, false, true])
        XCTAssertEqual(ResponseTimingView.chips(timing(reused: true, redirects: 1)).map(\.title), ["HTTP/2", "TLS 1.3", "Reused connection", "1 redirect", "93.184.216.34:443"])
        XCTAssertTrue(ResponseTimingView.chips(timing(redirects: 3)).map(\.title).contains("3 redirects"))
        let bare = ResponseTiming(taskStart: start, total: 5, marks: ResponseTiming.Marks())
        XCTAssertEqual(ResponseTimingView.chips(bare).map(\.title), ["New connection"])
    }

    func testStreamRowsShowWhatArrivedAndDashesForWhatDidNot() {
        let reply = StreamInfo(kind: .sse, events: Fixture.events(2), firstByteTime: 80, text: "Hi", firstTextTime: 120.4, end: .completed)
        XCTAssertTrue(
            ResponseTimingView.streamRows(reply).map { "\($0.label)=\($0.value)" } == [
                "Stream=Server-sent events", "Events=2", "First byte=80 ms", "First token=120 ms", "Last event=140 ms"
            ])
        let noText = StreamInfo(kind: .ndjson, end: .streaming)
        XCTAssertTrue(ResponseTimingView.streamRows(noText).map { "\($0.label)=\($0.value)" } == ["Stream=NDJSON", "Events=0", "First byte=–", "Last event=–"])
        let textNotYet = StreamInfo(kind: .sse, text: "", end: .streaming)
        XCTAssertTrue(ResponseTimingView.streamRows(textNotYet).contains { $0.label == "First token" && $0.value == "–" })
    }

    func testWaterfallSpansTheTotalOrTheLastPhaseEnd() {
        XCTAssertEqual(ResponseTimingView.waterfallSpan(timing()), 182)
        let late = ResponseTiming(
            taskStart: start, total: 10, marks: ResponseTiming.Marks(responseStart: start, responseEnd: start.addingTimeInterval(0.05)))
        XCTAssertEqual(ResponseTimingView.waterfallSpan(late), 50, accuracy: 0.001, "A phase that ends after the reported total still fits.")
        XCTAssertEqual(ResponseTimingView.waterfallSpan(ResponseTiming(taskStart: start, total: 0, marks: ResponseTiming.Marks())), 1, "Never divides by zero.")
    }

    func testEveryPhaseHasItsOwnColor() {
        let colors = ResponseTiming.Phase.Kind.allCases.map { NSColor(ResponseTimingView.color(for: $0)).usingColorSpace(.sRGB)?.description ?? "" }
        XCTAssertEqual(Set(colors).count, colors.count)
    }

    // Rendering

    func testTheWaterfallNamesEachPhaseAndItsDuration() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let hosting = ViewHosting.host(ResponseTimingView(totalTime: 999, timing: timing()), size: CGSize(width: 700, height: 500), appearance: appearance)
            defer { ViewHosting.close(hosting) }
            let text = ViewHosting.text(in: hosting)
            XCTAssertTrue(text.contains("182 ms"), "The measured total wins over the reported time.")
            XCTAssertTrue(text.contains("total"))
            for chip in ["HTTP/2", "TLS 1.3", "New connection", "93.184.216.34:443"] { XCTAssertTrue(text.contains(chip), chip) }
            let expected = ["DNS lookup", "4.0 ms", "TCP connect", "16 ms", "TLS handshake", "30 ms", "Request sent", "2.0 ms", "Waiting (TTFB)", "108 ms", "Content download", "20 ms"]
            for item in expected { XCTAssertTrue(text.contains(item), "Each phase is named, not only coloured: \(item)") }
            XCTAssertFalse(text.contains("A detailed breakdown isn't available for this response."))
        }
    }

    func testWithoutPhasesItSaysNoBreakdownIsAvailable() {
        for timing in [nil, timing(phases: false)] {
            let hosting = ViewHosting.host(ResponseTimingView(totalTime: 42, timing: timing), size: CGSize(width: 420, height: 400))
            defer { ViewHosting.close(hosting) }
            let text = ViewHosting.text(in: hosting)
            XCTAssertTrue(text.contains(timing == nil ? "42 ms" : "182 ms"))
            XCTAssertTrue(text.contains("A detailed breakdown isn't available for this response."))
        }
    }

    func testAStreamAddsWhenItsBytesTokensAndEventsArrived() {
        let stream = StreamInfo(kind: .sse, events: Fixture.events(3), firstByteTime: 80, text: "Hi", firstTextTime: 120, end: .stopped)
        let hosting = ViewHosting.host(ResponseTimingView(totalTime: 900, timing: nil, stream: stream), size: CGSize(width: 700, height: 500))
        defer { ViewHosting.close(hosting) }
        let text = ViewHosting.text(in: hosting)
        for item in ["Stream", "Server-sent events", "Events", "3", "First byte", "80 ms", "First token", "120 ms", "Last event", "180 ms"] {
            XCTAssertTrue(text.contains(item), item)
        }
    }
}

// MARK: - ResponseTextView

@MainActor
final class ResponseTextViewTests: XCTestCase {
    private struct Input {
        var text: String
        var wraps = true
        var find = 0
        var followsEnd = false
    }

    private func host(_ feed: Feed<Input>, size: CGSize = CGSize(width: 500, height: 200)) -> NSHostingView<AnyView> {
        ViewHosting.host(
            FedView(feed: feed) { ResponseTextView(text: $0.text, highlightsJSON: false, wrapsLines: $0.wraps, findRequest: $0.find, followsEnd: $0.followsEnd) }, size: size)
    }

    private func scrollView(in hosting: NSView) throws -> NSScrollView {
        try XCTUnwrap(AX.textViews(in: hosting).first?.enclosingScrollView)
    }

    private func lines(_ count: Int, prefix: String = "line") -> String { (1...count).map { "\(prefix) \($0)" }.joined(separator: "\n") }

    func testShowsTheTextReadOnlyWithLineNumbers() throws {
        let hosting = host(Feed(Input(text: "{\n  \"a\": 1\n}")))
        defer { ViewHosting.close(hosting) }
        let textView = try XCTUnwrap(AX.textViews(in: hosting).first)
        XCTAssertEqual(textView.string, "{\n  \"a\": 1\n}")
        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        let scroll = try scrollView(in: hosting)
        XCTAssertTrue(scroll.verticalRulerView is LineNumberRulerView)
        XCTAssertTrue(scroll.rulersVisible)
        XCTAssertTrue(ViewHosting.elements(in: hosting).contains { $0.role == .textArea && $0.label == textView.string }, "VoiceOver reads the body.")
    }

    func testWrappingTogglesTheHorizontalScroller() throws {
        let feed = Feed(Input(text: String(repeating: "wide ", count: 200)))
        let hosting = host(feed)
        defer { ViewHosting.close(hosting) }
        let scroll = try scrollView(in: hosting)
        let textView = try XCTUnwrap(AX.textViews(in: hosting).first)
        XCTAssertFalse(scroll.hasHorizontalScroller)
        XCTAssertEqual(textView.textContainer?.widthTracksTextView, true)
        feed.value.wraps = false
        ViewHosting.settle()
        XCTAssertTrue(scroll.hasHorizontalScroller)
        XCTAssertEqual(textView.textContainer?.widthTracksTextView, false)
        XCTAssertGreaterThan(textView.frame.width, scroll.contentSize.width, "One long line runs past the edge.")
    }

    func testOnlyALaterFindRequestOpensTheFindBar() throws {
        let feed = Feed(Input(text: "find me", find: 3))
        let hosting = host(feed)
        defer { ViewHosting.close(hosting) }
        let scroll = try scrollView(in: hosting)
        XCTAssertFalse(scroll.isFindBarVisible, "The count it starts with doesn't open it.")
        feed.value.find += 1
        ViewHosting.settle()
        XCTAssertTrue(scroll.isFindBarVisible)
    }

    func testNewTextScrollsToTheTopButGrowingTextKeepsThePlace() throws {
        let feed = Feed(Input(text: lines(200)))
        let hosting = host(feed)
        defer { ViewHosting.close(hosting) }
        let scroll = try scrollView(in: hosting)
        let textView = try XCTUnwrap(AX.textViews(in: hosting).first)
        textView.scroll(NSPoint(x: 0, y: 600))
        let place = scroll.contentView.bounds.minY
        XCTAssertGreaterThan(place, 0)
        feed.value.text += "\nmore"
        ViewHosting.settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, place, accuracy: 1, "A stream's text grew; the reader stays put.")
        feed.value.text = lines(200, prefix: "other")
        ViewHosting.settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1, "A different body starts at its top.")
    }

    func testFollowingTheEndKeepsArrivingTextInView() throws {
        let feed = Feed(Input(text: lines(100), followsEnd: true))
        let hosting = host(feed)
        defer { ViewHosting.close(hosting) }
        let scroll = try scrollView(in: hosting)
        let textView = try XCTUnwrap(AX.textViews(in: hosting).first)
        textView.scrollToEndOfDocument(nil)
        feed.value.text += "\n" + lines(50, prefix: "new")
        ViewHosting.settle()
        XCTAssertEqual(scroll.contentView.bounds.maxY, textView.frame.height, accuracy: 2)
    }
}
