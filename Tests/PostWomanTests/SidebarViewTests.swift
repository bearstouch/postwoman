import AppKit
import SwiftData
import SwiftUI
import XCTest

@testable import PostWoman

/// Hosts a view in a titled window, so its toolbar exists, and reads the whole accessibility tree: through the NSAccessibility
/// getters and through the older attribute API that list rows and toolbar items answer (which `ViewHosting` doesn't read).
@MainActor
private final class WindowHost {
    struct Node {
        let object: NSObject
        let role: String
        let texts: [String]
        let help: String
        let isSelected: Bool
        let isEnabled: Bool
        let children: [Node]
        var label: String { texts.first ?? "" }
        var all: [Node] { [self] + children.flatMap(\.all) }
        var allText: [String] { all.flatMap(\.texts) }
    }

    let window: NSWindow

    init(_ view: some View, size: CGSize = CGSize(width: 900, height: 600), appearance: NSAppearance.Name = .aqua, container: ModelContainer) {
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = NSHostingController(rootView: AnyView(view.modelContainer(container)))
        window.setContentSize(size)
        window.orderFrontRegardless()
        ViewHosting.settle(0.2)
    }

    func close() {
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
        ViewHosting.settle()
    }

    /// Everything `object` (a window, say a sheet) exposes as text.
    static func text(of object: NSObject) -> [String] {
        var seen = Set<ObjectIdentifier>()
        return read(object, depth: 0, seen: &seen)?.allText ?? []
    }

    var root: Node {
        var seen = Set<ObjectIdentifier>()
        return Self.read(window, depth: 0, seen: &seen)!
    }

    var nodes: [Node] { root.all }
    var text: [String] { nodes.flatMap(\.texts) }
    var buttons: [Node] { nodes.filter { ["AXButton", "AXMenuButton", "AXPopUpButton"].contains($0.role) } }
    func button(_ label: String) -> Node? { buttons.first { $0.label == label } }
    /// List rows that show something (AppKit lists the same rows twice; the second time they're empty).
    var rows: [Node] { nodes.filter { $0.role == "AXRow" && !$0.allText.isEmpty } }
    var toolbarButtons: [Node] { nodes.first { $0.role == "AXToolbar" }?.all.filter { $0.role == "AXButton" || $0.role == "AXMenuButton" } ?? [] }

    /// Selects the `row`th row of the list that shows `text`, as a click would.
    func selectRow(_ row: Int, inListShowing text: String) {
        func lists(in view: NSView) -> [NSOutlineView] { (view as? NSOutlineView).map { [$0] } ?? view.subviews.flatMap(lists) }
        guard let outline = lists(in: window.contentView!).first(where: { Self.text(of: $0).contains(text) }) else { return XCTFail("No list shows \(text)") }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        ViewHosting.settle()
    }

    /// Presses a button as VoiceOver does.
    func press(_ node: Node) {
        _ = node.object.perform(NSSelectorFromString("accessibilityPerformPress"))
        ViewHosting.settle()
    }

    private static func get(_ node: NSObject, _ getter: String) -> Any? {
        node.responds(to: NSSelectorFromString(getter)) ? node.perform(NSSelectorFromString(getter))?.takeUnretainedValue() : nil
    }

    private static func attribute(_ node: NSObject, _ name: String) -> Any? {
        guard node.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) else { return nil }
        return node.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: name)?.takeUnretainedValue()
    }

    private static func flag(_ node: NSObject, getter: String, key: String, attribute name: String) -> Bool? {
        if node.responds(to: NSSelectorFromString(getter)), let value = node.value(forKey: key) as? Bool { return value }
        return (attribute(node, name) as? NSNumber)?.boolValue
    }

    private static func read(_ object: Any, depth: Int, seen: inout Set<ObjectIdentifier>) -> Node? {
        guard depth < 60, let node = object as? NSObject, seen.insert(ObjectIdentifier(node)).inserted else { return nil }
        var texts: [String] = []
        for text in [get(node, "accessibilityLabel"), get(node, "accessibilityTitle"), get(node, "accessibilityValue")]
            + [attribute(node, "AXDescription"), attribute(node, "AXTitle"), attribute(node, "AXValue")]
        {
            if let text = text as? String, !text.isEmpty, !texts.contains(text) { texts.append(text) }
        }
        var children: [Node] = []
        for child in (get(node, "accessibilityChildren") as? [Any] ?? []) + (attribute(node, "AXChildren") as? [Any] ?? []) {
            if let read = read(child, depth: depth + 1, seen: &seen) { children.append(read) }
        }
        return Node(
            object: node, role: get(node, "accessibilityRole") as? String ?? attribute(node, "AXRole") as? String ?? "", texts: texts,
            help: get(node, "accessibilityHelp") as? String ?? attribute(node, "AXHelp") as? String ?? "",
            isSelected: flag(node, getter: "isAccessibilitySelected", key: "accessibilitySelected", attribute: "AXSelected") ?? false,
            isEnabled: flag(node, getter: "isAccessibilityEnabled", key: "accessibilityEnabled", attribute: "AXEnabled") ?? true, children: children)
    }
}

/// A store like a user's: "Shop API" with three requests and a Staging environment in use, an empty "Empty" collection,
/// and History with a success, a server error, a failure without a response and a streamed reply.
@MainActor
private struct SidebarFixture {
    let container: ModelContainer
    let shop: Folder
    let empty: Folder
    let staging: CollectionEnvironment
    let listOrders: APIRequest
    let createOrder: APIRequest
    let deleteOrder: APIRequest
    let success: RequestHistory
    let serverError: RequestHistory
    let offline: RequestHistory
    let streamed: RequestHistory
    let yesterday: RequestHistory
    var context: ModelContext { container.mainContext }

    /// Every fixture's store, for the whole run: a closed window's `@Query` can outlive its test, and it traps when a later
    /// save notifies it after its store is gone.
    private static var keptAlive: [ModelContainer] = []

    /// An empty store, kept alive like the fixtures'.
    static func emptyStore() throws -> ModelContainer {
        let container = try ViewHosting.container()
        keptAlive.append(container)
        return container
    }

