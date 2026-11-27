import SwiftData
import XCTest

@testable import PostWoman

@MainActor
final class HistoryRecordingTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() async throws {
        container = nil
    }

    /// A collection whose Default has a host and a secret token and password, with Staging selected.
    private func makeCollection() -> (Folder, APIRequest) {
        let folder = Folder(name: "API")
        context.insert(folder)
        folder.ensureDefaultEnvironment().variables = [
            Variable(key: "host", value: "https://local.example.com"), Variable(key: "token", value: "tok-SECRET", isSecret: true),
            Variable(key: "pw", value: "pw-SECRET", isSecret: true), Variable(key: "user", value: "ada")
        ]
        folder.selectedEnvironment = folder.addEnvironment(
            named: "Staging", color: .orange, variables: [Variable(key: "host", value: "https://staging.example.com"), Variable(key: "key", value: "key-SECRET", isSecret: true)])
        let request = APIRequest(name: "Create", url: "{{host}}/users?k={{key}}", method: .post, folder: folder)
        request.headers = [KeyValuePair(key: "X-Key", value: "{{key}}"), KeyValuePair(key: "X-User", value: "{{user}}")]
        request.queryParams = [KeyValuePair(key: "token", value: "{{token}}")]
        request.bodyType = .json
        request.bodyContent = #"{"user":"{{user}}","token":"{{token}}"}"#
        request.authenticationType = .basic
        request.authBasicUsername = "{{user}}"
        request.authBasicPassword = "{{pw}}"
        request.authBearerToken = "{{token}}"
        context.insert(request)
        return (folder, request)
    }

    /// History made the way the editor and `request_execute` make it.
    private func record(_ request: APIRequest, in folder: Folder) -> RequestHistory {
        RequestHistory(
            request: request, sent: RequestSnapshot(request).resolved(with: folder.variableResolver, redactSecrets: true),
            environmentName: folder.activeEnvironmentName)
    }

    private func allText(_ history: RequestHistory) -> String {
        let pairs = history.requestHeaders + (history.queryParams ?? [])
        return
            ([history.url, history.requestBody ?? "", history.authBearerToken ?? "", history.authBasicUsername ?? "", history.authBasicPassword ?? ""]
            + pairs.flatMap { [$0.key, $0.value] }).joined(separator: "\n")
    }

    func testHistoryNeverHoldsASecretValue() throws {
        let (folder, request) = makeCollection()
        let history = record(request, in: folder)
        context.insert(history)
        try context.save()
        let stored = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<RequestHistory>()).first)
        for entry in [history, stored] {
            let text = allText(entry)
            XCTAssertFalse(text.contains("SECRET"), text)
        }
    }

    func testHistoryKeepsResolvedPlainValuesAndSecretsAsNames() {
        let (folder, request) = makeCollection()
        let history = record(request, in: folder)
        XCTAssertEqual(history.url, "https://staging.example.com/users?k={{key}}")
        XCTAssertEqual(history.requestHeaders.map(\.value), ["{{key}}", "ada"])
        XCTAssertEqual(history.queryParams?.map(\.value), ["{{token}}"])
        XCTAssertEqual(history.requestBody, #"{"user":"ada","token":"{{token}}"}"#)
        XCTAssertEqual(history.authBasicUsername, "ada")
        XCTAssertEqual(history.authBasicPassword, "{{pw}}")
        XCTAssertEqual(history.authBearerToken, "{{token}}")
        XCTAssertEqual(history.bodyType, .json)
        XCTAssertEqual(history.authenticationType, .basic)
        XCTAssertEqual(history.method, .post)
        XCTAssertEqual(history.requestName, "Create")
        XCTAssertEqual(history.savedRequestID, request.id)
    }

    func testHistoryNamesTheEnvironmentItResolvedWith() {
        let (folder, request) = makeCollection()
        XCTAssertEqual(record(request, in: folder).environmentName, "Staging")
        folder.selectedEnvironment = nil
        XCTAssertEqual(record(request, in: folder).environmentName, "Default")
        XCTAssertEqual(record(request, in: folder).url, "https://local.example.com/users?k={{key}}", "Staging's key is gone, so it is sent as written")
        folder.defaultEnvironment?.name = "Local"
        XCTAssertEqual(record(request, in: folder).environmentName, "Local")
        XCTAssertNil(RequestHistory(request: request).environmentName, "Recorded without one")
    }

    func testRecordingDoesNotChangeTheSavedRequest() {
        let (folder, request) = makeCollection()
        _ = record(request, in: folder)
        XCTAssertEqual(request.url, "{{host}}/users?k={{key}}")
        XCTAssertEqual(request.authBasicPassword, "{{pw}}")
        XCTAssertEqual(request.headers.map(\.value), ["{{key}}", "{{user}}"])
    }

    func testAnEmptyBodyIsRecordedAsNoBody() {
        let request = APIRequest(name: "Get", url: "https://x")
        context.insert(request)
        request.bodyType = .json
        XCTAssertNil(RequestHistory(request: request).requestBody)
        request.bodyContent = " "
        XCTAssertEqual(RequestHistory(request: request).requestBody, " ", "Whitespace is a body")
    }

    func testRestoringARedactedEntryKeepsTheVariablesSoTheyResolveAgain() {
        let (folder, request) = makeCollection()
        let restored = record(request, in: folder).makeRequest(folder: folder)
        XCTAssertEqual(restored.name, "Create")
        XCTAssertEqual(restored.authBasicPassword, "{{pw}}")
        XCTAssertEqual(restored.authenticationType, .basic)
        XCTAssertIdentical(restored.folder, folder)
        XCTAssertNotEqual(restored.id, request.id, "A new request, not the original")
        XCTAssertEqual(RequestSnapshot(restored).resolved(with: folder.variableResolver).authBasicPassword, "pw-SECRET")
    }

    func testRestoringAnOlderEntryFillsInDefaults() {
        let entry = RequestHistory(url: "https://x/y", method: .put, requestHeaders: [KeyValuePair(key: "A", value: "1")], requestBody: "raw")
        let restored = entry.makeRequest()
        XCTAssertEqual(restored.name, "https://x/y", "No saved name: the URL")
        XCTAssertEqual(restored.method, .put)
        XCTAssertEqual(restored.headers.map(\.key), ["A"])
        XCTAssertEqual(restored.queryParams, [])
        XCTAssertEqual(restored.bodyContent, "raw")
        XCTAssertEqual(restored.bodyType, .json, "A body with no recorded type is JSON")
        XCTAssertEqual(restored.authenticationType, .none)
        XCTAssertNil(restored.folder)

        let noBody = RequestHistory(url: "https://x", method: .get)
        noBody.bodyType = .xml
        XCTAssertEqual(noBody.makeRequest().bodyType, .none, "No body, no body type")
    }

    // MARK: Responses

    private func response(status: Int = 200, body: String? = "ok", contentType: String? = "text/plain", bodySize: Int? = nil, stream: StreamInfo? = nil) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [KeyValuePair(key: "content-type", value: "text/html")], body: body, responseTime: 12.5, contentType: contentType, bodySize: bodySize, stream: stream)
    }

    func testSuccessFollowsTheStatusCode() {
        let cases: [(Int, Bool)] = [(199, false), (200, true), (204, true), (299, true), (300, false), (304, false), (404, false), (500, false)]
        for (status, success) in cases {
            let entry = RequestHistory(url: "https://x", method: .get)
            entry.record(response(status: status))
            XCTAssertEqual(entry.wasSuccessful, success, "\(status)")
            XCTAssertEqual(entry.response?.statusCode, status)
        }
    }

    func testResponseSizeFallsBackToTheBodysUTF8Length() {
        let entry = RequestHistory(url: "https://x", method: .get)
        entry.record(response(body: "é🚀"))
        XCTAssertEqual(entry.responseSize, 6, "Bytes, not characters")
        entry.record(response(body: "é🚀", bodySize: 1024))
        XCTAssertEqual(entry.responseSize, 1024, "The size as received wins")
        entry.record(response(body: nil))
        XCTAssertNil(entry.responseSize)
        XCTAssertNil(entry.response?.body)
    }

    func testAnEntryWithNothingRecordedHasNoResponse() {
        XCTAssertNil(RequestHistory(url: "https://x", method: .get).response)
    }

    func testContentTypeFallsBackToTheHeaderCaseInsensitively() {
        let entry = RequestHistory(url: "https://x", method: .get)
        entry.record(response(contentType: nil))
        XCTAssertNil(entry.responseContentType)
        XCTAssertEqual(entry.response?.contentType, "text/html")
        entry.record(response(contentType: "application/json"))
        XCTAssertEqual(entry.response?.contentType, "application/json")
    }

    func testAResponseAfterAFailureClearsTheError() {
        let entry = RequestHistory(url: "https://x", method: .get)
        entry.record(URLError(.timedOut))
        XCTAssertNotNil(entry.errorMessage)
        XCTAssertEqual(entry.response?.statusCode, 0)
        entry.record(response(status: 201))
        XCTAssertNil(entry.errorMessage)
        XCTAssertTrue(entry.wasSuccessful)
        XCTAssertEqual(entry.response?.statusCode, 201)
    }

    func testAFailureMessageIsShownAsTheResponseBody() {
        let entry = RequestHistory(url: "https://x", method: .get)
        entry.record(URLError(.cannotFindHost))
        let shown = entry.response
        XCTAssertEqual(shown?.body, "Error: \(URLError(.cannotFindHost).localizedDescription)")
        XCTAssertEqual(shown?.headers, [])
        XCTAssertFalse(entry.wasSuccessful)
    }

    func testAResponseWithoutTimingOrStreamStoresNeither() {
        let entry = RequestHistory(url: "https://x", method: .get)
        entry.record(response())
        XCTAssertNil(entry.responseTimingData)
        XCTAssertNil(entry.responseStreamData)
        XCTAssertNil(entry.response?.timing)
        XCTAssertNil(entry.response?.stream)
        XCTAssertEqual(entry.response?.responseTime, 12.5)
    }

    func testAStoppedStreamIsStoredAndComesBackFromTheStore() throws {
        let stream = StreamInfo(
            kind: .sse,
            events: [
                StreamEvent(index: 0, time: 10, event: nil, data: #"{"delta":"Hel"}"#, eventID: "1"),
                StreamEvent(index: 1, time: 20, event: "message_delta", data: "lo\nworld", eventID: nil)
            ], firstByteTime: 8, text: "Hello", firstTextTime: 10, end: .stopped)
        let entry = RequestHistory(url: "https://llm.example.com/v1", method: .post)
        entry.record(response(contentType: "text/event-stream", stream: stream))
        context.insert(entry)
        try context.save()

        let stored = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<RequestHistory>()).first)
        XCTAssertEqual(stored.response?.stream, stream, "Events, text, timings and how it ended")
        XCTAssertEqual(stored.response?.stream?.isLive, false)
        XCTAssertEqual(stored.response?.contentType, "text/event-stream")
    }

    func testEveryWayAStreamEndsIsKept() {
        for end in [StreamEnd.streaming, .completed, .stopped, .failed("connection reset 💥")] {
            let entry = RequestHistory(url: "https://x", method: .get)
            entry.record(response(stream: StreamInfo(kind: .ndjson, end: end)))
            XCTAssertEqual(entry.response?.stream?.end, end)
            XCTAssertEqual(entry.response?.stream?.kind, .ndjson)
        }
    }

    func testUnreadableStoredStreamDataIsIgnoredNotFatal() {
        let entry = RequestHistory(url: "https://x", method: .get)
        entry.record(response())
        entry.responseStreamData = Data("not json".utf8)
        entry.responseTimingData = Data([0x00])
        XCTAssertNil(entry.response?.stream)
        XCTAssertNil(entry.response?.timing)
        XCTAssertEqual(entry.response?.body, "ok", "The rest of the response still shows")
    }

    func testCookiesNeedAURL() {
        let entry = RequestHistory(url: "", method: .get)
        entry.record(HTTPResponse(statusCode: 200, headers: [KeyValuePair(key: "Set-Cookie", value: "a=1")], body: nil, responseTime: 0, contentType: nil))
        XCTAssertEqual(entry.response?.cookies.count, 0)
    }
}

