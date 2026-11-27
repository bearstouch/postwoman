import Foundation

/// How a streamed response body is framed.
enum StreamKind: String, Codable, Sendable {
    /// Server-sent events (`text/event-stream`): `data:` lines, a blank line ends each event.
    case sse
    /// Newline-delimited JSON: one event per line.
    case ndjson

    /// The stream framing of a response `Content-Type`; nil when the response isn't a stream.
    init?(contentType: String?) {
        guard let type = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        switch type {
        case "text/event-stream": self = .sse
        case "application/x-ndjson", "application/ndjson", "application/jsonl", "application/x-jsonlines", "application/stream+json": self = .ndjson
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .sse: return "Server-sent events"
        case .ndjson: return "NDJSON"
        }
    }
}

/// One event of a streamed response.
struct StreamEvent: Codable, Equatable, Sendable, Identifiable {
    /// Position in the stream, from 0.
    let index: Int
    /// Milliseconds from the start of the request to when the event arrived.
    let time: Double
    /// The SSE `event:` name; nil for the default ("message") and for NDJSON.
    var event: String?
    /// The event's data: its `data:` lines joined with newlines, or the NDJSON line.
    var data: String
    /// The SSE `id:`, when the event set one.
    var eventID: String?

    var id: Int { index }
}

/// How a stream ended.
enum StreamEnd: Codable, Equatable, Sendable {
    /// Still arriving.
    case streaming
    /// The server closed it.
    case completed
    /// Stop was pressed (or the agent's time ran out) before the server closed it.
    case stopped
    /// The connection failed part way, with this message.
    case failed(String)
}

/// What a streamed response delivered: its events, the text an LLM reply assembles to, and when they arrived.
struct StreamInfo: Codable, Equatable, Sendable {
    var kind: StreamKind
    var events: [StreamEvent] = []
    /// Milliseconds from the start of the request to the first body byte.
    var firstByteTime: Double?
    /// The reply text, joined from the LLM deltas the events carry (OpenAI, Anthropic, Ollama, Gemini); nil when none do.
    var text: String?
    /// Milliseconds from the start of the request to the first non-empty piece of text.
    var firstTextTime: Double?
    var end: StreamEnd = .streaming

    var isLive: Bool { end == .streaming }
}

extension RequestFields {
    /// Whether the request asks for a streamed response: an `Accept: text/event-stream` header, or a JSON body
    /// with `"stream": true` at the top level (OpenAI, Anthropic, Ollama).
    var expectsStream: Bool {
        let acceptsEvents = headers.contains {
            $0.isEnabled && $0.key.caseInsensitiveCompare("Accept") == .orderedSame && $0.value.lowercased().contains("text/event-stream")
        }
        if acceptsEvents { return true }
        guard bodyType != .none, let data = bodyContent.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (object["stream"] as? Bool) == true
    }
}
