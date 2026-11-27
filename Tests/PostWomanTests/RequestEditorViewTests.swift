import AppKit
import SwiftData
import SwiftUI
import XCTest

@testable import PostWoman

/// Hosting for the request editor's views: every appearance and size they are checked at, and what an accessibility client
/// can read or press beyond `ViewHosting`'s summary (every string of a node, pressing a button).
@MainActor
private enum EditorHosting {
    static let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    /// Hosts `view` at each appearance and size and runs `check` on it, naming the variant in failures.
    static func eachVariant<Content: View>(
        _ view: @autoclosure () -> Content, sizes: [CGSize], container: ModelContainer? = nil,
        _ check: (NSHostingView<AnyView>, String) throws -> Void
    ) rethrows {
        for appearance in appearances {
            for size in sizes {
                let hosting = ViewHosting.host(view(), size: size, appearance: appearance, container: container)
                defer { ViewHosting.close(hosting) }
                try check(hosting, "\(appearance.rawValue) \(Int(size.width))×\(Int(size.height))")
            }
        }
    }

    /// Every accessibility node under `root`, depth first.
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

    static func read(_ node: NSObject, _ getter: String) -> Any? {
        node.responds(to: NSSelectorFromString(getter)) ? node.perform(NSSelectorFromString(getter))?.takeUnretainedValue() : nil
    }

    /// Every string any node exposes (label, title, value, help, placeholder), to check secrets never appear.
    static func exposedStrings(in root: NSView) -> [String] {
        let getters = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityHelp", "accessibilityPlaceholderValue"]
        return nodes(in: root).flatMap { node in getters.compactMap { read(node, $0) as? String } }.filter { !$0.isEmpty }
    }

    /// Presses the first button labelled `label`, as VoiceOver's "press" does. Returns whether there was one.
    @discardableResult
    static func press(_ label: String, in root: NSView) -> Bool {
        for node in nodes(in: root) where (read(node, "accessibilityRole") as? String) == NSAccessibility.Role.button.rawValue {
            let texts = ["accessibilityLabel", "accessibilityTitle"].compactMap { read(node, $0) as? String }
            guard texts.contains(label) else { continue }
            _ = node.perform(NSSelectorFromString("accessibilityPerformPress"))
            ViewHosting.settle()
            return true
        }
        return false
    }

    /// Settles until `condition` holds or `timeout` passes.
    static func wait(timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { ViewHosting.settle() }
        return condition()
    }

    /// Fails for any button without a label, or an icon-only button (`iconOnly`) without help.
    static func assertButtonsAreLabelled(in root: NSView, iconOnly: Set<String> = [], _ variant: String, file: StaticString = #filePath, line: UInt = #line) {
        let buttons = ViewHosting.elements(in: root).filter { $0.role == .button }
        XCTAssertFalse(buttons.isEmpty, "no buttons (\(variant))", file: file, line: line)
        for button in buttons {
            XCTAssertFalse(button.label.trimmingCharacters(in: .whitespaces).isEmpty, "unlabelled button (\(variant))", file: file, line: line)
            if iconOnly.contains(button.label) { XCTAssertFalse(button.help.isEmpty, "\(button.label) has no help (\(variant))", file: file, line: line) }
        }
    }

    /// The last store made, kept so its models stay usable while a test that ignores the container runs.
    private static var retained: ModelContainer?

    /// A collection with Default variables `host` and the secret `token`, and a request in it that uses both.
    static func store() throws -> (ModelContainer, Folder, APIRequest) {
        let container = try ViewHosting.container()
        retained = container
        let folder = Folder(name: "Users API")
        container.mainContext.insert(folder)
        folder.ensureDefaultEnvironment().variables = [
            Variable(key: "host", value: "api.example.com"), Variable(key: "token", value: "s3cret-token", isSecret: true)
        ]
        let request = APIRequest(name: "List Users", url: "https://{{host}}/users?key={{token}}", method: .post, folder: folder)
        container.mainContext.insert(request)
        request.queryParams = [KeyValuePair(key: "page", value: "1"), KeyValuePair(key: "off", value: "x", isEnabled: false), KeyValuePair(key: "", value: "y")]
        request.headers = [KeyValuePair(key: "Accept", value: "application/json"), KeyValuePair(key: "X-Trace", value: "1")]
        request.bodyType = .json
        request.bodyContent = #"{"name":"Ada"}"#
        request.authenticationType = .bearer
        request.authBearerToken = "bearer-secret-123"
        return (container, folder, request)
    }