@MainActor
final class HistoryRetentionBoundaryTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private let suite = "HistoryRetentionBoundaryTests.\(UUID().uuidString)"

    override func setUp() async throws {
        container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suite)
        container = nil
    }

    @discardableResult
    private func insert(_ seconds: [Int]) -> [RequestHistory] {
        seconds.map { second in
            let entry = RequestHistory(url: "https://example.com/\(second)", method: .get)
            entry.timestamp = Date(timeIntervalSince1970: 1_000_000 + Double(second))
            context.insert(entry)
            return entry
        }
    }

    private func urls() throws -> [String] {
        try context.fetch(FetchDescriptor<RequestHistory>(sortBy: [SortDescriptor(\.timestamp)])).map(\.url)
    }

    func testTrimKeepsTheNewestByTimestampNotByInsertionOrder() throws {
        insert([5, 1, 9, 3, 7])
        XCTAssertEqual(HistoryRetention.trim(context, limit: 2), 3)
        XCTAssertEqual(try urls(), ["https://example.com/7", "https://example.com/9"])
    }

    func testTrimAtExactlyTheLimitDeletesNothing() throws {
        insert([1, 2, 3])
        XCTAssertEqual(HistoryRetention.trim(context, limit: 3), 0)
        XCTAssertEqual(try urls().count, 3)
        XCTAssertEqual(HistoryRetention.trim(context, limit: 2), 1)
        XCTAssertEqual(try urls(), ["https://example.com/2", "https://example.com/3"])
    }

    func testTrimToOneKeepsOnlyTheNewest() throws {
        insert([1, 2, 3])
        XCTAssertEqual(HistoryRetention.trim(context, limit: 1), 2)
        XCTAssertEqual(try urls(), ["https://example.com/3"])
    }

    func testTrimToZeroOrLessDeletesEverything() throws {
        insert([1, 2])
        XCTAssertEqual(HistoryRetention.trim(context, limit: 0), 2)
        insert([3])
        XCTAssertEqual(HistoryRetention.trim(context, limit: -5), 1)
        XCTAssertEqual(try urls(), [])
    }

    func testTrimAnEmptyHistory() throws {
        XCTAssertEqual(HistoryRetention.trim(context, limit: 1), 0)
        XCTAssertEqual(HistoryRetention.clear(context), 0)
    }

    func testTrimCountsSavedAndUnsavedEntriesTogether() throws {
        insert([1, 2])
        try context.save()
        insert([3, 4])
        XCTAssertEqual(HistoryRetention.trim(context, limit: 3), 1)
        XCTAssertEqual(try urls(), ["https://example.com/2", "https://example.com/3", "https://example.com/4"])
    }

    func testTrimSavesAndLeavesTheKeptEntriesIntact() throws {
        let kept = insert([1, 2])[1]
        kept.record(HTTPResponse(statusCode: 201, headers: [], body: "body", responseTime: 3, contentType: nil))
        kept.environmentName = "Staging"
        HistoryRetention.trim(context, limit: 1)
        XCTAssertFalse(context.hasChanges, "The deletion is saved")
        let stored = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<RequestHistory>()).first)
        XCTAssertEqual(stored.id, kept.id)
        XCTAssertEqual(stored.statusCode, 201)
        XCTAssertEqual(stored.responseBody, "body")
        XCTAssertEqual(stored.environmentName, "Staging")
    }

    func testTrimDoesNotTouchCollections() throws {
        let folder = Folder(name: "Keep")
        context.insert(folder)
        folder.ensureDefaultEnvironment()
        context.insert(APIRequest(name: "R", folder: folder))
        insert([1, 2, 3])
        HistoryRetention.clear(context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Folder>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<APIRequest>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CollectionEnvironment>()), 1)
    }

    func testDeletionsAreAnnouncedWithTheDeletedIDs() throws {
        let entries = insert([1, 2, 3, 4])
        let recorder = DeletionRecorder()
        let observer = NotificationCenter.default.addObserver(forName: .remoteAgentWillDelete, object: nil, queue: nil) { note in
            recorder.append(note.userInfo?["ids"] as? Set<UUID> ?? [])
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var announced: [Set<UUID>] { recorder.ids }

        HistoryRetention.trim(context, limit: 2)
        XCTAssertEqual(announced, [Set(entries.prefix(2).map(\.id))], "Only the oldest two, before they go")
        HistoryRetention.trim(context, limit: 2)
        XCTAssertEqual(announced.count, 1, "Nothing deleted, nothing announced")
        HistoryRetention.clear(context)
        XCTAssertEqual(announced.last, Set(entries.suffix(2).map(\.id)))
        HistoryRetention.clear(context)
        XCTAssertEqual(announced.count, 2)
    }

    func testLimitReadsOnlyWholeNumbersAndClampsThem() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cases: [(Any, Int)] = [
            (1, 1), (300, 300), (99_999, 99_999), (100_000, 100_000), (100_001, 100_000), (Int.max, 100_000), (-1, 1), (Int.min, 1), ("50", 300)
        ]
        for (value, expected) in cases {
            defaults.set(value, forKey: HistoryRetention.limitKey)
            XCTAssertEqual(HistoryRetention.limit(in: defaults), expected, "\(value)")
        }
        defaults.removeObject(forKey: HistoryRetention.limitKey)
        XCTAssertEqual(HistoryRetention.limit(in: defaults), HistoryRetention.defaultLimit)
    }
}

/// Collects the ids `.remoteAgentWillDelete` announces (posted synchronously on the deleting thread).
private final class DeletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [Set<UUID>] = []

    var ids: [Set<UUID>] { lock.withLock { collected } }

    func append(_ ids: Set<UUID>) { lock.withLock { collected.append(ids) } }
}
