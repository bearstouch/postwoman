import Foundation

/// The request as it goes on the wire, for the Preview tab: request line, headers, blank line, body. It is built from
/// the same `URLRequest` `HTTPClient` sends, so it can't drift from what is sent. Credentials from the Auth tab are
/// masked and secret variables stay `{{name}}` (the caller resolves with `redactSecrets`). Main actor, as `HTTPClient` is.
@MainActor
enum RequestPreview {
    /// The fixed multipart boundary the preview shows; a send uses a fresh random one of the same length
    /// (`MultipartForm.makeBoundary`), so Content-Length is what is sent.
    static let boundary = "Reqs-00000000-0000-0000-0000-000000000000"

    /// Text bodies longer than this (UTF-8 bytes) are cut, so a large body doesn't stall the tab.
    static let maximumBodyBytes = 100_000

    /// Shown instead of a preview when the URL can't be sent.
    static let invalidURLMessage = "Enter a full URL, such as https://api.example.com/users, to see the request."

    /// What the preview leaves out, in one line under it; `footnoteDetail` is its help.
    static let footnote = "Credentials are masked and secrets shown as {{name}}. URLSession adds a few headers of its own."

    static let footnoteDetail =
        "Credentials from the Auth tab are masked and secret variables are shown as {{name}} (percent-encoded in the URL), so Content-Length counts the names, not the values. URLSession also adds Accept, Accept-Encoding, Accept-Language, Connection and User-Agent unless the request sets them, and over HTTPS may send the request as HTTP/2."

    /// The preview, or why there is none.
    enum Outcome: Equatable {
        case request(String)
        case invalidURL
    }

    /// The preview of a saved request on every redraw: a File body is described from its name and size, without
    /// loading its bytes from the store.
    static func make(_ request: APIRequest, resolver: VariableResolver) -> Outcome {
        var snapshot = RequestSnapshot(request, includingFile: false).resolved(with: resolver, redactSecrets: true)
        if request.bodyFileSize != nil { snapshot.bodyFile = Data() }
        return make(snapshot, fileSize: request.bodyFileSize)
    }

    /// The preview of `request`. `fileSize` is the size of a File body whose `bodyFile` is a placeholder; nil uses the bytes.
    static func make(_ request: some RequestFields, fileSize: Int? = nil) -> Outcome {
        guard !request.url.trimmingCharacters(in: .whitespaces).isEmpty,
            let urlRequest = try? HTTPClient.urlRequest(for: withoutMissingFile(request), timeout: 30, boundary: boundary),
            let url = urlRequest.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = components.host, !host.isEmpty
        else { return .invalidURL }

        var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { target += "?" + query }
        var lines = ["\(request.method.rawValue) \(target) HTTP/1.1"]
        // The host as it goes on the wire: punycode for a name (bücher.de → xn--bcher-kva.de), and an IPv6 address without
        // its zone (`%25en0`), which only routes the connection.
        var wireHost = components.encodedHost ?? host
        if wireHost.hasPrefix("["), let zone = wireHost.range(of: "%25") { wireHost = wireHost[..<zone.lowerBound] + "]" }
        let hostHeader = wireHost + (components.port.map { ":\($0)" } ?? "")
        lines.append("Host: \(hostHeader)")
        // Host and Content-Length are URLSession's to send: the request's own values are replaced, not added.
        for (name, value) in orderedHeaders(urlRequest, request: request)
        where name.caseInsensitiveCompare("Host") != .orderedSame && name.caseInsensitiveCompare("Content-Length") != .orderedSame {
            lines.append("\(name): \(value)")
        }
        if let body = urlRequest.httpBody { lines.append("Content-Length: \(fileSize ?? body.count)") }
        lines.append("")
        if request.lacksBodyFile {
            lines.append("[No file attached. \(FileBody.missingFileMessage(fileName: request.bodyFileName))]")
        } else if let body = urlRequest.httpBody {
            lines.append(bodyText(body, request: request, fileSize: fileSize))
        }
        return .request(lines.joined(separator: "\n"))
    }

    /// The headers in the order the request lists them (each name once, with the value sent), then those Reqs adds
    /// (Authorization from the Auth tab, Content-Type from the body type). Auth credentials are masked.
    static func orderedHeaders(_ urlRequest: URLRequest, request: some RequestFields) -> [(String, String)] {
        let sent = urlRequest.allHTTPHeaderFields ?? [:]
        var seen: Set<String> = []
        var names: [String] = []
        for pair in request.headers where pair.isEnabled && !pair.key.isEmpty {
            if seen.insert(pair.key.lowercased()).inserted { names.append(pair.key) }
        }
        names += sent.keys.filter { !seen.contains($0.lowercased()) }.sorted()
        return names.compactMap { name in
            guard let value = sent.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value else { return nil }
            if name.caseInsensitiveCompare("Authorization") == .orderedSame, let masked = maskedAuthorization(request) { return (name, masked) }
            return (name, value)
        }
    }

    /// The Authorization value the Auth tab sends, with its credentials masked (a `{{secret}}` stays readable), or nil
    /// when the Auth tab sends none (the header, if any, is the request's own).
    static func maskedAuthorization(_ request: some RequestFields) -> String? {
        switch request.authenticationType {
        case .bearer:
            guard let token = request.authBearerToken, !token.isEmpty else { return nil }
            return "Bearer " + HistoryDetailView.masked(token)
        case .basic:
            guard let (username, password) = AuthenticationHandler.basicCredentials(username: request.authBasicUsername, password: request.authBasicPassword)
            else { return nil }
            return "Basic " + String(repeating: "•", count: Data("\(username):\(password)".utf8).base64EncodedString().count)
        case .none, .oauth2:
            return nil
        }
    }

    /// The body as text; a file or bytes that aren't UTF-8 as a one-line description instead.
    static func bodyText(_ body: Data, request: some RequestFields, fileSize: Int? = nil) -> String {
        if request.bodyType == .file {
            return "[File: \(request.bodyFileName ?? "Unnamed file") · \(FileBody.formattedSize(fileSize ?? body.count))]"
        }
        let shown = body.prefix(maximumBodyBytes)
        // A cut can land inside a character of up to 4 bytes: drop up to 3 bytes until the rest decodes.
        let dropped = shown.count < body.count ? 0...3 : 0...0
        guard let text = dropped.lazy.compactMap({ String(data: shown.dropLast($0), encoding: .utf8) }).first else {
            return "[\(FileBody.formattedSize(body.count)) of binary data]"
        }
        let rest = body.count - Data(text.utf8).count
        return rest > 0 ? text + "\n… \(FileBody.formattedSize(rest)) more" : text
    }

    /// `request` with a missing File body left out, so the rest still previews (the body says the file is missing).
    private static func withoutMissingFile(_ request: some RequestFields) -> RequestSnapshot {
        var snapshot = RequestSnapshot(request)
        if snapshot.lacksBodyFile { snapshot.bodyType = .none }
        return snapshot
    }
}