    init() throws {
        container = try ViewHosting.container()
        Self.keptAlive.append(container)
        let context = container.mainContext
        let shop = Folder(name: "Shop API", sortOrder: 0)
        self.shop = shop
        empty = Folder(name: "Empty", sortOrder: 1)
        context.insert(shop)
        context.insert(empty)
        shop.ensureDefaultEnvironment().variables = [Variable(key: "baseUrl", value: "https://shop.local")]
        empty.ensureDefaultEnvironment()
        staging = shop.addEnvironment(named: "Staging", color: .orange)
        shop.addEnvironment(named: "Production", color: .red)
        shop.selectedEnvironment = staging

        func request(_ name: String, _ method: HTTPMethod, _ url: String, order: Int) -> APIRequest {
            let request = APIRequest(name: name, url: url, method: method, folder: shop)
            request.sortOrder = order
            context.insert(request)
            return request
        }
        createOrder = request("Create Order", .post, "{{baseUrl}}/orders", order: 1)
        listOrders = request("List Orders", .get, "{{baseUrl}}/orders", order: 0)
        deleteOrder = request("Delete Order", .delete, "{{baseUrl}}/orders/1", order: 2)

        func entry(_ method: HTTPMethod, _ url: String, status: Int?, secondsAgo: TimeInterval) -> RequestHistory {
            let entry = RequestHistory(url: url, method: method)
            entry.timestamp = Date().addingTimeInterval(-secondsAgo)
            if let status {
                entry.record(HTTPResponse(statusCode: status, headers: [], body: #"{"ok":true}"#, responseTime: 42, contentType: "application/json"))
            }
            context.insert(entry)
            return entry
        }
        success = entry(.get, "https://shop.local/orders", status: 200, secondsAgo: 1)
        serverError = entry(.post, "https://shop.local/orders", status: 500, secondsAgo: 2)
        offline = entry(.put, "https://offline.local/orders/1", status: nil, secondsAgo: 3)
        offline.record(URLError(.notConnectedToInternet))
        streamed = entry(.post, "https://llm.local/v1/chat", status: nil, secondsAgo: 4)
        streamed.record(
            HTTPResponse(
                statusCode: 200, headers: [], body: "data: hi", responseTime: 80, contentType: "text/event-stream",
                stream: StreamInfo(kind: .sse, text: "Hello from the stream", end: .completed)))
        // Within today when run just after midnight is impossible to guarantee, so pin "yesterday" to noon yesterday.
        yesterday = entry(.delete, "https://shop.local/old", status: 404, secondsAgo: 0)
        yesterday.timestamp = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!.addingTimeInterval(12 * 3600)
        try context.save()
    }

    func folders() throws -> [Folder] { try context.fetch(FetchDescriptor<Folder>(sortBy: [SortDescriptor(\.sortOrder)])) }
    func history() throws -> [RequestHistory] { try context.fetch(FetchDescriptor<RequestHistory>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])) }
}

// MARK: - RequestRowView

@MainActor
final class RequestRowViewTests: XCTestCase {
    func testShowsEveryMethodAndTheNameInAnyWidthAndAppearance() throws {
        let container = try ViewHosting.container()
        for method in HTTPMethod.allCases {
            let request = APIRequest(name: "A request with a rather long name for \(method.rawValue)", url: "https://x", method: method)
            container.mainContext.insert(request)
            for (width, appearance) in [(CGFloat(120), NSAppearance.Name.aqua), (400, .darkAqua)] {
                let hosting = ViewHosting.host(RequestRowView(request: request), size: CGSize(width: width, height: 30), appearance: appearance, container: container)
                defer { ViewHosting.close(hosting) }
                XCTAssertEqual(ViewHosting.text(in: hosting), [method.rawValue, request.name], "Truncated on screen, read in full")
            }
        }
    }

    func testFollowsEdits() throws {
        let container = try ViewHosting.container()
        let request = APIRequest(name: "Get Users", url: "https://x")
        container.mainContext.insert(request)
        let hosting = ViewHosting.host(RequestRowView(request: request), size: CGSize(width: 250, height: 30), container: container)
        defer { ViewHosting.close(hosting) }
        request.name = "Create User"
        request.method = .post
        ViewHosting.settle()
        XCTAssertEqual(ViewHosting.text(in: hosting), ["POST", "Create User"])
    }
}

// MARK: - FolderRowView

@MainActor
final class FolderRowViewTests: XCTestCase {
    func testShowsTheNameTheEnvironmentInUseByNameAndTheRequestCount() throws {
        let fixture = try SidebarFixture()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = WindowHost(List { FolderRowView(folder: fixture.shop) }, size: CGSize(width: 300, height: 120), appearance: appearance, container: fixture.container)
            defer { host.close() }
            let row = try XCTUnwrap(host.rows.first)
            XCTAssertTrue(row.allText.contains("Shop API"))
            XCTAssertTrue(row.allText.contains("Staging"), "The environment is named, not only colored")
            XCTAssertTrue(row.allText.contains("3"))
            XCTAssertTrue(host.nodes.contains { $0.help == "Requests in Shop API use the Staging environment" })
        }
    }

    func testShowsNoEnvironmentWhenOnlyDefaultApplies() throws {
        let fixture = try SidebarFixture()
        let host = WindowHost(List { FolderRowView(folder: fixture.empty) }, size: CGSize(width: 300, height: 120), container: fixture.container)
        defer { host.close() }
        let row = try XCTUnwrap(host.rows.first)
        XCTAssertTrue(row.allText.contains("Empty"))
        XCTAssertTrue(row.allText.contains("0"))
        XCTAssertFalse(row.allText.contains("Default"))
    }

    func testFollowsRenamesAndEnvironmentChanges() throws {
        let fixture = try SidebarFixture()
        let host = WindowHost(List { FolderRowView(folder: fixture.shop) }, size: CGSize(width: 300, height: 120), container: fixture.container)
        defer { host.close() }
        fixture.shop.name = "Store API"
        EnvironmentActions.select(index: 2, in: fixture.shop)
        ViewHosting.settle()
        let row = try XCTUnwrap(host.rows.first)
        XCTAssertTrue(row.allText.contains("Store API"))
        XCTAssertTrue(row.allText.contains("Production"))
        XCTAssertFalse(row.allText.contains("Staging"))
    }
}