    static let secrets = ["s3cret-token", "bearer-secret-123", "basic-password-456", "client-secret-789"]

    static func assertNoSecrets(in root: NSView, _ variant: String, file: StaticString = #filePath, line: UInt = #line) {
        let exposed = exposedStrings(in: root)
        for secret in secrets {
            XCTAssertFalse(exposed.contains { $0.contains(secret) }, "\(secret) exposed (\(variant))", file: file, line: line)
        }
    }
}

/// Holds a binding's value for a test, so a view's writes can be read back.
@MainActor
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
    var binding: Binding<Value> { Binding(get: { self.value }, set: { self.value = $0 }) }
}

// MARK: - URL bar

@MainActor
final class URLBarViewTests: XCTestCase {
    private let sizes = [CGSize(width: 420, height: 90), CGSize(width: 1000, height: 90)]

    func testTheButtonIsSendUntilARequestRunsThenStopWhenItCanBeStopped() {
        XCTAssertEqual(URLBarAction.current(url: "https://x", isLoading: false, canStop: true), .send(isEnabled: true))
        XCTAssertEqual(URLBarAction.current(url: "https://x", isLoading: true, canStop: true), .stop)
        XCTAssertEqual(URLBarAction.current(url: "https://x", isLoading: true, canStop: false), .sending)
        XCTAssertTrue(URLBarAction.stop.isEnabled)
        XCTAssertFalse(URLBarAction.sending.isEnabled)
    }

    func testSendIsDisabledWithoutAURL() {
        XCTAssertEqual(URLBarAction.current(url: "", isLoading: false, canStop: true), .send(isEnabled: false))
        XCTAssertFalse(URLBarAction.current(url: "", isLoading: false, canStop: false).isEnabled)
    }

    func testTheResolvedURLShowsOnlyForURLsWithVariablesAndAnEnvironment() {
        let resolver = VariableResolver(defaults: [Variable(key: "host", value: "h")], selected: nil)
        XCTAssertTrue(URLBarView.showsResolvedURL("https://{{host}}/a", resolver: resolver))
        XCTAssertTrue(URLBarView.showsResolvedURL("https://{{undefined}}/a", resolver: resolver), "Undefined variables show too, in red")
        XCTAssertFalse(URLBarView.showsResolvedURL("https://plain/a", resolver: resolver))
        XCTAssertFalse(URLBarView.showsResolvedURL("", resolver: resolver))
        XCTAssertFalse(URLBarView.showsResolvedURL("https://{{host}}/a", resolver: nil))
    }

    func testShowsTheMethodURLAndSendWithTheResolvedURLMaskingSecrets() throws {
        let (_, folder, request) = try EditorHosting.store()
        try EditorHosting.eachVariant(
            URLBarView(url: .constant(request.url), method: .constant(.post), isLoading: false, resolver: folder.variableResolver, onSend: {}), sizes: sizes
        ) { hosting, variant in
            let elements = ViewHosting.elements(in: hosting)
            XCTAssertTrue(elements.contains { $0.role == .popUpButton && $0.label == "Method" }, variant)
            XCTAssertTrue(elements.contains { $0.role == .textField && $0.label == "https://{{host}}/users?key={{token}}" }, variant)
            XCTAssertEqual(ViewHosting.buttonLabels(in: hosting), ["Send"], variant)
            let resolved = try XCTUnwrap(elements.first { $0.label == "Resolved URL" }, variant)
            XCTAssertTrue(resolved.help.contains("host = api.example.com  (Default)"), variant)
            XCTAssertTrue(resolved.help.contains("token = ••••••  (Default)"), variant)
            EditorHosting.assertNoSecrets(in: hosting, variant)
        }
    }

