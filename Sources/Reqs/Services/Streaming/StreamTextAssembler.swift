import Foundation

/// Joins the text deltas of a streamed LLM reply into the reply itself.
///
/// Recognises OpenAI Chat Completions (`choices[0].delta.content`, and legacy `choices[0].text`), the OpenAI
/// Responses API (`response.output_text.delta`), Anthropic Messages (`content_block_delta` → `delta.text`),
/// Ollama (`message.content` or `response`, with `done`) and Gemini (`candidates[0].content.parts[].text`).
/// Other events, and `[DONE]`, add nothing.
struct StreamTextAssembler {
    /// The text so far; nil until an event carried a delta.
    private(set) var text: String?
    /// When the first non-empty delta arrived.
    private(set) var firstTextTime: Double?

    mutating func add(_ event: StreamEvent) {
        guard let delta = Self.delta(in: event.data) else { return }
        text = (text ?? "") + delta
        if firstTextTime == nil, !delta.isEmpty { firstTextTime = event.time }
    }

    /// The piece of reply text an event's data carries; nil when it carries none.
    static func delta(in data: String) -> String? {
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let bytes = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        else { return nil }

        switch object["type"] as? String {
        case "content_block_delta":
            return (object["delta"] as? [String: Any])?["text"] as? String
        case "response.output_text.delta":
            return object["delta"] as? String
        default:
            break
        }
        if let choice = (object["choices"] as? [[String: Any]])?.first {
            if let delta = choice["delta"] as? [String: Any] { return delta["content"] as? String ?? (delta.isEmpty ? nil : "") }
            if let text = choice["text"] as? String { return text }
        }
        if object["done"] != nil {
            if let content = (object["message"] as? [String: Any])?["content"] as? String { return content }
            if let response = object["response"] as? String { return response }
        }
        if let candidate = (object["candidates"] as? [[String: Any]])?.first,
            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        {
            let texts = parts.compactMap { $0["text"] as? String }
            return texts.isEmpty ? nil : texts.joined()
        }
        return nil
    }
}