// MARK: - FolderRequestsListView

@MainActor
final class FolderRequestsListViewTests: XCTestCase {
    // MARK: Logic

    func testRequestsAreInTheirOrder() throws {
        let fixture = try SidebarFixture()
        XCTAssertEqual(SidebarActions.requests(in: fixture.shop, matching: "").map(\.name), ["List Orders", "Create Order", "Delete Order"])
    }

    func testSearchMatchesNameOrURLInAnyCase() throws {
        let fixture = try SidebarFixture()
        XCTAssertEqual(SidebarActions.requests(in: fixture.shop, matching: "create").map(\.name), ["Create Order"])
        XCTAssertEqual(SidebarActions.requests(in: fixture.shop, matching: "ORDERS/1").map(\.name), ["Delete Order"])
        XCTAssertEqual(SidebarActions.requests(in: fixture.shop, matching: "{{baseUrl}}").count, 3)
        XCTAssertEqual(SidebarActions.requests(in: fixture.shop, matching: "nothing like it"), [])
        XCTAssertEqual(SidebarActions.requests(in: fixture.empty, matching: ""), [])
    }

    func testNewRequestsGoAtTheEnd() throws {
        let fixture = try SidebarFixture()
        let request = SidebarActions.createRequest(in: fixture.shop, context: fixture.context)
        XCTAssertEqual(request.name, "New Request")
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.folder?.id, fixture.shop.id)
        XCTAssertEqual(SidebarActions.requests(in: fixture.shop, matching: "").last?.id, request.id)
        try fixture.context.save()
        XCTAssertEqual(fixture.shop.requests?.count, 4)
    }

    func testDuplicateCopiesTheRequestIntoTheSameCollection() throws {
        let fixture = try SidebarFixture()
        let original = fixture.createOrder
        original.headers = [KeyValuePair(key: "Accept", value: "application/json")]
        original.queryParams = [KeyValuePair(key: "dryRun", value: "1", isEnabled: false)]
        original.bodyType = .json
        original.bodyContent = #"{"sku":"A1"}"#
        let copy = SidebarActions.duplicate(original, in: fixture.shop, context: fixture.context)
        XCTAssertEqual(copy.name, "Create Order Copy")
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.url, original.url)
        XCTAssertEqual(copy.method, .post)
        XCTAssertEqual(copy.headers, original.headers)
        XCTAssertEqual(copy.queryParams, original.queryParams)
        XCTAssertEqual(copy.bodyType, .json)
        XCTAssertEqual(copy.bodyContent, original.bodyContent)
        XCTAssertEqual(SidebarActions.requests(in: fixture.shop, matching: "").last?.id, copy.id)
        XCTAssertEqual(original.name, "Create Order", "The original is untouched")
    }

    func testDuplicateKeepsTheCredentials() throws {
        let fixture = try SidebarFixture()
        let bearer = fixture.listOrders
        bearer.authenticationType = .bearer
        bearer.authBearerToken = "{{token}}"
        let basic = fixture.createOrder
        basic.authenticationType = .basic
        basic.authBasicUsername = "admin"
        basic.authBasicPassword = "hunter22"
        let oauth = fixture.deleteOrder
        oauth.authenticationType = .oauth2
        oauth.authOAuthConfig = OAuthConfig(tokenURL: "https://auth.local/token", clientID: "app")
        let bearerCopy = SidebarActions.duplicate(bearer, in: fixture.shop, context: fixture.context)
        XCTAssertEqual(bearerCopy.authenticationType, .bearer)
        XCTAssertEqual(bearerCopy.authBearerToken, "{{token}}", "A copy that uses Bearer auth needs the token to send")
        let basicCopy = SidebarActions.duplicate(basic, in: fixture.shop, context: fixture.context)
        XCTAssertEqual(basicCopy.authBasicUsername, "admin")
        XCTAssertEqual(basicCopy.authBasicPassword, "hunter22")
        XCTAssertEqual(SidebarActions.duplicate(oauth, in: fixture.shop, context: fixture.context).authOAuthConfig, oauth.authOAuthConfig)
    }

    func testDeletingTheSelectedRequestClearsTheSelection() throws {
        let fixture = try SidebarFixture()
        XCTAssertNil(SidebarActions.delete(fixture.listOrders, selected: fixture.listOrders, context: fixture.context))
        try fixture.context.save()
        XCTAssertEqual(SidebarActions.requests(in: fixture.shop, matching: "").map(\.name), ["Create Order", "Delete Order"])
    }

    func testDeletingAnotherRequestKeepsTheSelection() throws {
        let fixture = try SidebarFixture()
        XCTAssertEqual(SidebarActions.delete(fixture.listOrders, selected: fixture.createOrder, context: fixture.context)?.id, fixture.createOrder.id)
        XCTAssertNil(SidebarActions.delete(fixture.deleteOrder, selected: nil, context: fixture.context))
    }

    // MARK: Rendering

    private func host(_ fixture: SidebarFixture, _ folder: Folder, selected: APIRequest? = nil, appearance: NSAppearance.Name = .aqua, width: CGFloat = 320)
        -> WindowHost
    {
        WindowHost(
            NavigationStack { FolderRequestsListView(folder: folder, selectedRequest: .constant(selected)) }, size: CGSize(width: width, height: 400),
            appearance: appearance, container: fixture.container)
    }

    func testRowsShowMethodAndNameInOrderWithTheSelectedOneSelected() throws {
        let fixture = try SidebarFixture()
        for (appearance, width) in [(NSAppearance.Name.aqua, CGFloat(320)), (.darkAqua, 600)] {
            let host = host(fixture, fixture.shop, selected: fixture.createOrder, appearance: appearance, width: width)
            defer { host.close() }
            XCTAssertEqual(host.rows.map(\.allText), [["GET", "List Orders"], ["POST", "Create Order"], ["DELETE", "Delete Order"]])
            XCTAssertEqual(host.rows.filter(\.isSelected).map(\.allText), [["POST", "Create Order"]], "Selection is exposed, not only highlighted")
            XCTAssertEqual(host.window.title, "Shop API")
        }
    }

    func testAnEmptyCollectionSaysHowToStart() throws {
        let fixture = try SidebarFixture()
        let host = host(fixture, fixture.empty)
        defer { host.close() }
        XCTAssertTrue(host.text.contains("No Requests"))
        XCTAssertTrue(host.text.contains("Create a new request to get started"))
        XCTAssertTrue(host.rows.isEmpty)
    }

    func testTheToolbarOffersANewRequest() throws {
        let fixture = try SidebarFixture()
        let host = host(fixture, fixture.empty, width: 700)
        defer { host.close() }
        let button = try XCTUnwrap(host.toolbarButtons.first { $0.label == "New Request" })
        host.press(button)
        XCTAssertEqual(fixture.empty.requests?.map(\.name), ["New Request"])
        XCTAssertEqual(host.rows.map(\.allText), [["GET", "New Request"]])
    }

    func testRowsFollowTheStore() throws {
        let fixture = try SidebarFixture()
        let host = host(fixture, fixture.shop)
        defer { host.close() }
        _ = SidebarActions.delete(fixture.listOrders, selected: nil, context: fixture.context)
        fixture.deleteOrder.name = "Cancel Order"
        try fixture.context.save()
        ViewHosting.settle()
        XCTAssertEqual(host.rows.map(\.allText), [["POST", "Create Order"], ["DELETE", "Cancel Order"]])
    }
}