    func testAPlainURLHasNoResolvedLine() {
        let resolver = VariableResolver(defaults: [], selected: nil)
        let hosting = ViewHosting.host(
            URLBarView(url: .constant("https://example.com"), method: .constant(.get), isLoading: false, resolver: resolver, onSend: {}), size: sizes[1])
        defer { ViewHosting.close(hosting) }
        XCTAssertFalse(ViewHosting.text(in: hosting).contains("Resolved URL"))
    }

    func testPressingSendCallsOnSend() {
        var sent = 0
        let hosting = ViewHosting.host(URLBarView(url: .constant("https://example.com"), method: .constant(.get), isLoading: false, onSend: { sent += 1 }), size: sizes[1])
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(EditorHosting.press("Send", in: hosting))
        XCTAssertEqual(sent, 1)
    }

    func testWhileLoadingTheBarOffersStopWithItsShortcutInHelp() {
        EditorHosting.eachVariant(
            URLBarView(url: .constant("https://example.com"), method: .constant(.get), isLoading: true, onSend: {}, onStop: {}), sizes: sizes
        ) { hosting, variant in
            let stop = ViewHosting.elements(in: hosting).first { $0.label == "Stop" }
            XCTAssertEqual(stop?.help, "Stop the request (⌘.)", variant)
            XCTAssertFalse(ViewHosting.buttonLabels(in: hosting).contains("Send"), variant)
        }
    }
}

// MARK: - Tabs

@MainActor
final class RequestTabViewTests: XCTestCase {
    private let sizes = [CGSize(width: 360, height: 44), CGSize(width: 1000, height: 44)]

    func testBadgesCountActiveParamsAndHeadersAndMarkABodyAndAuth() throws {
        let (_, _, request) = try EditorHosting.store()
        XCTAssertEqual(RequestTab.params.badge(for: request), 1, "Disabled and unnamed params don't count")
        XCTAssertEqual(RequestTab.headers.badge(for: request), 2)
        XCTAssertEqual(RequestTab.body.badge(for: request), 1)
        XCTAssertEqual(RequestTab.auth.badge(for: request), 1)
    }

    func testTabsWithNothingInThemHaveNoBadge() {
        let request = APIRequest(name: "Empty")
        request.queryParams = [KeyValuePair(key: "a", value: "1", isEnabled: false), KeyValuePair(key: "", value: "2")]
        for tab in RequestTab.allCases { XCTAssertNil(tab.badge(for: request), tab.rawValue) }
    }

    func testActiveCountSkipsDisabledAndUnnamedPairs() {
        XCTAssertEqual([KeyValuePair]().activeCount, 0)
        XCTAssertEqual([KeyValuePair(key: "a"), KeyValuePair(key: "b", isEnabled: false), KeyValuePair(key: "")].activeCount, 1)
    }

    func testEachTabIsALabelledButtonWithItsCount() throws {
        let (container, _, request) = try EditorHosting.store()
        request.headers = []
        EditorHosting.eachVariant(RequestTabView(selectedTab: .constant(.params), request: request), sizes: sizes, container: container) { hosting, variant in
            XCTAssertEqual(ViewHosting.buttonLabels(in: hosting), ["Params, 1", "Headers", "Body, 1", "Auth, 1"], variant)
        }
    }

    func testTheSelectedTabIsExposedAsSelectedNotOnlyByColor() throws {
        let (container, _, request) = try EditorHosting.store()
        try EditorHosting.eachVariant(RequestTabView(selectedTab: .constant(.headers), request: request), sizes: sizes, container: container) { hosting, variant in
            let tabs = ViewHosting.elements(in: hosting).filter { $0.role == .button }
            XCTAssertEqual(tabs.filter { $0.isSelected == true }.map(\.label), ["Headers, 2"], variant)
        }
    }

