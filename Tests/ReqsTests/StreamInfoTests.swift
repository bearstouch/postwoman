import XCTest
import os

@testable import Reqs

final class StreamInfoTests: XCTestCase {
    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    func testANewStreamIsLiveAndEmpty() {
        let stream = StreamInfo(kind: .ndjson)
        XCTAssertEqual(stream.end, .streaming)
        XCTAssertTrue(stream.isLive)
        XCTAssertEqual(stream.events, [])
        XCTAssertNil(stream.text)
        XCTAssertNil(stream.firstByteTime)
        XCTAssertNil(stream.firstTextTime)
    }

    func testOnlyAStreamingStreamIsLive() {
        let ends: [(StreamEnd, Bool)] = [(.streaming, true), (.completed, false), (.stopped, false), (.failed("lost"), false), (.failed(""), false)]
        for (end, live) in ends {
            var stream = StreamInfo(kind: .sse)
            stream.end = end
            XCTAssertEqual(stream.isLive, live, "\(end)")
        }
    }

    func testEveryEndSurvivesEncoding() throws {
        for end in [StreamEnd.streaming, .completed, .stopped, .failed("The network connection was lost."), .failed(""), .failed("ü \"quoted\"\n")] {
            XCTAssertEqual(try roundTrip(end), end)
        }
        XCTAssertNotEqual(StreamEnd.failed("a"), .failed("b"), "The failure message is part of the end.")
    }

    func testAStreamSurvivesEncodingWithEveryField() throws {
        let stream = StreamInfo(
            kind: .sse,
            events: [
                StreamEvent(index: 0, time: 1.5, event: "delta", data: "line 1\nline 2 é", eventID: "id-1"), StreamEvent(index: 1, time: 2.25, data: ""),
                StreamEvent(index: 2, time: 3, event: nil, data: "[DONE]", eventID: "")
            ],
            firstByteTime: 1.25, text: "Hello 👋", firstTextTime: 1.5, end: .failed("lost"))
        XCTAssertEqual(try roundTrip(stream), stream)

        var bare = StreamInfo(kind: .ndjson)
        bare.end = .completed
        XCTAssertEqual(try roundTrip(bare), bare, "Nil times and text stay nil.")
    }

    func testAnEventsIdentityIsItsIndex() {
        XCTAssertEqual(StreamEvent(index: 7, time: 0, data: "x").id, 7)
        XCTAssertNotEqual(StreamEvent(index: 0, time: 0, data: "x"), StreamEvent(index: 0, time: 0, data: "x", eventID: "1"))
    }

    func testKindsEncodeAsTheirNames() throws {
        XCTAssertEqual(String(decoding: try JSONEncoder().encode([StreamKind.sse, .ndjson]), as: UTF8.self), #"["sse","ndjson"]"#)
    }
}

final class StreamExpectationEdgeCaseTests: XCTestCase {
    private func request(headers: [KeyValuePair] = [], bodyType: ContentType = .json, body: String = "") -> RequestSnapshot {
        var request = RequestSnapshot(APIRequest(name: "Chat", url: "https://llm.test/chat", method: .post))
        request.headers = headers
        request.bodyType = bodyType
        request.bodyContent = body
        return request
    }

    func testAcceptHeaderAsksForAStream() {
        let cases: [(KeyValuePair, Bool)] = [
            (KeyValuePair(key: "Accept", value: "text/event-stream"), true), (KeyValuePair(key: "ACCEPT", value: "Text/Event-Stream"), true),
            (KeyValuePair(key: "Accept", value: "application/json, text/event-stream;q=0.9"), true),
            (KeyValuePair(key: "Accept", value: "text/event-stream", isEnabled: false), false), (KeyValuePair(key: "Accept", value: "application/json"), false),
            (KeyValuePair(key: "Content-Type", value: "text/event-stream"), false), (KeyValuePair(key: "Accept-Encoding", value: "text/event-stream"), false)
        ]
        for (header, expected) in cases {
            XCTAssertEqual(request(headers: [header]).expectsStream, expected, "\(header.key): \(header.value) enabled=\(header.isEnabled)")
        }
    }