// MARK: - HistoryListView

@MainActor
final class HistoryListViewTests: XCTestCase {
    // MARK: Logic

    func testSearchMatchesURLOrMethodInAnyCase() throws {
        let fixture = try SidebarFixture()
        let history = try fixture.history()
        XCTAssertEqual(SidebarActions.history(history, matching: "").count, 5)
        XCTAssertEqual(Set(SidebarActions.history(history, matching: "OFFLINE").map(\.id)), [fixture.offline.id])
        XCTAssertEqual(Set(SidebarActions.history(history, matching: "post").map(\.id)), [fixture.serverError.id, fixture.streamed.id])
        XCTAssertEqual(SidebarActions.history(history, matching: "nowhere"), [])
    }

    func testEntriesAreGroupedByDayNewestFirst() throws {
        let fixture = try SidebarFixture()
        let calendar = Calendar.current
        let older = RequestHistory(url: "https://old", method: .get)
        older.timestamp = calendar.date(byAdding: .day, value: -10, to: Date())!
        fixture.context.insert(older)
        let groups = SidebarActions.groupedByDay(try fixture.history() + [older], calendar: calendar)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        XCTAssertEqual(groups.map(\.0), ["Today", "Yesterday", formatter.string(from: older.timestamp)])
        XCTAssertEqual(groups.first?.1.map(\.id), [fixture.success.id, fixture.serverError.id, fixture.offline.id, fixture.streamed.id])
        XCTAssertEqual(groups[1].1.map(\.id), [fixture.yesterday.id])
        XCTAssertTrue(SidebarActions.groupedByDay([]).isEmpty)
    }

    func testDeletingTheSelectedEntryClearsTheSelection() throws {
        let fixture = try SidebarFixture()
        XCTAssertNil(SidebarActions.deleteHistory(fixture.success, selected: fixture.success, context: fixture.context))
        XCTAssertEqual(SidebarActions.deleteHistory(fixture.offline, selected: fixture.streamed, context: fixture.context)?.id, fixture.streamed.id)
        try fixture.context.save()
        XCTAssertEqual(try fixture.history().count, 3)
    }

    func testClearingHistoryLeavesCollectionsAlone() throws {
        let fixture = try SidebarFixture()
        SidebarActions.clearHistory(try fixture.history(), context: fixture.context)
        try fixture.context.save()
        XCTAssertEqual(try fixture.history(), [])
        XCTAssertEqual(try fixture.folders().map(\.name), ["Shop API", "Empty"])
        XCTAssertEqual(fixture.shop.requests?.count, 3)
    }

    // MARK: Rendering

    private func host(_ fixture: SidebarFixture, selected: RequestHistory? = nil, appearance: NSAppearance.Name = .aqua, width: CGFloat = 320) -> WindowHost {
        WindowHost(
            NavigationStack { HistoryListView(selectedHistory: .constant(selected), onRestore: { _ in }) }, size: CGSize(width: width, height: 500),
            appearance: appearance, container: fixture.container)
    }

    func testRowsShowMethodStatusTimeAndURLUnderDaySections() throws {
        let fixture = try SidebarFixture()
        for (appearance, width) in [(NSAppearance.Name.aqua, CGFloat(320)), (.darkAqua, 700)] {
            let host = host(fixture, appearance: appearance, width: width)
            defer { host.close() }
            let rows = host.rows.map(\.allText)
            XCTAssertEqual(rows.count, 7, "Two section headers and five entries: \(rows)")
            XCTAssertEqual(rows.first, ["Today"])
            XCTAssertEqual(rows[1].first, "GET")
            XCTAssertTrue(rows[1].contains("200"), "The status is written out, not only colored")
            XCTAssertTrue(rows[1].contains("https://shop.local/orders"))
            XCTAssertTrue(rows[1].contains { $0.contains(":") }, "The time")
            XCTAssertTrue(rows[2].contains("500"))
            XCTAssertEqual(rows[5], ["Yesterday"])
            XCTAssertTrue(rows[6].contains("404"))
        }
    }

    func testTheSelectedEntryIsExposedAsSelected() throws {
        let fixture = try SidebarFixture()
        let host = host(fixture, selected: fixture.serverError)
        defer { host.close() }
        XCTAssertEqual(host.rows.filter(\.isSelected).count, 1)
        XCTAssertTrue(host.rows.first(where: \.isSelected)?.allText.contains("500") ?? false)
    }

