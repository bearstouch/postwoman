import Foundation

/// Splits a streamed body into events as its bytes arrive, in chunks that can end anywhere (mid-line, mid-character).
///
/// Server-sent events follow the WHATWG rules: lines end with LF, CRLF or CR; `data:` lines are joined with
/// newlines; `event:` and `id:` name the event; lines starting with `:` are comments; a blank line dispatches
/// the event. NDJSON gives one event per non-blank line. One byte-order mark at the start of the stream is ignored.
struct StreamEventParser {
    let kind: StreamKind

    private var line: [UInt8] = []
    /// A CR ended the last line, so a LF right after it belongs to the same line end.
    private var skipsLineFeed = false
    private var dataLines: [String] = []
    private var eventName: String?
    private var eventID: String?
    private var count = 0
    /// How many bytes of a leading UTF-8 byte-order mark (EF BB BF) have arrived; nil once the stream is past its start.
    private var markBytes: Int? = 0
    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    init(kind: StreamKind) {
        self.kind = kind
    }

    /// The events `chunk` completes; `time` is when it arrived.
    mutating func feed(_ chunk: Data, time: Double) -> [StreamEvent] {
        var events: [StreamEvent] = []
        for byte in chunk {
            if let matched = markBytes {
                if byte == Self.byteOrderMark[matched] {
                    markBytes = matched + 1 == Self.byteOrderMark.count ? nil : matched + 1
                    continue
                }
                markBytes = nil
                line.append(contentsOf: Self.byteOrderMark[..<matched])  // only the start of a mark: they were text
            }
            if skipsLineFeed {
                skipsLineFeed = false
                if byte == 0x0A { continue }
            }
            if byte == 0x0A || byte == 0x0D {
                skipsLineFeed = byte == 0x0D
                if let event = takeLine(time: time) { events.append(event) }
            } else {
                line.append(byte)
            }
        }
        return events
    }

    /// The last event, when the stream ended without the line end or blank line that would dispatch it.
    mutating func finish(time: Double) -> [StreamEvent] {
        var events: [StreamEvent] = []
        if let matched = markBytes {
            markBytes = nil
            line.append(contentsOf: Self.byteOrderMark[..<matched])
        }
        if !line.isEmpty, let event = takeLine(time: time) { events.append(event) }
        if kind == .sse, let event = dispatch(time: time) { events.append(event) }
        return events
    }

    private mutating func takeLine(time: Double) -> StreamEvent? {
        // Lines split only at CR and LF, which never occur inside a UTF-8 sequence, so a whole line decodes.
        let text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        switch kind {
        case .ndjson:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return makeEvent(data: trimmed, time: time)
        case .sse:
            if text.isEmpty { return dispatch(time: time) }
            if text.hasPrefix(":") { return nil }
            let field: Substring, value: Substring
            if let colon = text.firstIndex(of: ":") {
                field = text[..<colon]
                let rest = text[text.index(after: colon)...]
                value = rest.hasPrefix(" ") ? rest.dropFirst() : rest
            } else {
                field = Substring(text)
                value = ""
            }
            switch field {
            case "data": dataLines.append(String(value))
            case "event": eventName = String(value)
            case "id" where !value.contains("\0"): eventID = String(value)
            default: break  // retry and unknown fields
            }
            return nil
        }
    }

    /// The event the lines so far describe; nil when they had no `data:`.
    private mutating func dispatch(time: Double) -> StreamEvent? {
        defer {
            dataLines = []
            eventName = nil
            eventID = nil
        }
        guard !dataLines.isEmpty else { return nil }
        var event = makeEvent(data: dataLines.joined(separator: "\n"), time: time)
        event.event = eventName.flatMap { $0.isEmpty ? nil : $0 }
        event.eventID = eventID
        return event
    }

    private mutating func makeEvent(data: String, time: Double) -> StreamEvent {
        defer { count += 1 }
        return StreamEvent(index: count, time: time, data: data)
    }
}
