import Foundation

/// A Form Data body on the wire. The request keeps its fields as `a=1&b=2` (what the form editor and agents write);
/// sending it and generated code turn them into `multipart/form-data` parts.
enum MultipartForm {
    /// The fields to send, or nil when the body goes out as written: another body type, or the request names its own
    /// Content-Type, which means its author wrote the body (and its boundary) by hand.
    static func fields(of request: some RequestFields) -> [KeyValuePair]? {
        guard request.bodyType == .formData, !request.headers.contains(where: { $0.isEnabled && $0.key.lowercased() == "content-type" }) else { return nil }
        return FormBody.pairs(from: request.bodyContent).filter { !$0.key.isEmpty }
    }

    /// A boundary no field can contain by accident.
    static func makeBoundary() -> String { "PostWoman-" + UUID().uuidString }

    static func contentType(boundary: String) -> String { "multipart/form-data; boundary=\(boundary)" }

    /// A field name inside `name="…"`: quotes and line breaks percent-encoded, as browsers send them.
    static func escapedName(_ name: String) -> String {
        name.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\r", with: "%0D").replacingOccurrences(of: "\n", with: "%0A")
    }

    /// One part per field, then the closing boundary.
    static func body(_ fields: [KeyValuePair], boundary: String) -> Data {
        var text = ""
        for field in fields { text += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(escapedName(field.key))\"\r\n\r\n\(field.value)\r\n" }
        return Data((text + "--\(boundary)--\r\n").utf8)
    }
}