    func testAnEmptyHistorySaysSoAndCannotBeCleared() throws {
        let container = try SidebarFixture.emptyStore()
        let host = WindowHost(NavigationStack { HistoryListView(selectedHistory: .constant(nil), onRestore: { _ in }) }, container: container)
        defer { host.close() }
        XCTAssertTrue(host.text.contains("No History"))
        XCTAssertTrue(host.text.contains("Your request history will appear here"))
        XCTAssertEqual(host.toolbarButtons.first { $0.label == "Clear History" }?.isEnabled, false, "Clear History is disabled")
    }

    func testClearingFromTheToolbarEmptiesTheList() throws {
        let fixture = try SidebarFixture()
        let host = host(fixture, width: 700)
        defer { host.close() }
        let clear = try XCTUnwrap(host.toolbarButtons.first { $0.label == "Clear History" })
        host.press(clear)
        XCTAssertEqual(try fixture.history(), [])
        XCTAssertTrue(host.text.contains("No History"))
        XCTAssertEqual(try fixture.folders().count, 2)
    }

    func testTheClearButtonIsNamedNotReadAsItsIcon() throws {
        let fixture = try SidebarFixture()
        let host = host(fixture, width: 700)
        defer { host.close() }
        XCTAssertEqual(host.toolbarButtons.map(\.label).filter { $0 != "Search" }, ["Clear History"])
    }

    func testTheListFollowsNewEntries() throws {
        let fixture = try SidebarFixture()
        let host = host(fixture)
        defer { host.close() }
        let entry = RequestHistory(url: "https://new.local/ping", method: .put)
        fixture.context.insert(entry)
        try fixture.context.save()
        ViewHosting.settle()
        XCTAssertTrue(host.rows.map(\.allText)[1].contains("https://new.local/ping"), "The newest entry comes first")
    }
}

// MARK: - HistoryDetailView

@MainActor
final class HistoryDetailViewTests: XCTestCase {
    private func host(_ entry: RequestHistory, _ fixture: SidebarFixture, appearance: NSAppearance.Name = .aqua, onRestore: @escaping (RequestHistory) -> Void = { _ in })
        -> WindowHost
    {
        WindowHost(
            NavigationStack { HistoryDetailView(history: entry, onRestore: onRestore) }, size: CGSize(width: 900, height: 700), appearance: appearance,
            container: fixture.container)
    }

    func testTheHeaderShowsWhatWasSentAndWhen() throws {
        let fixture = try SidebarFixture()
        fixture.success.requestName = "List Orders"
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = host(fixture.success, fixture, appearance: appearance)
            defer { host.close() }
            XCTAssertTrue(host.text.contains("List Orders"))
            XCTAssertTrue(host.text.contains("GET"))
            XCTAssertTrue(host.text.contains("https://shop.local/orders"))
            XCTAssertTrue(host.text.contains(fixture.success.timestamp.formatted(date: .abbreviated, time: .standard)))
            XCTAssertTrue(host.text.contains("200 OK"), "The response's status, in words")
        }
    }

    func testAnUnnamedEntryIsTitledHistory() throws {
        let fixture = try SidebarFixture()
        let host = host(fixture.success, fixture)
        defer { host.close() }
        XCTAssertTrue(host.text.contains("History"))
    }

    func testOpenAsRequestHandsBackTheEntry() throws {
        let fixture = try SidebarFixture()
        var restored: [UUID] = []
        let host = host(fixture.serverError, fixture) { restored.append($0.id) }
        defer { host.close() }
        host.press(try XCTUnwrap(host.button("Open as Request")))
        XCTAssertEqual(restored, [fixture.serverError.id])
    }

    func testTheToolbarButtonIsNamedNotReadAsItsIcon() throws {
        let fixture = try SidebarFixture()
        var restored = 0
        let host = host(fixture.success, fixture) { _ in restored += 1 }
        defer { host.close() }
        let button = try XCTUnwrap(host.toolbarButtons.first, "\(host.toolbarButtons.map(\.label))")
        XCTAssertEqual(button.label, "Open as New Request")
        host.press(button)
        XCTAssertEqual(restored, 1)
    }

    func testTabsShowParamsHeadersBodyAndMaskedAuth() throws {
        let fixture = try SidebarFixture()
        let entry = fixture.serverError
        entry.queryParams = [KeyValuePair(key: "page", value: "2"), KeyValuePair(key: "off", value: "x", isEnabled: false)]
        entry.requestHeaders = [KeyValuePair(key: "Accept", value: "application/json")]
        entry.requestBody = #"{"sku":"A1"}"#
        entry.bodyType = .json
        entry.authenticationType = .basic
        entry.authBasicUsername = "admin"
        entry.authBasicPassword = "hunter22"
        let host = host(entry, fixture)
        defer { host.close() }
        XCTAssertTrue(host.text.contains("page"))
        XCTAssertTrue(host.text.contains("2"))
        XCTAssertFalse(host.text.contains("off"), "Disabled params weren't sent, so they aren't shown")

        host.press(try XCTUnwrap(host.buttons.first { $0.label.hasPrefix("Headers") && $0.help.isEmpty }))
        XCTAssertTrue(host.text.contains("Accept"))

        host.press(try XCTUnwrap(host.buttons.first { $0.label.hasPrefix("Auth") }))
        XCTAssertTrue(host.text.contains("admin"))
        XCTAssertTrue(host.text.contains("••••••••"), "The password is masked, one dot per character")
        XCTAssertFalse(host.text.contains { $0.contains("hunter22") })
    }

    func testEmptyTabsSaySo() throws {
        let fixture = try SidebarFixture()
        let host = host(fixture.success, fixture)
        defer { host.close() }
        XCTAssertTrue(host.text.contains("No query parameters"))
        host.press(try XCTUnwrap(host.buttons.first { $0.label.hasPrefix("Auth") }))
        XCTAssertTrue(host.text.contains("No authentication"))
    }

    func testAFailureWithoutAResponseShowsTheError() throws {
        let fixture = try SidebarFixture()
        let host = host(fixture.offline, fixture)
        defer { host.close() }
        XCTAssertTrue(host.text.contains { $0.contains(fixture.offline.errorMessage ?? "?") }, "\(host.text)")
    }

    func testAStreamedEntryShowsItsText() throws {
        let fixture = try SidebarFixture()
        let host = host(fixture.streamed, fixture)
        defer { host.close() }
        XCTAssertTrue(host.text.contains { $0.contains("Hello from the stream") }, "\(host.text)")
    }
}