    func testPressingATabSelectsIt() throws {
        let (container, _, request) = try EditorHosting.store()
        let selection = Box(RequestTab.params)
        let hosting = ViewHosting.host(RequestTabView(selectedTab: selection.binding, request: request), size: sizes[1], container: container)
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(EditorHosting.press("Auth, 1", in: hosting))
        XCTAssertEqual(selection.value, .auth)
    }
}

// MARK: - Params and headers

@MainActor
final class ParamsTabViewTests: XCTestCase {
    private let sizes = [CGSize(width: 380, height: 300), CGSize(width: 1000, height: 400)]

    func testShowsTheActiveCountAndEveryParamWithLabelledButtons() throws {
        let (_, folder, request) = try EditorHosting.store()
        EditorHosting.eachVariant(ParamsTabView(params: .constant(request.queryParams), resolver: folder.variableResolver), sizes: sizes) { hosting, variant in
            let text = ViewHosting.text(in: hosting)
            XCTAssertTrue(text.contains("Query Parameters"), variant)
            XCTAssertTrue(text.contains("1 active"), variant)
            XCTAssertTrue(text.contains("page") && text.contains("off"), variant)
            XCTAssertTrue(ViewHosting.buttonLabels(in: hosting).contains("Add"), variant)
            EditorHosting.assertButtonsAreLabelled(in: hosting, variant)
        }
    }

    func testNoParamsShowsZeroActiveAndAnAddButton() {
        let hosting = ViewHosting.host(ParamsTabView(params: .constant([])), size: sizes[0])
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("0 active"))
        XCTAssertEqual(ViewHosting.buttonLabels(in: hosting), ["Add"])
    }

    func testAddAppendsAnEmptyParam() {
        let params = Box([KeyValuePair(key: "page", value: "1")])
        let hosting = ViewHosting.host(ParamsTabView(params: params.binding), size: sizes[1])
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(EditorHosting.press("Add", in: hosting))
        XCTAssertEqual(params.value.map(\.key), ["page", ""])
    }
}

@MainActor
final class HeadersTabViewTests: XCTestCase {
    private let sizes = [CGSize(width: 380, height: 300), CGSize(width: 1000, height: 400)]

    func testShowsTheHeadersAndTheCommonHeadersMenu() throws {
        let (_, folder, request) = try EditorHosting.store()
        EditorHosting.eachVariant(HeadersTabView(headers: .constant(request.headers), resolver: folder.variableResolver), sizes: sizes) { hosting, variant in
            let elements = ViewHosting.elements(in: hosting)
            XCTAssertTrue(elements.contains { $0.label == "Request Headers" }, variant)
            XCTAssertTrue(elements.contains { $0.role == .menuButton && $0.label == "Common Headers" }, variant)
            XCTAssertTrue(elements.contains { $0.role == .textField && $0.label == "Accept" }, variant)
            XCTAssertTrue(elements.contains { $0.role == .textField && $0.label == "application/json" }, variant)
            EditorHosting.assertButtonsAreLabelled(in: hosting, variant)
        }
    }
}

// MARK: - Body

/// The body tab bound to a request, as the editor shows it, so tests can change the body type.
private struct BodyTabHost: View {
    @Bindable var request: APIRequest
    var body: some View { BodyTabView(bodyType: $request.bodyType, bodyContent: $request.bodyContent) }
}

@MainActor
final class BodyTabViewTests: XCTestCase {
    private let sizes = [CGSize(width: 400, height: 300), CGSize(width: 1000, height: 500)]

    func testEachBodyTypeGetsItsEditor() {
        XCTAssertEqual(BodyEditing.Editor(.none), .none)
        XCTAssertEqual(BodyEditing.Editor(.formData), .form)
        XCTAssertEqual(BodyEditing.Editor(.urlEncoded), .form)
        for type in [ContentType.json, .xml, .text] { XCTAssertEqual(BodyEditing.Editor(type), .code, type.rawValue) }
    }

