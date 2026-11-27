import Foundation

// The HTTP/1.1 subset the MCP endpoint speaks, ported from Trellis's TrellisMCP. Named `MCPHTTP…`
// so they never collide with the app's own `HTTPResponse` (a response to a user's request).

/// One parsed HTTP/1.1 request. Header names are lowercased; a repeated header keeps its first value.
struct MCPHTTPRequest: Equatable, Sendable {
    let method: String
    let path: String
    let version: String
    let headers: [String: String]
    let body: Data

    init(method: String, path: String, version: String = "HTTP/1.1", headers: [String: String] = [:], body: Data = Data()) {
        self.method = method; self.path = path; self.version = version
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }) { first, _ in first }
        self.body = body
    }

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// HTTP/1.0 closes unless asked to stay; HTTP/1.1 stays unless asked to close.
    var keepAlive: Bool {
        let connection = header("connection")?.lowercased() ?? ""
        return version == "HTTP/1.0" ? connection.contains("keep-alive") : !connection.contains("close")
    }
}

struct MCPHTTPResponse: Equatable, Sendable {
    var status: Int
    var headers: [(String, String)]
    var body: Data

    init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }

    static func == (a: Self, b: Self) -> Bool {
        a.status == b.status && a.body == b.body && a.headers.map { "\($0.0):\($0.1)" } == b.headers.map { "\($0.0):\($0.1)" }
    }

    func header(_ name: String) -> String? { headers.first { $0.0.lowercased() == name.lowercased() }?.1 }

    static func json(_ status: Int, _ body: Data, headers: [(String, String)] = []) -> Self {
        Self(status: status, headers: [("Content-Type", "application/json")] + headers, body: body)
    }

    static func empty(_ status: Int, headers: [(String, String)] = []) -> Self { Self(status: status, headers: headers) }

    static func plain(_ status: Int, _ message: String) -> Self {
        Self(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")], body: Data((message + "\n").utf8))
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 503: "Service Unavailable"
        case 505: "HTTP Version Not Supported"
        default: "Error"
        }
    }

    /// Wire bytes. Content-Length is always set; no caching, no CORS.
    func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

enum MCPHTTPParseError: Error, Equatable, Sendable {
    /// Malformed request line or headers.
    case malformed
    case headersTooLarge
    case bodyTooLarge
    /// No Content-Length on a request with a body, or chunked transfer coding.
    case lengthRequired
    case unsupportedVersion

    var status: Int {
        switch self {
        case .malformed: 400
        case .headersTooLarge: 431
        case .bodyTooLarge: 413
        case .lengthRequired: 411
        case .unsupportedVersion: 505
        }
    }
}

/// Incremental request parser for one connection. Bounded: 16 KiB of headers, 64 header lines and a
/// 1 MiB body, so a client cannot grow memory.
struct MCPHTTPRequestParser: Sendable {
    static let maximumHeaderBytes = 16_384
    static let maximumHeaderCount = 64
    static let maximumBody = 1_048_576
    private static let headTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A])
    private var buffer = Data()

    init() {}

    /// Bytes of an incomplete request are buffered.
    var hasPartialRequest: Bool { !buffer.isEmpty }

    /// Appends bytes and returns every complete request now available, in order.
    mutating func append(_ bytes: Data) throws(MCPHTTPParseError) -> [MCPHTTPRequest] {
        buffer.append(bytes)
        var requests: [MCPHTTPRequest] = []
        // Consumed by offset and compacted once, so many small requests in one read cost linear time.
        var start = buffer.startIndex
        defer { if start > buffer.startIndex { buffer = Data(buffer[start...]) } }
        while let request = try next(from: &start) { requests.append(request) }
        return requests
    }

    private func next(from start: inout Data.Index) throws(MCPHTTPParseError) -> MCPHTTPRequest? {
        // Tolerate blank lines between requests (RFC 9112 §2.2).
        while buffer.endIndex - start >= 2, buffer[start] == 0x0D, buffer[start + 1] == 0x0A { start += 2 }
        let pending = buffer[start...]
        guard let end = pending.firstRange(of: Self.headTerminator) else {
            // The bytes may end in the first part of the terminator; only the head before it counts, so the limit
            // does not depend on how the reads split. At most 3 bytes over the limit are ever buffered.
            let partial = (1...3).last { pending.count >= $0 && pending.suffix($0).elementsEqual(Self.headTerminator.prefix($0)) } ?? 0
            if pending.count - partial > Self.maximumHeaderBytes { throw .headersTooLarge }
            return nil
        }
        guard end.lowerBound - start <= Self.maximumHeaderBytes else { throw .headersTooLarge }
        guard let head = String(data: buffer[start..<end.lowerBound], encoding: .utf8) else { throw .malformed }
        let lines = head.components(separatedBy: "\r\n")
        guard lines.count - 1 <= Self.maximumHeaderCount else { throw .headersTooLarge }
        // RFC 9112 §2.2: a bare CR or LF is not a line ending here, and inside a field it could smuggle a header.
        guard !lines.contains(where: { $0.utf8.contains { $0 == 0x0D || $0 == 0x0A } }) else { throw .malformed }
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, parts[0].allSatisfy({ $0.isASCII && $0.isUppercase }), parts[1].hasPrefix("/") else { throw .malformed }
        let version = String(parts[2])
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
            if version.hasPrefix("HTTP/") { throw .unsupportedVersion }
            throw .malformed
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw .malformed }
            let name = line[..<colon]
            // Obsolete line folding and whitespace before the colon are request-smuggling vectors.
            guard !name.isEmpty, !name.contains(where: { $0 == " " || $0 == "\t" || !$0.isASCII }) else { throw .malformed }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            let key = name.lowercased()
            if key == "content-length", let existing = headers[key], existing != value { throw .malformed }
            // RFC 9112 §3.2: more than one Host is a 400, so the Host check cannot be split.
            if key == "host", headers[key] != nil { throw .malformed }
            if headers[key] == nil { headers[key] = value }
        }
        if headers["transfer-encoding"] != nil { throw .lengthRequired }
        var length = 0
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.count <= 8, raw.allSatisfy(\.isASCII), raw.allSatisfy(\.isNumber), let value = Int(raw) else { throw .malformed }
            guard value <= Self.maximumBody else { throw .bodyTooLarge }
            length = value
        }
        let bodyStart = end.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let body = Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: length)])
        start = buffer.index(bodyStart, offsetBy: length)
        let target = String(parts[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        return MCPHTTPRequest(method: String(parts[0]), path: path, version: version, headers: headers, body: body)
    }
}
