import Foundation

/// Generates cURL command-line equivalents from API request configurations.
/// Produces properly formatted, executable cURL commands that replicate the
/// HTTP request with all headers, authentication, and body content.
struct CURLGenerator {
    /// Generates a cURL command string that replicates the given API request.
    /// The generated command includes method, URL with query parameters, headers,
    /// authentication, and request body.
    ///
    /// - Parameters:
    ///   - request: The API request to convert to cURL
    /// - Returns: A formatted cURL command string with proper line continuation
    func generate(from request: some RequestFields) -> String {
        var parts: [String] = ["curl"]

        // Print a streamed response as it arrives
        if request.expectsStream {
            parts.append("-N")
        }

        // cURL defaults to GET, but switches to POST for a body, so a GET with a body is spelled out too. HEAD is -I:
        // with -X HEAD, curl waits for a body that never comes.
        let hasBody = request.sendsBody
        if request.method == .head {
            parts.append("-I")
        } else if request.method != .get || hasBody {
            parts.append("-X \(request.method.rawValue)")
        }

        parts.append(quoted(urlWithParams(request)))

        // Authentication, as the app applies it: a bearer token or Basic credentials replace an Authorization header.
        var authentication: String?
        switch request.authenticationType {
        case .bearer:
            if let token = request.authBearerToken, !token.isEmpty { authentication = "-H " + quoted("Authorization: Bearer \(token)") }
        case .basic:
            if let (username, password) = AuthenticationHandler.basicCredentials(username: request.authBasicUsername, password: request.authBasicPassword) {
                authentication = "-u " + quoted("\(username):\(password)")
            }
        default:
            break
        }

        // The app sends each header name once, with its last value; curl would send every -H line, and with a written
        // Authorization header would ignore -u.
        let enabledHeaders = request.headers.filter { $0.isEnabled && !$0.key.isEmpty }
        for (index, header) in enabledHeaders.enumerated() {
            let name = header.key.lowercased()
            if enabledHeaders[(index + 1)...].contains(where: { $0.key.lowercased() == name }) { continue }
            if authentication != nil, name == "authorization" { continue }
            parts.append("-H " + quoted("\(header.key): \(header.value)"))
        }
        if let authentication { parts.append(authentication) }

        // Add request body if present
        if hasBody, let fields = MultipartForm.fields(of: request) {
            // --form-string, not -F: a value starting with @ or < is sent as written, not read from a file. curl adds the
            // multipart Content-Type and its boundary.
            for field in fields { parts.append("--form-string " + quoted("\(field.key)=\(field.value)")) }
        } else if hasBody {
            // --data-raw, not -d: with -d a body that starts with @ names a file to upload.
            parts.append("--data-raw " + quoted(request.bodyContent))

            // Add Content-Type header if not already specified
            if request.headers.first(where: { $0.key.lowercased() == "content-type" && $0.isEnabled }) == nil,
                let mimeType = request.bodyType.mimeType
            {
                parts.append("-H 'Content-Type: \(mimeType)'")
            }
        }

        // Join parts with line continuation for readability
        return parts.joined(separator: " \\\n  ")
    }

    /// Characters a query name or value keeps as written: `.urlQueryAllowed` without the separators `&`, `=`, `+` and `#`,
    /// so `a&b=c` stays one value and `a+b` is not read as `a b`.
    private static let queryComponentAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))

    /// The URL as the app sends it (`RequestURL.encoded`), with the enabled params appended to its query (`&`, or `?` when it has none; nothing after a bare `?`)
    /// and before any `#fragment`, as `HTTPClient` sends it.
    private func urlWithParams(_ request: some RequestFields) -> String {
        let url = RequestURL.encoded(request.url)
        let enabledParams = request.queryParams.filter { $0.isEnabled && !$0.key.isEmpty }
        guard !enabledParams.isEmpty else { return url }
        let encode = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: Self.queryComponentAllowed) ?? text }
        let query = enabledParams.map { "\(encode($0.key))=\(encode($0.value))" }.joined(separator: "&")
        let fragmentStart = url.firstIndex(of: "#") ?? url.endIndex
        let base = url[..<fragmentStart]
        let separator = base.hasSuffix("?") ? "" : base.contains("?") ? "&" : "?"
        return base + separator + query + url[fragmentStart...]
    }

    /// Wraps `text` in single quotes for a POSIX shell, so nothing in it expands; each `'` is closed, escaped and reopened (`'\''`).
    private func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