    func testOnlyJSONAndXMLCanBePrettifiedAndOnlyWithText() {
        XCTAssertEqual(ContentType.allCases.filter(BodyEditing.canPrettify), [.json, .xml])
        XCTAssertFalse(BodyEditing.hasContent(""))
        XCTAssertFalse(BodyEditing.hasContent(" \n\t "))
        XCTAssertTrue(BodyEditing.hasContent(" {} "))
    }

    func testPrettifyIndentsJSONAndXML() throws {
        let json = try XCTUnwrap(BodyEditing.prettified(#"{"a":{"b":1}}"#, as: .json))
        XCTAssertTrue(json.contains("\n"), json)
        XCTAssertEqual(BodyEditing.prettified(json, as: .json), json, "Prettifying twice changes nothing")
        let xml = try XCTUnwrap(BodyEditing.prettified("<a><b>1</b></a>", as: .xml))
        XCTAssertTrue(xml.contains("\n    <b>1</b>"), xml)
    }

    func testPrettifyGivesNothingForTextThatDoesNotParse() {
        XCTAssertNil(BodyEditing.prettified(#"{"a":"#, as: .json))
        XCTAssertNil(BodyEditing.prettified("<a><b></a>", as: .xml))
        XCTAssertNil(BodyEditing.prettified("", as: .json))
        XCTAssertNil(BodyEditing.prettified("{}", as: .text), "Plain text has no prettify")
        XCTAssertNil(BodyEditing.prettified("a=1", as: .urlEncoded))
    }

    func testFormBodiesBecomeDecodedFields() {
        let pairs = FormBody.pairs(from: "name=Ada%20Lovelace&empty=&flag&x=1=2")
        XCTAssertEqual(pairs.map(\.key), ["name", "empty", "flag", "x"])
        XCTAssertEqual(pairs.map(\.value), ["Ada Lovelace", "", "", "1=2"])
        XCTAssertEqual(FormBody.pairs(from: ""), [])
        XCTAssertEqual(FormBody.pairs(from: "&&").count, 0)
        XCTAssertEqual(FormBody.pairs(from: "bad=%zz").first?.value, "%zz", "Text that isn't percent-encoding stays as written")
    }

    func testFormFieldsBecomeABodyOfTheEnabledNamedOnes() {
        let pairs = [KeyValuePair(key: "name", value: "Ada Lovelace"), KeyValuePair(key: "off", value: "1", isEnabled: false), KeyValuePair(key: "", value: "x")]
        XCTAssertEqual(FormBody.body(from: pairs), "name=Ada%20Lovelace")
        XCTAssertEqual(FormBody.body(from: []), "")
    }

    func testAJSONBodyShowsItsTextAndAPrettifyButton() throws {
        let (container, _, request) = try EditorHosting.store()
        EditorHosting.eachVariant(BodyTabHost(request: request), sizes: sizes, container: container) { hosting, variant in
            let elements = ViewHosting.elements(in: hosting)
            XCTAssertTrue(elements.contains { $0.role == .popUpButton && $0.label == "Body Type" }, variant)
            XCTAssertTrue(elements.contains { $0.role == .textArea && $0.label == #"{"name":"Ada"}"# }, variant)
            XCTAssertTrue(elements.contains { $0.role == .button && $0.help == "Prettify JSON" }, variant)
        }
    }

    func testThePrettifyButtonIsNamedForWhatItDoes() throws {
        let (container, _, request) = try EditorHosting.store()
        let hosting = ViewHosting.host(BodyTabHost(request: request), size: sizes[1], container: container)
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(ViewHosting.buttonLabels(in: hosting).contains("Prettify JSON"), "\(ViewHosting.buttonLabels(in: hosting))")
        request.bodyType = .xml
        ViewHosting.settle()
        XCTAssertTrue(ViewHosting.buttonLabels(in: hosting).contains("Prettify XML"), "\(ViewHosting.buttonLabels(in: hosting))")
    }

    func testChangingTheBodyTypeSwapsTheEditor() throws {
        let (container, _, request) = try EditorHosting.store()
        let hosting = ViewHosting.host(BodyTabHost(request: request), size: sizes[1], container: container)
        defer { ViewHosting.close(hosting) }

        request.bodyType = .none
        ViewHosting.settle()
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("This request does not have a body"))
        XCTAssertFalse(ViewHosting.elements(in: hosting).contains { $0.help.hasPrefix("Prettify") })

        request.bodyType = .urlEncoded
        request.bodyContent = "a=1&b=two"
        ViewHosting.settle()
        let fields = ViewHosting.elements(in: hosting).filter { $0.role == .textField }.map(\.label)
        XCTAssertEqual(fields, ["a", "1", "b", "two"])

        request.bodyType = .text
        ViewHosting.settle()
        XCTAssertTrue(ViewHosting.elements(in: hosting).contains { $0.role == .textArea && $0.label == "a=1&b=two" }, "The text stays when the type changes")
        XCTAssertFalse(ViewHosting.elements(in: hosting).contains { $0.help.hasPrefix("Prettify") }, "Plain text has no Prettify")
    }

    func testPrettifyIndentsTheBodyInPlace() throws {
        let (container, _, request) = try EditorHosting.store()
        let hosting = ViewHosting.host(BodyTabHost(request: request), size: sizes[1], container: container)
        defer { ViewHosting.close(hosting) }
        let prettify = try XCTUnwrap(EditorHosting.nodes(in: hosting).first { EditorHosting.read($0, "accessibilityHelp") as? String == "Prettify JSON" })
        _ = prettify.perform(NSSelectorFromString("accessibilityPerformPress"))
        ViewHosting.settle()
        XCTAssertEqual(request.bodyContent, JSONFormatter.prettify(#"{"name":"Ada"}"#))
    }

    func testPrettifyLeavesABodyThatDoesNotParseAsItIs() throws {
        let (container, _, request) = try EditorHosting.store()
        request.bodyContent = #"{"name":"#
        let hosting = ViewHosting.host(BodyTabHost(request: request), size: sizes[1], container: container)
        defer { ViewHosting.close(hosting) }
        let prettify = try XCTUnwrap(EditorHosting.nodes(in: hosting).first { EditorHosting.read($0, "accessibilityHelp") as? String == "Prettify JSON" })
        _ = prettify.perform(NSSelectorFromString("accessibilityPerformPress"))
        ViewHosting.settle()
        XCTAssertEqual(request.bodyContent, #"{"name":"#)
    }
}

// MARK: - Auth

@MainActor
final class AuthTabViewTests: XCTestCase {
    private let sizes = [CGSize(width: 380, height: 520), CGSize(width: 1000, height: 600)]

    func testSettingAnOAuthFieldKeepsTheOthers() {
        let made = AuthTabView.oauthConfig(nil, setting: \.clientID, to: "app")
        XCTAssertEqual(made, OAuthConfig(clientID: "app"))
        let existing = OAuthConfig(authorizationURL: "https://a", tokenURL: "https://t", clientID: "app", clientSecret: "s", scope: "read", redirectURI: "r")
        var expected = existing
        expected.scope = "read write"
        XCTAssertEqual(AuthTabView.oauthConfig(existing, setting: \.scope, to: "read write"), expected)
        XCTAssertEqual(AuthTabView.oauthConfig(existing, setting: \.scope, to: ""), OAuthConfig(authorizationURL: "https://a", tokenURL: "https://t", clientID: "app", clientSecret: "s", redirectURI: "r"))
    }

    func testEachAuthTypeShowsItsFieldsAndNeverItsSecrets() throws {
        let (container, _, request) = try EditorHosting.store()
        request.authBasicUsername = "ada"
        request.authBasicPassword = "basic-password-456"
        request.authOAuthConfig = OAuthConfig(
            authorizationURL: "https://auth.example.com", tokenURL: "https://auth.example.com/token", clientID: "app-id", clientSecret: "client-secret-789",
            scope: "read", redirectURI: "app://callback")
        let expected: [AuthenticationType: [String]] = [
            .none: ["No Authentication", "This request does not require authentication."],
            .bearer: ["Bearer Token", "The token will be sent as: Authorization: Bearer <token>"],
            .basic: ["Basic Authentication", "Username", "Password", "ada"],
            .oauth2: ["OAuth 2.0 Configuration", "Authorization URL", "Token URL", "Client ID", "Client Secret", "Scope", "Redirect URI", "app-id", "app://callback"]
        ]
        EditorHosting.eachVariant(AuthTabView(request: request), sizes: sizes, container: container) { hosting, variant in
            for type in AuthenticationType.allCases {
                request.authenticationType = type
                ViewHosting.settle()
                let text = ViewHosting.text(in: hosting)
                XCTAssertTrue(text.contains("Authentication"), variant)
                for shown in expected[type] ?? [] { XCTAssertTrue(text.contains(shown), "\(type.rawValue): \(shown) missing (\(variant))") }
                let others = AuthenticationType.allCases.filter { $0 != type }.compactMap { expected[$0]?.first }
                for hidden in others { XCTAssertFalse(text.contains(hidden), "\(type.rawValue): \(hidden) shown (\(variant))") }
                EditorHosting.assertNoSecrets(in: hosting, "\(type.rawValue), \(variant)")
            }
        }
    }

    func testTheBearerCopyButtonHasALabelAndHelp() throws {
        let (container, _, request) = try EditorHosting.store()
        EditorHosting.eachVariant(AuthTabView(request: request), sizes: sizes, container: container) { hosting, variant in
            let copy = ViewHosting.elements(in: hosting).first { $0.role == .button && $0.help == "Copy to clipboard" }
            XCTAssertFalse(copy?.label.isEmpty ?? true, variant)
        }
    }

    func testTheTypePickerIsLabelled() throws {
        let (container, _, request) = try EditorHosting.store()
        let hosting = ViewHosting.host(AuthTabView(request: request), size: sizes[1], container: container)
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(ViewHosting.elements(in: hosting).contains { $0.role == .popUpButton && $0.label == "Type" })
    }
}

// MARK: - Request editor

@MainActor
final class RequestEditorViewTests: XCTestCase {
    private let sizes = [CGSize(width: 620, height: 720), CGSize(width: 1200, height: 900)]

    func testSendNeedsAURLAndNoRequestInFlight() {
        XCTAssertTrue(RequestEditorView.canSend(url: "https://x", isSending: false))
        XCTAssertFalse(RequestEditorView.canSend(url: "", isSending: false))
        XCTAssertFalse(RequestEditorView.canSend(url: "https://x", isSending: true))
    }

    func testTheMissingVariablesNoticeNamesThemAndWhyTheyWereSentAsWritten() {
        XCTAssertEqual(
            MissingVariablesNotice.text(missing: ["host"], defaultEnvironmentName: "Default", sentEnvironmentName: "Staging"),
            "1 variable was sent as written, because neither Staging nor Default defines it: {{host}}")
        XCTAssertEqual(
            MissingVariablesNotice.text(missing: ["a", "b"], defaultEnvironmentName: "Base", sentEnvironmentName: nil),
            "2 variables were sent as written, because neither the environment nor Base defines it: {{a}}, {{b}}")
        XCTAssertEqual(
            MissingVariablesNotice.text(missing: ["a"], defaultEnvironmentName: nil, sentEnvironmentName: nil),
            "1 variable was sent as written, because this request has no collection: {{a}}")
    }

    func testTheNoticeShowsOnlyAfterASendWithMissingVariables() {
        XCTAssertTrue(MissingVariablesNotice.isShown(missing: ["a"], isLoading: false))
        XCTAssertFalse(MissingVariablesNotice.isShown(missing: ["a"], isLoading: true))
        XCTAssertFalse(MissingVariablesNotice.isShown(missing: [], isLoading: false))
    }

    func testDuplicateCopiesEverythingButTheIdentityIntoTheSameCollection() throws {
        let (_, folder, request) = try EditorHosting.store()
        request.authBasicUsername = "ada"
        request.authBasicPassword = "pw"
        request.authOAuthConfig = OAuthConfig(clientID: "app")
        let copy = RequestEditorView.duplicate(of: request)
        XCTAssertEqual(copy.name, "List Users (Copy)")
        XCTAssertNotEqual(copy.id, request.id)
        XCTAssertTrue(copy.folder === folder)
        XCTAssertEqual(copy.url, request.url)
        XCTAssertEqual(copy.method, .post)
        XCTAssertEqual(copy.headers, request.headers)
        XCTAssertEqual(copy.queryParams, request.queryParams)
        XCTAssertEqual(copy.bodyType, .json)
        XCTAssertEqual(copy.bodyContent, request.bodyContent)
        XCTAssertEqual(copy.authenticationType, .bearer)
        XCTAssertEqual(copy.authBearerToken, request.authBearerToken)
        XCTAssertEqual(copy.authBasicUsername, "ada")
        XCTAssertEqual(copy.authBasicPassword, "pw")
        XCTAssertEqual(copy.authOAuthConfig, request.authOAuthConfig)
    }

    func testShowsTheRequestItsCollectionAndTheParamsTabFirst() throws {
        let (container, _, request) = try EditorHosting.store()
        EditorHosting.eachVariant(RequestEditorView(request: request), sizes: sizes, container: container) { hosting, variant in
            let text = ViewHosting.text(in: hosting)
            for shown in ["List Users", "Users API", "https://{{host}}/users?key={{token}}", "Resolved URL", "Query Parameters", "1 active"] {
                XCTAssertTrue(text.contains(shown), "\(shown) missing (\(variant))")
            }
            let buttons = ViewHosting.buttonLabels(in: hosting)
            for tab in ["Params, 1", "Headers, 2", "Body, 1", "Auth, 1"] { XCTAssertTrue(buttons.contains(tab), "\(tab) missing (\(variant))") }
            XCTAssertTrue(buttons.contains("Send"), variant)
            XCTAssertTrue(text.contains("Send a request to see the response here"), variant)
            EditorHosting.assertNoSecrets(in: hosting, variant)
        }
    }

    func testPressingATabShowsItsContentWithoutExposingSecrets() throws {
        let (container, _, request) = try EditorHosting.store()
        let hosting = ViewHosting.host(RequestEditorView(request: request), size: sizes[1], container: container)
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(EditorHosting.press("Headers, 2", in: hosting))
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("Request Headers"))
        XCTAssertTrue(EditorHosting.press("Body, 1", in: hosting))
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("Request Body"))
        XCTAssertTrue(EditorHosting.press("Auth, 1", in: hosting))
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("Bearer Token"))
        EditorHosting.assertNoSecrets(in: hosting, "auth tab")
    }

    func testAFailedSendWithAnUndefinedVariableShowsTheNoticeAndRecordsHistory() throws {
        let (container, _, request) = try EditorHosting.store()
        // Nothing listens on port 1, so the send fails at once without leaving the machine.
        request.url = "http://127.0.0.1:1/{{undefined}}"
        let hosting = ViewHosting.host(RequestEditorView(request: request), size: sizes[1], container: container)
        defer { ViewHosting.close(hosting) }
        XCTAssertTrue(EditorHosting.press("Send", in: hosting))
        let notice = "1 variable was sent as written, because neither Default nor Default defines it: {{undefined}}"
        XCTAssertTrue(EditorHosting.wait { ViewHosting.text(in: hosting).contains(notice) }, "\(ViewHosting.text(in: hosting))")
        let elements = ViewHosting.elements(in: hosting)
        XCTAssertTrue(elements.contains { $0.role == .link && $0.label == "Manage Environments…" }, "\(elements)")
        let dismiss = elements.first { $0.role == .button && $0.help == "Dismiss" }
        XCTAssertFalse(dismiss?.label.isEmpty ?? true, "The notice's icon-only dismiss button is labelled")
        let history = try container.mainContext.fetch(FetchDescriptor<RequestHistory>())
        XCTAssertEqual(history.count, 1)
        EditorHosting.assertNoSecrets(in: hosting, "after send")
    }
}
