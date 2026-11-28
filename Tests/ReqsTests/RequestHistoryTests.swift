import SwiftData
import XCTest

@testable import Reqs

@MainActor
final class RequestHistoryTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() async throws {
        container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() async throws {
        container = nil
    }

    private func makeRequest() -> APIRequest {
        let request = APIRequest(name: "Get user", url: "https://api.example.com/users/1", method: .post)
        request.headers = [KeyValuePair(key: "Accept", value: "application/json")]
        request.queryParams = [KeyValuePair(key: "verbose", value: "true")]
        request.bodyType = .json
        request.bodyContent = #"{"a":1}"#
        request.authenticationType = .bearer
        request.authBearerToken = "secret"
        container.mainContext.insert(request)
        return request
    }

    func testSnapshotsTheRequestAndRestoresIt() {
        let request = makeRequest()
        let history = RequestHistory(request: request)
        container.mainContext.insert(history)

        XCTAssertEqual(history.requestName, "Get user")
        XCTAssertEqual(history.savedRequestID, request.id)

        let restored = history.makeRequest()
        XCTAssertEqual(restored.name, "Get user")
        XCTAssertEqual(restored.url, request.url)
        XCTAssertEqual(restored.method, .post)
        XCTAssertEqual(restored.headers, request.headers)
        XCTAssertEqual(restored.queryParams, request.queryParams)
        XCTAssertEqual(restored.bodyType, .json)
        XCTAssertEqual(restored.bodyContent, request.bodyContent)
        XCTAssertEqual(restored.authenticationType, .bearer)
        XCTAssertEqual(restored.authBearerToken, "secret")
    }

    func testAHeadEntryRecordsNoBodyBecauseNoneWasSent() {
        let request = makeRequest()
        request.method = .head
        let history = RequestHistory(request: request)
        container.mainContext.insert(history)
        XCTAssertEqual(history.method, .head)
        XCTAssertNil(history.requestBody)
        XCTAssertEqual(history.bodyType, ContentType.none, "No body type for a body that wasn't sent")
        XCTAssertEqual(history.makeRequest().bodyType, ContentType.none)
        XCTAssertEqual(history.makeRequest().bodyContent, "", "Open as Request gives back what was sent")
        XCTAssertEqual(request.bodyContent, #"{"a":1}"#, "The saved request keeps its body")
    }

    func testRecordsTheResponseAndRebuildsIt() {
        let history = RequestHistory(request: makeRequest())
        container.mainContext.insert(history)
        let timing = ResponseTiming(
            taskStart: Date(timeIntervalSince1970: 0), total: 120,
            marks: .init(responseStart: Date(timeIntervalSince1970: 0.05), responseEnd: Date(timeIntervalSince1970: 0.1)),
            networkProtocol: "HTTP/2")
        let response = HTTPResponse(
            statusCode: 201,
            headers: [
                KeyValuePair(key: "Content-Type", value: "application/json"),
                KeyValuePair(key: "Set-Cookie", value: "session=abc; Path=/")
            ],
            body: #"{"ok":true}"#,
            responseTime: 120,
            contentType: "application/json",
            timing: timing,
            bodySize: 11)

        history.record(response)
        let rebuilt = history.response

        XCTAssertTrue(history.wasSuccessful)
        XCTAssertEqual(rebuilt?.statusCode, 201)
        XCTAssertEqual(rebuilt?.body, #"{"ok":true}"#)
        XCTAssertEqual(rebuilt?.contentType, "application/json")
        XCTAssertEqual(rebuilt?.headers.count, 2)
        XCTAssertEqual(rebuilt?.bodySize, 11)
        XCTAssertEqual(rebuilt?.timing, timing)
        XCTAssertEqual(rebuilt?.cookies.map(\.name), ["session"])
    }

    func testRecordsAFailure() {
        let history = RequestHistory(request: makeRequest())
        container.mainContext.insert(history)

        history.record(URLError(.notConnectedToInternet))

        XCTAssertFalse(history.wasSuccessful)
        XCTAssertNotNil(history.errorMessage)
        XCTAssertEqual(history.response?.statusCode, 0)
        XCTAssertEqual(history.response?.body?.hasPrefix("Error: "), true)
    }
}