// MARK: - ContentView

@MainActor
final class ContentViewTests: XCTestCase {
    // MARK: Current collection

    func testHistoryHasNoCurrentCollection() throws {
        let fixture = try SidebarFixture()
        let selection = ContentSelection(sidebar: .history, request: fixture.listOrders)
        XCTAssertNil(selection.currentFolder(in: try fixture.folders()), "Even with a request still selected")
    }

    func testTheEditedRequestsCollectionComesBeforeTheSelectedOne() throws {
        let fixture = try SidebarFixture()
        let folders = try fixture.folders()
        XCTAssertEqual(ContentSelection(sidebar: .folder(fixture.empty.id), request: fixture.listOrders).currentFolder(in: folders)?.id, fixture.shop.id)
        XCTAssertEqual(ContentSelection(sidebar: .folder(fixture.empty.id)).currentFolder(in: folders)?.id, fixture.empty.id)
        XCTAssertNil(ContentSelection(sidebar: .folder(UUID())).currentFolder(in: folders), "A collection that is gone")
        XCTAssertNil(ContentSelection(sidebar: nil).currentFolder(in: folders))
    }

    func testADeletedRequestNoLongerPicksTheCollection() throws {
        let fixture = try SidebarFixture()
        let selection = ContentSelection(sidebar: .folder(fixture.empty.id), request: fixture.listOrders)
        fixture.context.delete(fixture.listOrders)
        XCTAssertEqual(selection.currentFolder(in: try fixture.folders())?.id, fixture.empty.id)
    }

    func testNotificationsNameTheirCollectionOrUseTheCurrentOne() throws {
        let fixture = try SidebarFixture()
        let folders = try fixture.folders()
        let selection = ContentSelection(sidebar: .folder(fixture.shop.id))
        XCTAssertEqual(selection.folder(for: ["folderID": fixture.empty.id], in: folders)?.id, fixture.empty.id)
        XCTAssertEqual(selection.folder(for: nil, in: folders)?.id, fixture.shop.id)
        XCTAssertEqual(selection.folder(for: ["folderID": "not a UUID"], in: folders)?.id, fixture.shop.id)
        XCTAssertNil(selection.folder(for: ["folderID": UUID()], in: folders), "Never another collection than the one named")
    }

    // MARK: New Folder, New Request, Open as Request

    func testNewFolderAddsASelectedCollectionWithItsDefaultEnvironment() throws {
        let fixture = try SidebarFixture()
        var selection = ContentSelection()
        let folder = selection.createFolder(in: try fixture.folders(), context: fixture.context)
        XCTAssertEqual(folder.name, "New Collection")
        XCTAssertEqual(folder.sortOrder, 2, "After the others")
        XCTAssertNotNil(folder.defaultEnvironment)
        XCTAssertEqual(selection.sidebar, .folder(folder.id))
        try fixture.context.save()
        XCTAssertEqual(try fixture.folders().map(\.name), ["Shop API", "Empty", "New Collection"])
    }

    func testNewRequestGoesIntoTheSelectedCollection() throws {
        let fixture = try SidebarFixture()
        var selection = ContentSelection(sidebar: .folder(fixture.empty.id))
        let request = selection.createRequest(in: try fixture.folders(), context: fixture.context)
        XCTAssertEqual(request.folder?.id, fixture.empty.id)
        XCTAssertEqual(selection.request?.id, request.id)
        XCTAssertEqual(selection.sidebar, .folder(fixture.empty.id))
    }

    func testNewRequestFromHistoryGoesIntoTheFirstCollectionAndShowsIt() throws {
        let fixture = try SidebarFixture()
        var selection = ContentSelection(sidebar: .history)
        let request = selection.createRequest(in: try fixture.folders(), context: fixture.context)
        XCTAssertEqual(request.folder?.id, fixture.shop.id)
        XCTAssertGreaterThanOrEqual(request.sortOrder, 3, "After the collection's requests")
        XCTAssertEqual(selection.sidebar, .folder(fixture.shop.id))
    }

