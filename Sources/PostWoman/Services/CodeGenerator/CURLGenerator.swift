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

        // Add HTTP method if not GET (cURL defaults to GET)
        if request.method != .get {
            parts.append("-X \(request.method.rawValue)")
        }

        // Build URL
        var urlWithParams = request.url

        // Add query parameters to URL
        let enabledParams = request.queryParams.filter { $0.isEnabled && !$0.key.isEmpty }
        if !enabledParams.isEmpty {
            let queryString = enabledParams.map { param in
                let key = param.key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? param.key
                let value = param.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? param.value
                return "\(key)=\(value)"
            }.joined(separator: "&")

            urlWithParams += (request.url.contains("?") ? "&" : "?") + queryString
        }

        parts.append(quoted(urlWithParams))

        // Add HTTP headers
        for header in request.headers where header.isEnabled && !header.key.isEmpty {
            parts.append("-H " + quoted("\(header.key): \(header.value)"))
        }

        // Add authentication
        switch request.authenticationType {
        case .bearer:
            if let token = request.authBearerToken, !token.isEmpty {
                parts.append("-H " + quoted("Authorization: Bearer \(token)"))
            }
        case .basic:
            if let username = request.authBasicUsername,
                let password = request.authBasicPassword
            {
                parts.append("-u " + quoted("\(username):\(password)"))
            }
        default:
            break
        }

        // Add request body if present
        if request.bodyType != .none && !request.bodyContent.isEmpty {
            parts.append("-d " + quoted(request.bodyContent))

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

    /// Wraps `text` in single quotes for a POSIX shell, so nothing in it expands; each `'` is closed, escaped and reopened (`'\''`).
    private func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
