import XCTest

@testable import PostWoman

/// Feeds `chunks` (chunk `i` arrives at time `i`) and finishes the stream at time `chunks.count`.
private func parse(_ chunks: [Data], kind: StreamKind) -> [StreamEvent] {
    var parser = StreamEventParser(kind: kind)
    var events: [StreamEvent] = []
    for (index, chunk) in chunks.enumerated() { events += parser.feed(chunk, time: Double(index)) }
    return events + parser.finish(time: Double(chunks.count))
}

private func parse(_ chunks: [String], kind: StreamKind = .sse) -> [StreamEvent] {
    parse(chunks.map { Data($0.utf8) }, kind: kind)
}

final class StreamEventParserEdgeCaseTests: XCTestCase {
    func testSplittingAtEveryByteGivesTheSameEvents() {
        let text = "event: δ\r\nid: 9\ndata: héllo 👋🏽 世界\r\ndata: second\r\r: note\ndata: {\"t\":\"ü\"}\n\n"
        let bytes = Array(text.utf8)
        let whole = parse([Data(bytes)], kind: .sse)
        XCTAssertEqual(whole.map(\.data), ["héllo 👋🏽 世界\nsecond", #"{"t":"ü"}"#])
        XCTAssertEqual(whole.first?.event, "δ")
        for cut in 1..<bytes.count {
            let split = parse([Data(bytes[..<cut]), Data(bytes[cut...])], kind: .sse)
            XCTAssertEqual(split.map(\.data), whole.map(\.data), "Split at byte \(cut)")
            XCTAssertEqual(split.map(\.event), whole.map(\.event), "Split at byte \(cut)")
            XCTAssertEqual(split.map(\.eventID), whole.map(\.eventID), "Split at byte \(cut)")
        }
    }

    func testSplittingNDJSONAtEveryByteGivesTheSameEvents() {
        let bytes = Array("{\"a\":\"ação\"}\r\n\n  {\"b\":\"🚀\"}\r{\"c\":3}".utf8)
        let whole = parse([Data(bytes)], kind: .ndjson).map(\.data)
        XCTAssertEqual(whole, [#"{"a":"ação"}"#, #"{"b":"🚀"}"#, #"{"c":3}"#])
        for cut in 1..<bytes.count {
            XCTAssertEqual(parse([Data(bytes[..<cut]), Data(bytes[cut...])], kind: .ndjson).map(\.data), whole, "Split at byte \(cut)")
        }
    }

    func testACRAtTheEndOfAChunkAndALFAtTheStartOfTheNextAreOneLineEnd() {
        let events = parse(["data: a\r", "\n", "data: b\r", "\n\r", "\n"])
        XCTAssertEqual(events.map(\.data), ["a\nb"], "CR then LF across chunks ends one line, not two.")
        XCTAssertEqual(events.first?.time, 3, "The CR of the blank line dispatches it; the LF after it is skipped.")
    }

    func testTwoCRsAreABlankLine() {
        XCTAssertEqual(parse(["data: a\r\rdata: b\r\r"]).map(\.data), ["a", "b"])
        XCTAssertEqual(parse(["data: a\n\r\ndata: b\r\n\n"]).map(\.data), ["a", "b"])
    }

    func testDataFieldValueRules() {
        let cases: [(String, String)] = [
            ("data: x\n\n", "x"), ("data:x\n\n", "x"), ("data:  x\n\n", " x"), ("data: x \n\n", "x "), ("data:\n\n", ""), ("data\n\n", ""),
            ("data: a: b\n\n", "a: b"), ("data: \n\n", ""), ("data:\ndata:\n\n", "\n"), ("data: {\"k\":\"v\"}\n\n", #"{"k":"v"}"#)
        ]
        for (input, data) in cases {
            XCTAssertEqual(parse([input]).map(\.data), [data], input.debugDescription)
        }
    }

    func testFieldNamesAreCaseSensitiveAndUnknownFieldsAreIgnored() {
        XCTAssertEqual(parse(["Data: no\nDATA: no\nfoo: bar\ndata: yes\n\n"]).map(\.data), ["yes"])
        XCTAssertTrue(parse(["Data: no\n\n", "event: x\n\n"]).isEmpty, "Without a data field nothing is dispatched.")
    }

    func testRetryFieldIsIgnoredWithoutDroppingTheEvent() {
        let events = parse(["retry: 3000\ndata: a\nretry\nretry: soon\n\n"])
        XCTAssertEqual(events, [StreamEvent(index: 0, time: 0, data: "a")])
    }

    func testCommentsAndKeepAlivesProduceNothing() {
        XCTAssertTrue(parse([":\n", ": ping\n\n", ":data: hidden\n\n", "\n\n\n"]).isEmpty)
        XCTAssertEqual(parse([": c\ndata: a\n: c2\ndata: b\n\n"]).map(\.data), ["a\nb"], "A comment between data lines doesn't split the event.")
    }

    func testEventNameAndIDBelongToOneEvent() {
        let events = parse(["event: first\nid: 1\ndata: a\n\ndata: b\n\nevent:\nid:\ndata: c\n\n"])
        XCTAssertEqual(events.map(\.event), ["first", nil, nil], "An empty event name is the default.")
        XCTAssertEqual(events.map(\.eventID), ["1", nil, ""], "An id applies to the event that set it; an empty id is kept as empty.")
        XCTAssertEqual(events.map(\.index), [0, 1, 2])
    }

    func testTheLastEventNameAndIDWin() {
        let events = parse(["event: a\nevent: b\nid: 1\nid: 2\ndata: x\n\n"])
        XCTAssertEqual(events.first?.event, "b")
        XCTAssertEqual(events.first?.eventID, "2")
    }

    func testAnIDContainingNULIsIgnored() {
        XCTAssertEqual(parse(["id: ok\nid: bad\u{0}id\ndata: x\n\n"]).first?.eventID, "ok")
    }

    func testAnEventWithoutDataResetsItsNameAndID() {
        let events = parse(["event: ping\nid: 5\n\ndata: x\n\n"])
        XCTAssertEqual(events, [StreamEvent(index: 0, time: 0, data: "x")], "The ping's name and id don't leak into the next event.")
    }

    func testDONEIsAnOrdinaryEvent() {
        let events = parse(["data: {\"a\":1}\n\ndata: [DONE]\n\n"])
        XCTAssertEqual(events.map(\.data), [#"{"a":1}"#, "[DONE]"])
    }

    func testVeryLongLinesArriveWhole() {
        let payload = String(repeating: "abcdefghij", count: 100_000) + "é"
        let bytes = Array("data: \(payload)\n\n".utf8)
        let chunks = stride(from: 0, to: bytes.count, by: 4093).map { Data(bytes[$0..<min($0 + 4093, bytes.count)]) }
        let events = parse(chunks, kind: .sse)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data.count, payload.count)
        XCTAssertEqual(events.first?.data, payload)
    }

    func testInvalidUTF8IsReplacedNotDropped() {
        XCTAssertEqual(parse([Data("data: a".utf8) + Data([0xC3]) + Data("\n\n".utf8)], kind: .sse).map(\.data), ["a\u{FFFD}"])
        XCTAssertEqual(parse([Data([0xFF, 0xFE]) + Data("\n".utf8)], kind: .ndjson).map(\.data), ["\u{FFFD}\u{FFFD}"])
    }

    func testEmptyChunksAndFinishingTwiceAddNothing() {
        var parser = StreamEventParser(kind: .sse)
        XCTAssertTrue(parser.feed(Data(), time: 0).isEmpty)
        XCTAssertTrue(parser.feed(Data("data: a".utf8), time: 1).isEmpty, "An unfinished line waits for its line end.")
        XCTAssertTrue(parser.feed(Data(), time: 2).isEmpty)
        XCTAssertEqual(parser.finish(time: 3), [StreamEvent(index: 0, time: 3, data: "a")], "Finishing flushes the line and dispatches it.")
        XCTAssertTrue(parser.finish(time: 4).isEmpty)
    }

    func testFinishDispatchesCompleteLinesWithoutTheBlankLine() {
        XCTAssertEqual(parse(["event: e\ndata: a\ndata: b\n"]), [StreamEvent(index: 0, time: 1, event: "e", data: "a\nb")])
        XCTAssertTrue(parse(["event: e\nid: 1\n"]).isEmpty, "Nothing to dispatch without data.")
        XCTAssertTrue(parse([String]()).isEmpty)
    }

    func testEventTimesAreWhenTheDispatchingChunkArrived() {
        let events = parse(["data: a\n", "\ndata: b\n\ndata: c", "\n", "\n"])
        XCTAssertEqual(events.map(\.time), [1, 1, 3])
        XCTAssertEqual(events.map(\.index), [0, 1, 2])
    }

    func testNDJSONSkipsBlankAndWhitespaceLinesAndKeepsOthersAsWritten() {
        let events = parse(["\n \n\t\n{\"a\":1}\n  {\"b\":2}\t\nnot json\n{broken\n[1,2]\n\r\n"], kind: .ndjson)
        XCTAssertEqual(events.map(\.data), [#"{"a":1}"#, #"{"b":2}"#, "not json", "{broken", "[1,2]"], "Garbage lines are still events.")
        XCTAssertEqual(events.map(\.index), [0, 1, 2, 3, 4], "Blank lines don't use up an index.")
        XCTAssertTrue(events.allSatisfy { $0.event == nil && $0.eventID == nil })
    }

    func testNDJSONHasNoSSEFields() {
        XCTAssertEqual(parse(["data: x\n: comment\nevent: e\n"], kind: .ndjson).map(\.data), ["data: x", ": comment", "event: e"])
    }

    func testNDJSONFinishFlushesOnlyAPendingLine() {
        var parser = StreamEventParser(kind: .ndjson)
        XCTAssertEqual(parser.feed(Data("{\"a\":1}\n".utf8), time: 0).count, 1)
        XCTAssertTrue(parser.finish(time: 1).isEmpty)
        XCTAssertEqual(parse(["{\"a\":1}\n{\"b\""], kind: .ndjson).map(\.data), [#"{"a":1}"#, #"{"b""#], "A cut-off last line is still kept.")
        XCTAssertTrue(parse(["   "], kind: .ndjson).isEmpty)
    }
}

final class StreamKindTests: XCTestCase {
    func testRecognisesStreamContentTypes() {
        let cases: [(String?, StreamKind?)] = [
            ("text/event-stream", .sse), ("Text/Event-Stream", .sse), (" text/event-stream ; charset=utf-8", .sse), ("text/event-stream;charset=UTF-8", .sse),
            ("application/x-ndjson", .ndjson), ("application/ndjson", .ndjson), ("application/jsonl", .ndjson), ("application/x-jsonlines", .ndjson),
            ("application/stream+json", .ndjson), ("APPLICATION/X-NDJSON; charset=utf-8", .ndjson),
            ("application/json", nil), ("text/plain", nil), ("text/event-streams", nil), ("text/event", nil), ("", nil), (";", nil), (nil, nil),
            ("multipart/x-mixed-replace; boundary=frame", nil)
        ]
        for (contentType, kind) in cases {
            XCTAssertEqual(StreamKind(contentType: contentType), kind, contentType ?? "nil")
        }
    }

    func testDisplayNames() {
        XCTAssertEqual(StreamKind.sse.displayName, "Server-sent events")
        XCTAssertEqual(StreamKind.ndjson.displayName, "NDJSON")
    }
}

final class StreamTextAssemblerEdgeCaseTests: XCTestCase {
    private func assemble(_ data: [String]) -> StreamTextAssembler {
        var assembler = StreamTextAssembler()
        for (index, item) in data.enumerated() { assembler.add(StreamEvent(index: index, time: Double(index * 10), data: item)) }
        return assembler
    }

    func testEventsWithoutReplyTextGiveNoDelta() {
        let inputs = [
            "", "   ", "[DONE]", "data", "null", "42", #""text""#, "[1,2]", #"[{"choices":[{"delta":{"content":"x"}}]}]"#, "{", #"{"choices":[{"delta":"#,
            #"{"choices":"nope"}"#, #"{"choices":[]}"#, #"{"choices":[{"finish_reason":"stop"}]}"#,
            #"{"choices":[{"delta":{}}]}"#, #"{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{\"a"}}"#,
            #"{"type":"content_block_delta"}"#, #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#, #"{"type":"ping"}"#,
            #"{"type":"response.output_text.done","text":"whole"}"#, #"{"type":"response.output_text.delta","delta":7}"#, #"{"response":"x"}"#,
            #"{"message":{"content":"x"}}"#, #"{"done":true}"#, #"{"candidates":[]}"#, #"{"candidates":[{"content":{"parts":[{"functionCall":{}}]}}]}"#,
            #"{"candidates":[{"finishReason":"STOP"}]}"#
        ]
        for input in inputs {
            XCTAssertNil(StreamTextAssembler.delta(in: input), input)
        }
    }

    func testDeltasOfEachProvider() {
        let cases: [(String, String)] = [
            (#"{"choices":[{"delta":{"content":"a"}}]}"#, "a"), (#"{"choices":[{"delta":{"role":"assistant"}}]}"#, ""),
            (#"{"choices":[{"text":"legacy"}]}"#, "legacy"), (#"{"choices":[{"delta":{"content":5}}]}"#, ""), (#"{"choices":[{"delta":{"content":"first"}},{"delta":{"content":"second"}}]}"#, "first"),
            (#"{"type":"response.output_text.delta","delta":"r"}"#, "r"), (#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"c"}}"#, "c"),
            (#"{"message":{"content":"m"},"done":false}"#, "m"), (#"{"response":"g","done":false}"#, "g"), (#"{"response":"","done":true}"#, ""),
            (#"{"candidates":[{"content":{"parts":[{"text":"x"},{"inlineData":{}},{"text":"y"}]}}]}"#, "xy"),
            (#"{"candidates":[{"content":{"parts":[{"text":"one"}]}},{"content":{"parts":[{"text":"two"}]}}]}"#, "one"),
            ("  \n{\"choices\":[{\"delta\":{\"content\":\"padded\"}}]}\n ", "padded"), (#"{"choices":[{"delta":{"content":"café 😀"}}]}"#, "café 😀"),
            (#"{"choices":[{"delta":{"content":"line\nbreak"}}]}"#, "line\nbreak")
        ]
        for (input, delta) in cases {
            XCTAssertEqual(StreamTextAssembler.delta(in: input), delta, input)
        }
    }

    func testARoleOnlyStreamHasEmptyTextButNoFirstToken() {
        let assembler = assemble([#"{"choices":[{"delta":{"role":"assistant"}}]}"#, #"{"choices":[{"delta":{"content":""}}]}"#])
        XCTAssertEqual(assembler.text, "", "The reply exists but is empty.")
        XCTAssertNil(assembler.firstTextTime)
    }

    func testMalformedEventsInTheMiddleDontBreakTheReply() {
        let assembler = assemble([
            #"{"choices":[{"delta":{"content":"A"}}]}"#, #"{"choices":[{"delta":{"content":"#, "garbage", #"{"choices":[{"delta":{"content":"B"}}]}"#, "[DONE]"
        ])
        XCTAssertEqual(assembler.text, "AB")
        XCTAssertEqual(assembler.firstTextTime, 0)
    }

    func testFirstTextTimeIsTheFirstNonEmptyDelta() {
        let assembler = assemble([
            #"{"type":"message_start"}"#, #"{"type":"content_block_delta","delta":{"text":""}}"#, #"{"type":"content_block_delta","delta":{"text":"x"}}"#,
            #"{"type":"content_block_delta","delta":{"text":"y"}}"#
        ])
        XCTAssertEqual(assembler.text, "xy")
        XCTAssertEqual(assembler.firstTextTime, 20)
    }

    func testMixedProvidersJoinInOrder() {
        let assembler = assemble([
            #"{"choices":[{"delta":{"content":"1"}}]}"#, #"{"type":"content_block_delta","delta":{"text":"2"}}"#, #"{"message":{"content":"3"},"done":false}"#,
            #"{"candidates":[{"content":{"parts":[{"text":"4"}]}}]}"#, #"{"type":"response.output_text.delta","delta":"5"}"#
        ])
        XCTAssertEqual(assembler.text, "12345")
    }

    func testManyDeltasJoinWithoutLoss() {
        let pieces = (0..<2_000).map { "w\($0) " }
        let assembler = assemble(pieces.map { #"{"choices":[{"delta":{"content":"\#($0)"}}]}"# })
        XCTAssertEqual(assembler.text, pieces.joined())
    }

    func testThePipelineFromBytesToText() {
        let body =
            "event: message_start\ndata: {\"type\":\"message_start\"}\n\nevent: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"Ol\"}}\n\nevent: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"á\"}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        let bytes = Array(body.utf8)
        for size in [1, 2, 3, 7, 64, bytes.count] {
            var parser = StreamEventParser(kind: .sse)
            var assembler = StreamTextAssembler()
            for start in stride(from: 0, to: bytes.count, by: size) {
                for event in parser.feed(Data(bytes[start..<min(start + size, bytes.count)]), time: 0) { assembler.add(event) }
            }
            for event in parser.finish(time: 0) { assembler.add(event) }
            XCTAssertEqual(assembler.text, "Olá", "Chunks of \(size) bytes")
        }
    }
}