    func testNewRequestWithNoCollectionsMakesOne() throws {
        let container = try ViewHosting.container()
        var selection = ContentSelection()
        let request = selection.createRequest(in: [], context: container.mainContext)
        let folder = try XCTUnwrap(request.folder)
        XCTAssertEqual(folder.name, "Default Collection")
        XCTAssertNotNil(folder.defaultEnvironment)
        XCTAssertEqual(selection.sidebar, .folder(folder.id))
        try container.mainContext.save()
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Folder>()), 1)
    }

    func testOpenAsRequestCopiesTheEntryIntoTheFirstCollection() throws {
        let fixture = try SidebarFixture()
        fixture.serverError.requestName = "Create Order"
        fixture.serverError.requestBody = #"{"sku":"A1"}"#
        var selection = ContentSelection(sidebar: .history, history: fixture.serverError)
        let request = selection.restore(fixture.serverError, in: try fixture.folders(), context: fixture.context)
        XCTAssertEqual(request.name, "Create Order")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.bodyContent, #"{"sku":"A1"}"#)
        XCTAssertEqual(request.folder?.id, fixture.shop.id)
        XCTAssertGreaterThanOrEqual(request.sortOrder, 3)
        XCTAssertNil(selection.history)
        XCTAssertEqual(selection.request?.id, request.id)
        XCTAssertEqual(selection.sidebar, .folder(fixture.shop.id))
        XCTAssertFalse(fixture.serverError.isDeleted, "The entry stays in History")
    }

    func testOpenAsRequestWithNoCollectionsMakesOne() throws {
        let container = try ViewHosting.container()
        let entry = RequestHistory(url: "https://x/ping", method: .get)
        container.mainContext.insert(entry)
        var selection = ContentSelection()
        let request = selection.restore(entry, in: [], context: container.mainContext)
        XCTAssertEqual(request.folder?.name, "Default Collection")
        XCTAssertEqual(request.name, "https://x/ping", "Unnamed entries are named by URL")
    }

    // MARK: Environment shortcuts

    func testControlDigitsPickTheCurrentCollectionsEnvironment() throws {
        let fixture = try SidebarFixture()
        let folders = try fixture.folders()
        let selection = ContentSelection(sidebar: .folder(fixture.shop.id))
        selection.selectEnvironment(["index": 2], in: folders)
        XCTAssertEqual(fixture.shop.activeEnvironmentName, "Production")
        selection.selectEnvironment(["index": 1], in: folders)
        XCTAssertEqual(fixture.shop.activeEnvironmentName, "Staging")
        selection.selectEnvironment(["index": 0], in: folders)
        XCTAssertNil(fixture.shop.selectedEnvironmentID, "⌃0 is Default only")
    }

    func testAShortcutPastTheLastEnvironmentChangesNothing() throws {
        let fixture = try SidebarFixture()
        let selection = ContentSelection(sidebar: .folder(fixture.shop.id))
        selection.selectEnvironment(["index": 3], in: try fixture.folders())
        selection.selectEnvironment(["index": 9], in: try fixture.folders())
        selection.selectEnvironment(nil, in: try fixture.folders())
        XCTAssertEqual(fixture.shop.selectedEnvironmentID, fixture.staging.id)
    }

    func testShortcutsInHistoryChangeNoCollection() throws {
        let fixture = try SidebarFixture()
        ContentSelection(sidebar: .history).selectEnvironment(["index": 0], in: try fixture.folders())
        XCTAssertEqual(fixture.shop.selectedEnvironmentID, fixture.staging.id)
    }

    // MARK: Deletions by agents and History trimming

    func testDeletedModelsAreNoLongerShown() throws {
        let fixture = try SidebarFixture()
        var selection = ContentSelection(
            sidebar: .folder(fixture.shop.id), request: fixture.listOrders, history: fixture.success, managedFolder: fixture.shop,
            newEnvironmentFolder: fixture.empty)
        selection.dropSelections(of: [fixture.listOrders.id, fixture.success.id])
        XCTAssertNil(selection.request)
        XCTAssertNil(selection.history)
        XCTAssertEqual(selection.sidebar, .folder(fixture.shop.id))
        XCTAssertEqual(selection.managedFolder?.id, fixture.shop.id)
        selection.dropSelections(of: [fixture.shop.id, fixture.empty.id])
        XCTAssertEqual(selection.sidebar, .history, "A deleted collection falls back to History")
        XCTAssertNil(selection.managedFolder, "Its environment sheets close")
        XCTAssertNil(selection.newEnvironmentFolder)
    }

    func testDeletingOtherModelsKeepsTheSelection() throws {
        let fixture = try SidebarFixture()
        var selection = ContentSelection(sidebar: .folder(fixture.shop.id), request: fixture.listOrders, history: fixture.success)
        selection.dropSelections(of: [fixture.createOrder.id, fixture.offline.id, fixture.empty.id, UUID()])
        XCTAssertEqual(selection.request?.id, fixture.listOrders.id)
        XCTAssertEqual(selection.history?.id, fixture.success.id)
        XCTAssertEqual(selection.sidebar, .folder(fixture.shop.id))
    }

    // MARK: The window

    private static let size = CGSize(width: 1200, height: 760)

    private func host(_ fixture: SidebarFixture, appearance: NSAppearance.Name = .aqua) -> WindowHost {
        WindowHost(ContentView(), size: Self.size, appearance: appearance, container: fixture.container)
    }

    private func post(_ name: Notification.Name, _ userInfo: [AnyHashable: Any]? = nil) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
        ViewHosting.settle(0.1)
    }

    func testOpensOnHistoryWithTheCollectionsListed() throws {
        let fixture = try SidebarFixture()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = host(fixture, appearance: appearance)
            defer { host.close() }
            let sidebar = host.rows.map(\.allText)
            XCTAssertEqual(sidebar.prefix(3).map { $0.first }, ["General", "History", "Collections"], "\(sidebar)")
            XCTAssertTrue(sidebar[3].contains("Shop API") && sidebar[3].contains("Staging") && sidebar[3].contains("3"), "\(sidebar[3])")
            XCTAssertTrue(sidebar[4].contains("Empty"))
            XCTAssertTrue(host.rows.first { $0.allText == ["History"] }?.isSelected ?? false, "History is selected, and says so")
            XCTAssertTrue(host.text.contains("No Request Selected"))
            let menu = try XCTUnwrap(host.nodes.first { $0.label == "No Environment" })
            XCTAssertFalse(menu.isEnabled)
        }
    }

    func testToolbarButtonsAreNamedNotReadAsTheirIcons() throws {
        let fixture = try SidebarFixture()
        let host = host(fixture)
        defer { host.close() }
        let labels = host.toolbarButtons.map(\.label)
        XCTAssertTrue(labels.contains("Add Collection"), "\(labels)")
        XCTAssertTrue(labels.contains("Clear History"), "\(labels)")
        XCTAssertFalse(labels.contains("Add") || labels.contains("Bin") || labels.contains("Trash"), "\(labels)")
    }

    func testNewRequestFromTheMenuOpensItInTheEditor() throws {
        let fixture = try SidebarFixture()
        let host = host(fixture)
        defer { host.close() }
        post(.createNewRequest)
        XCTAssertEqual(fixture.shop.requests?.count, 4)
        XCTAssertFalse(host.text.contains("No Request Selected"))
        XCTAssertTrue(host.rows.contains { $0.isSelected && $0.allText == ["GET", "New Request"] }, "\(host.rows.map(\.allText))")
        XCTAssertTrue(host.nodes.contains { $0.role == "AXMenuButton" && $0.label == "Staging" }, "The toolbar names the collection's environment")
    }

    func testNewFolderFromTheMenuAddsAndSelectsIt() throws {
        let fixture = try SidebarFixture()
        let host = host(fixture)
        defer { host.close() }
        post(.createNewFolder)
        XCTAssertEqual(try fixture.folders().map(\.name), ["Shop API", "Empty", "New Collection"])
        XCTAssertTrue(host.rows.contains { $0.isSelected && $0.allText.contains("New Collection") }, "\(host.rows.map(\.allText))")
        XCTAssertTrue(host.text.contains("No Requests"))
    }

    func testControlDigitShortcutsReachTheCurrentCollection() throws {
        let fixture = try SidebarFixture()
        let host = host(fixture)
        defer { host.close() }
        EnvironmentShortcut.all[2].post()
        ViewHosting.settle()
        XCTAssertEqual(fixture.shop.selectedEnvironmentID, fixture.staging.id, "Nothing to change while History is shown")
        post(.createNewRequest)
        EnvironmentShortcut.all[2].post()
        ViewHosting.settle()
        XCTAssertEqual(fixture.shop.activeEnvironmentName, "Production")
        XCTAssertTrue(host.nodes.contains { $0.role == "AXMenuButton" && $0.label == "Production" })
        EnvironmentShortcut.all[0].post()
        ViewHosting.settle()
        XCTAssertNil(fixture.shop.selectedEnvironmentID)
    }

    func testAnAgentDeletingTheOpenRequestEmptiesTheEditor() throws {
        let fixture = try SidebarFixture()
        let host = host(fixture)
        defer { host.close() }
        post(.createNewRequest)
        let request = try XCTUnwrap(fixture.shop.requests?.first { $0.name == "New Request" })
        post(.remoteAgentWillDelete, ["ids": Set([request.id])])
        fixture.context.delete(request)
        try fixture.context.save()
        ViewHosting.settle()
        XCTAssertTrue(host.text.contains("No Request Selected"))
    }

    func testOpeningAHistoryEntryAndTrimmingHistoryClosesIt() throws {
        let fixture = try SidebarFixture()
        let host = host(fixture)
        defer { host.close() }
        host.selectRow(2, inListShowing: "Today")  // Today, the 200 entry, the 500 entry
        ViewHosting.settle()
        XCTAssertTrue(host.text.contains("Open as Request"), "The entry opened: \(host.text)")
        HistoryRetention.clear(fixture.context)
        ViewHosting.settle()
        XCTAssertTrue(host.text.contains("No History"))
        XCTAssertFalse(host.text.contains("Open as Request"))
        XCTAssertTrue(host.text.contains("No Request Selected"))
    }

    func testManageEnvironmentsOpensASheetThatClosesWhenItsCollectionIsDeleted() throws {
        let fixture = try SidebarFixture()
        let host = host(fixture)
        defer { host.close() }
        post(.manageEnvironments, ["folderID": fixture.shop.id])
        let sheet = try XCTUnwrap(host.window.attachedSheet, "The sheet opened")
        XCTAssertTrue(WindowHost.text(of: sheet).contains("Shop API · Environments"))
        post(.remoteAgentWillDelete, ["ids": Set([fixture.shop.id])])
        ViewHosting.settle(0.5)
        XCTAssertNil(host.window.attachedSheet)
    }

    func testNewEnvironmentOpensItsSheetForTheNamedCollection() throws {
        let fixture = try SidebarFixture()
        let host = host(fixture)
        defer { host.close() }
        post(.newEnvironment, ["folderID": fixture.empty.id])
        let sheet = try XCTUnwrap(host.window.attachedSheet)
        XCTAssertTrue(WindowHost.text(of: sheet).contains("Use it for Empty now"))
    }

    func testEnvironmentSheetsNeedACollection() throws {
        let fixture = try SidebarFixture()
        let host = host(fixture)
        defer { host.close() }
        post(.manageEnvironments)
        post(.newEnvironment)
        post(.manageEnvironments, ["folderID": UUID()])
        XCTAssertNil(host.window.attachedSheet, "History is shown, so there is no current collection")
    }
}