    func testOnlyATopLevelStreamTrueAsksForAStream() {
        let cases: [(String, Bool)] = [
            (#"{"stream":true}"#, true), (#" { "model": "m", "stream" : true } "#, true), (#"{"stream":false}"#, false), (#"{"stream":"true"}"#, false),
            (#"{"stream":null}"#, false), (#"{"options":{"stream":true}}"#, false), (#"[{"stream":true}]"#, false), (#"{"stream":true"#, false), ("stream=true", false),
            ("", false), (#"{"Stream":true}"#, false)
        ]
        for (body, expected) in cases {
            XCTAssertEqual(request(body: body).expectsStream, expected, body)
        }
    }

    func testAStreamFlagInAnUnsentBodyDoesntCount() {
        XCTAssertFalse(request(bodyType: .none, body: #"{"stream":true}"#).expectsStream)
        XCTAssertTrue(request(bodyType: .text, body: #"{"stream":true}"#).expectsStream, "Any body that is sent is read as JSON.")
    }
}

final class StreamingTaskDelegateTests: XCTestCase {
    private let session = URLSession(configuration: .ephemeral)

    private static func describe(_ delegate: StreamingTaskDelegate) async -> (events: [String], error: Error?) {
        var events: [String] = []
        do {
            for try await event in delegate.events {
                switch event {
                case .response(let response): events.append("response \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                case .data(let data): events.append("data \(String(decoding: data, as: UTF8.self))")
                }
            }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    func testHandsOnTheResponseAndChunksInOrderAndAllowsTheBody() async throws {
        let delegate = StreamingTaskDelegate()
        let task = session.dataTask(with: try XCTUnwrap(URL(string: "https://api.test/")))
        let disposition = OSAllocatedUnfairLock<URLSession.ResponseDisposition?>(initialState: nil)
        let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(task.originalRequest?.url), statusCode: 202, httpVersion: nil, headerFields: nil))

        delegate.urlSession(session, dataTask: task, didReceive: response) { value in disposition.withLock { $0 = value } }
        delegate.urlSession(session, dataTask: task, didReceive: Data("a".utf8))
        delegate.urlSession(session, dataTask: task, didReceive: Data("b".utf8))
        delegate.urlSession(session, task: task, didCompleteWithError: nil)

        let result = await Self.describe(delegate)
        XCTAssertEqual(result.events, ["response 202", "data a", "data b"])
        XCTAssertNil(result.error)
        XCTAssertEqual(disposition.withLock { $0 }, .allow)
        XCTAssertNil(delegate.timing, "No metrics were collected.")
    }

    func testAFailureEndsTheEventsWithTheErrorAfterWhatArrived() async throws {
        let delegate = StreamingTaskDelegate()
        let task = session.dataTask(with: try XCTUnwrap(URL(string: "https://api.test/")))
        delegate.urlSession(session, dataTask: task, didReceive: Data("partial".utf8))
        delegate.urlSession(session, task: task, didCompleteWithError: URLError(.networkConnectionLost))
        delegate.urlSession(session, dataTask: task, didReceive: Data("late".utf8))

        let result = await Self.describe(delegate)
        XCTAssertEqual(result.events, ["data partial"], "Nothing arrives after the end.")
        XCTAssertEqual((result.error as? URLError)?.code, .networkConnectionLost)
    }

    func testTerminationHandlerRunsWhenTheConsumerStops() async {
        let delegate = StreamingTaskDelegate()
        let terminated = expectation(description: "onTermination")
        delegate.onTermination { terminated.fulfill() }
        // A plain loop, not `Self.describe`: Swift 6.3's isolation checker crashes on a task closure that captures `Self`.
        let consumer = Task { for try await _ in delegate.events {} }
        consumer.cancel()
        await fulfillment(of: [terminated], timeout: 2)
        _ = try? await consumer.value
    }

    func testTerminationHandlerRunsWhenTheTaskCompletes() async throws {
        let delegate = StreamingTaskDelegate()
        let terminated = expectation(description: "onTermination")
        delegate.onTermination { terminated.fulfill() }
        delegate.urlSession(session, task: session.dataTask(with: try XCTUnwrap(URL(string: "https://api.test/"))), didCompleteWithError: nil)
        await fulfillment(of: [terminated], timeout: 2)
    }
}
