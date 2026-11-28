import SwiftData
import XCTest
import os

@testable import Reqs

final class StreamEventParserTests: XCTestCase {
    private func parse(_ chunks: [String], kind: StreamKind = .sse) -> [StreamEvent] {
        var parser = StreamEventParser(kind: kind)
        var events: [StreamEvent] = []
        for (index, chunk) in chunks.enumerated() { events += parser.feed(Data(chunk.utf8), time: Double(index)) }
        return events + parser.finish(time: Double(chunks.count))
    }

    func testDispatchesOnBlankLinesAcrossChunkBoundaries() {
        let events = parse(["data: {\"a\"", ":1}\n", "\ndata: two\n\n"])
        XCTAssertEqual(events.map(\.data), [#"{"a":1}"#, "two"])
        XCTAssertEqual(events.map(\.index), [0, 1])
        XCTAssertEqual(events.first?.time, 2, "An event's time is when its dispatching chunk arrived.")
    }

    func testJoinsDataLinesAndReadsEventAndID() {
        let events = parse(["event: delta\nid: 7\ndata: line one\ndata:line two\n\n"])
        XCTAssertEqual(events, [StreamEvent(index: 0, time: 0, event: "delta", data: "line one\nline two", eventID: "7")])
    }

    func testAcceptsCRLFAndCRLineEndsAndSkipsComments() {
        XCTAssertEqual(parse([": keep-alive\r\ndata: a\r", "\n\r\ndata: b\r\r"]).map(\.data), ["a", "b"])
    }

    func testKeepsCharactersSplitAcrossChunks() {
        let bytes = Array("data: olá 👋\n\n".utf8)
        var parser = StreamEventParser(kind: .sse)
        var events: [StreamEvent] = []
        for byte in bytes { events += parser.feed(Data([byte]), time: 0) }
        XCTAssertEqual(events.map(\.data), ["olá 👋"])
    }

    func testIgnoresEventsWithoutDataAndFlushesTheLastEventAtTheEnd() {
        XCTAssertEqual(parse(["event: ping\n\ndata: [DONE]"]).map(\.data), ["[DONE]"])
    }

    func testSplitsNDJSONLines() {
        XCTAssertEqual(parse(["{\"a\":1}\n\n{\"b\"", ":2}\r\n{\"c\":3}"], kind: .ndjson).map(\.data), [#"{"a":1}"#, #"{"b":2}"#, #"{"c":3}"#])
    }

    func testDetectsStreamContentTypes() {
        XCTAssertEqual(StreamKind(contentType: "text/event-stream; charset=utf-8"), .sse)
        XCTAssertEqual(StreamKind(contentType: "application/x-ndjson"), .ndjson)
        XCTAssertNil(StreamKind(contentType: "application/json"))
        XCTAssertNil(StreamKind(contentType: nil))
    }
}

final class StreamTextAssemblerTests: XCTestCase {
    private func assemble(_ data: [String]) -> StreamTextAssembler {
        var assembler = StreamTextAssembler()
        for (index, item) in data.enumerated() { assembler.add(StreamEvent(index: index, time: Double(index * 10), data: item)) }
        return assembler
    }

    func testOpenAIChatCompletions() {
        let assembler = assemble([
            #"{"choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}"#,
            #"{"choices":[{"index":0,"delta":{"content":"Hel"}}]}"#,
            #"{"choices":[{"index":0,"delta":{"content":"lo"}}]}"#,
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            "[DONE]"
        ])
        XCTAssertEqual(assembler.text, "Hello")
        XCTAssertEqual(assembler.firstTextTime, 10, "The empty first delta isn't the first token.")
    }

    func testOpenAIResponsesAPI() {
        let assembler = assemble([
            #"{"type":"response.created","response":{}}"#, #"{"type":"response.output_text.delta","delta":"Hi"}"#,
            #"{"type":"response.output_text.delta","delta":" there"}"#, #"{"type":"response.completed"}"#
        ])
        XCTAssertEqual(assembler.text, "Hi there")
    }

    func testAnthropicMessages() {
        let assembler = assemble([
            #"{"type":"message_start","message":{"id":"msg_1"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Bonjour"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"!"}}"#, #"{"type":"message_stop"}"#
        ])
        XCTAssertEqual(assembler.text, "Bonjour!")
    }

    func testOllamaAndGemini() {
        XCTAssertEqual(
            assemble([#"{"message":{"role":"assistant","content":"a"},"done":false}"#, #"{"message":{"role":"assistant","content":"b"},"done":true}"#]).text, "ab")
        XCTAssertEqual(assemble([#"{"response":"x","done":false}"#]).text, "x")
        XCTAssertEqual(assemble([#"{"candidates":[{"content":{"parts":[{"text":"g"}]}}]}"#]).text, "g")
    }

    func testOtherStreamsHaveNoText() {
        XCTAssertNil(assemble([#"{"price":1}"#, "plain", "[DONE]"]).text)
    }
}

final class StreamExpectationTests: XCTestCase {
    func testRequestsThatAskForAStreamGetCurlNoBuffer() {
        let request = APIRequest(name: "Chat", url: "https://api.example.com/chat", method: .post)
        request.bodyType = .json
        request.bodyContent = #"{"model":"m","stream":true}"#
        XCTAssertTrue(request.expectsStream)
        XCTAssertTrue(CURLGenerator().generate(from: request).hasPrefix("curl \\\n  -N"))

        request.bodyContent = #"{"model":"m","stream":false}"#
        XCTAssertFalse(request.expectsStream)
        XCTAssertFalse(CURLGenerator().generate(from: request).contains("-N"))

        request.headers = [KeyValuePair(key: "accept", value: "text/event-stream")]
        XCTAssertTrue(request.expectsStream)
        request.headers = [KeyValuePair(key: "Accept", value: "text/event-stream", isEnabled: false)]
        XCTAssertFalse(request.expectsStream)
    }
}

/// Serves `StreamingStubProtocol.script` for every request: the response, then each chunk after its delay;
/// `finishes: false` leaves the stream open until the task is cancelled.
final class StreamingStubProtocol: URLProtocol {
    struct Script: Sendable {
        var contentType: String
        var chunks: [(delay: TimeInterval, text: String)]
        var finishes = true
    }

    nonisolated(unsafe) static var script = Script(contentType: "text/plain", chunks: [])
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let script = Self.script
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": script.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        nonisolated(unsafe) let stub = self
        DispatchQueue.global().async {
            for chunk in script.chunks {
                Thread.sleep(forTimeInterval: chunk.delay)
                if stub.stopped.withLock({ $0 }) { return }
                stub.client?.urlProtocol(stub, didLoad: Data(chunk.text.utf8))
            }
            if script.finishes, !stub.stopped.withLock({ $0 }) { stub.client?.urlProtocolDidFinishLoading(stub) }
        }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }
}

@MainActor
final class HTTPClientStreamingTests: XCTestCase {
    private func client() -> HTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingStubProtocol.self]
        return HTTPClient(session: URLSession(configuration: configuration))
    }

    private let request: RequestSnapshot = {
        let request = APIRequest(name: "Chat", url: "https://llm.test/v1/chat/completions", method: .post)
        return RequestSnapshot(request)
    }()

    private static func chunk(_ content: String) -> String {
        "data: {\"choices\":[{\"delta\":{\"content\":\"\(content)\"}}]}\n\n"
    }

    func testParsesAStreamAndReportsProgress() async throws {
        StreamingStubProtocol.script = .init(
            contentType: "text/event-stream", chunks: [(0.02, Self.chunk("Hel")), (0.15, Self.chunk("lo")), (0.15, "data: [DONE]\n\n")])
        var progress: [HTTPResponse] = []
        let response = try await client().execute(request: request) { progress.append($0) }

        XCTAssertEqual(response.stream?.end, .completed)
        XCTAssertEqual(response.stream?.events.count, 3)
        XCTAssertEqual(response.stream?.text, "Hello")
        XCTAssertNotNil(response.stream?.firstByteTime)
        XCTAssertTrue(response.body?.hasSuffix("data: [DONE]\n\n") ?? false)
        XCTAssertGreaterThanOrEqual(progress.count, 2, "Progress arrives with the headers and as events come.")
        XCTAssertTrue(progress.allSatisfy { $0.stream?.isLive == true })
        XCTAssertEqual(progress.first?.stream?.events.count, 0)
    }

    func testAHeadResponseWithAStreamContentTypeIsNotAStream() async throws {
        StreamingStubProtocol.script = .init(contentType: "text/event-stream", chunks: [])
        var head = request
        head.method = .head
        var progress: [HTTPResponse] = []
        let response = try await client().execute(request: head) { progress.append($0) }
        XCTAssertNil(response.stream, "No empty Events view for a HEAD to an event stream")
        XCTAssertTrue(progress.isEmpty)
    }

    func testStoppingAStreamKeepsWhatArrived() async throws {
        StreamingStubProtocol.script = .init(contentType: "text/event-stream", chunks: [(0.01, Self.chunk("partial"))], finishes: false)
        let client = client()
        let request = request
        let task = Task { try await client.execute(request: request) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let response = try await task.value

        XCTAssertEqual(response.stream?.end, .stopped)
        XCTAssertEqual(response.stream?.text, "partial")
        XCTAssertEqual(response.statusCode, 200)
    }

    func testOtherResponsesAreNotStreams() async throws {
        StreamingStubProtocol.script = .init(contentType: "application/json", chunks: [(0, #"{"a":"#), (0.01, "1}")])
        var progressCount = 0
        let response = try await client().execute(request: request) { _ in progressCount += 1 }
        XCTAssertNil(response.stream)
        XCTAssertEqual(response.body, #"{"a":1}"#)
        XCTAssertEqual(progressCount, 0)
    }
}

@MainActor
final class StreamRecordingTests: XCTestCase {
    private let stream = StreamInfo(
        kind: .sse, events: [StreamEvent(index: 0, time: 12, event: "delta", data: "x", eventID: "1"), StreamEvent(index: 1, time: 20, data: "y")],
        firstByteTime: 10, text: "Hi", firstTextTime: 12, end: .stopped)

    func testHistoryKeepsTheStream() throws {
        let container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let request = APIRequest(name: "Chat", url: "https://llm.test/chat")
        container.mainContext.insert(request)
        let history = RequestHistory(request: request)
        history.record(HTTPResponse(statusCode: 200, headers: [], body: "data: x\n\n", responseTime: 30, contentType: "text/event-stream", stream: stream))
        XCTAssertEqual(history.response?.stream, stream)
    }

    func testAgentsGetTheEventsTextAndEnd() {
        let json = MCPToolHandler.json(stream, maxTextBytes: 1)
        XCTAssertEqual(json["end"], .string("stopped"))
        XCTAssertEqual(json["eventCount"], .number(2))
        XCTAssertEqual(json["text"], .string("H"))
        XCTAssertEqual(json["textTruncated"], .bool(true))
        guard case .array(let events)? = json["events"] else { return XCTFail("No events") }
        XCTAssertEqual(events.first?["event"], .string("delta"))
        XCTAssertEqual(json["eventsTruncated"], .bool(false))

        var failed = stream
        failed.end = .failed("lost")
        XCTAssertEqual(MCPToolHandler.json(failed, maxTextBytes: 10)["error"], .string("lost"))
    }
}