// MARK: - AppCommands

@MainActor
final class AppCommandsTests: XCTestCase {
    func testEnvironmentShortcutsAreControlZeroToNine() {
        XCTAssertEqual(EnvironmentShortcut.all.map(\.index), Array(0...9))
        XCTAssertEqual(EnvironmentShortcut.all.map { String($0.key.character) }, (0...9).map(String.init))
        XCTAssertEqual(Set(EnvironmentShortcut.all.map(\.id)).count, 10)
    }

    func testEnvironmentShortcutTitlesSayWhatTheyPick() {
        XCTAssertEqual(EnvironmentShortcut.all.first?.title, "Use Default Only")
        XCTAssertEqual(EnvironmentShortcut.all.dropFirst().map(\.title), (1...9).map { "Use Environment \($0)" })
    }

    func testEnvironmentShortcutsPostTheirIndex() {
        let center = NotificationCenter()
        let received = Received()
        let token = center.addObserver(forName: .selectEnvironment, object: nil, queue: nil) { notification in
            received.append(notification.userInfo?["index"] as? Int ?? -1)
        }
        defer { center.removeObserver(token) }
        for shortcut in EnvironmentShortcut.all { shortcut.post(to: center) }
        XCTAssertEqual(received.values, Array(0...9))
    }

    func testMenuNotificationsHaveDistinctNames() {
        let names: [Notification.Name] = [
            .createNewRequest, .createNewFolder, .sendRequest, .saveRequest, .duplicateRequest, .generateCode, .expandFolder, .manageEnvironments,
            .newEnvironment, .selectEnvironment
        ]
        XCTAssertEqual(Set(names.map(\.rawValue)).count, names.count)
    }
}

/// Indexes a notification observer saw (it is called synchronously, on the posting thread).
private final class Received: @unchecked Sendable {
    private(set) var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}
