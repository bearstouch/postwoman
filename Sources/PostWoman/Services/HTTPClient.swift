import Foundation

/// Represents the response from an HTTP request.
/// Contains all relevant information about the server's response including
/// status, headers, body content, and performance metrics.
struct HTTPResponse {
    /// HTTP status code (e.g., 200, 404, 500).
    let statusCode: Int

    /// Response headers as key-value pairs.
    let headers: [KeyValuePair]

    /// Response body content as a string, if available.
    let body: String?

    /// Time taken for the request in milliseconds.
    let responseTime: Double

    /// Content-Type header value from the response.
    let contentType: String?

    /// Cookies the response set with `Set-Cookie`.
    var cookies: [ResponseCookie] = []

    /// Where the time went (DNS, connect, TLS, waiting, download), when URLSession reported it.
    var timing: ResponseTiming?

    /// The body's size in bytes as received; nil when unknown.
    var bodySize: Int?

    /// For a streamed body (server-sent events, NDJSON): its events, assembled LLM text and how it ended.
    var stream: StreamInfo?

    /// Human-readable status text (e.g., "OK", "Not Found"). Foundation's localized strings are lowercase and
    /// say "no error" for 200, so common codes use their standard reason phrases.
    var statusText: String {
        Self.reasonPhrases[statusCode] ?? HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized
    }

    private static let reasonPhrases: [Int: String] = [
        200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 206: "Partial Content",
        301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect",
        400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable",
        408: "Request Timeout", 409: "Conflict", 410: "Gone", 413: "Content Too Large", 415: "Unsupported Media Type",
        422: "Unprocessable Content", 429: "Too Many Requests",
        500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout"
    ]

    /// Whether the response indicates success (status code 200-299).
    var isSuccess: Bool {
        (200..<300).contains(statusCode)
    }

    /// Creates an error response for failed requests.
    /// - Parameter error: The error that occurred
    /// - Returns: An HTTPResponse representing the error
    static func error(_ error: Error) -> HTTPResponse {
        HTTPResponse(
            statusCode: 0,
            headers: [],
            body: "Error: \(error.localizedDescription)",
            responseTime: 0,
            contentType: nil
        )
    }
}

/// Errors that can occur during HTTP request execution.
/// Provides localized error messages for user display.
enum HTTPClientError: LocalizedError {
    /// The provided URL string could not be parsed into a valid URL.
    case invalidURL

    /// The server response was not a valid HTTP response.
    case invalidResponse

    /// A network or connection error occurred.
    case networkError(Error)

    /// Human-readable error description for display in the UI.
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid response from server"
        case .networkError(let error): return error.localizedDescription
        }
    }
}

/// Executes HTTP requests: URL construction, authentication, and response parsing.
/// Main-actor isolated because it can read SwiftData `APIRequest` models, which belong to the
/// main context; the network wait itself suspends without blocking the main thread. Callers send a
/// `RequestSnapshot` resolved with the collection's environment.
@MainActor
final class HTTPClient {
    /// The URLSession used for network requests.
    private let session: URLSession

    /// Service for applying authentication to requests.
    private let authHandler = AuthenticationHandler()

    /// Creates a new HTTP client with the specified URLSession.
    /// - Parameter session: URLSession to use for requests (defaults to shared session)
    init(session: URLSession = .shared) {
        self.session = session
    }

    /// How often `onProgress` hears about a stream, at most.
    private static let progressInterval: TimeInterval = 0.1

    /// Executes an HTTP request and returns the response.
    /// This method handles the complete request lifecycle: URL construction with query parameters,
    /// header application, authentication, body encoding, and response parsing.
    ///
    /// A streamed response (`text/event-stream`, NDJSON) is parsed into events as it arrives, and `onProgress`
    /// gets the response so far, about ten times a second. Cancelling the calling task while a stream arrives
    /// returns what was received, with `stream.end == .stopped`; a connection lost part way returns it with `.failed`.
    ///
    /// - Parameters:
    ///   - request: The request to send, as it is: `{{variables}}` are sent as written, so resolve them first
    ///   - onProgress: Called with the partial response of a stream while it arrives
    /// - Returns: HTTPResponse containing the server's response
    /// - Throws: HTTPClientError if the request cannot be completed
    func execute(request: some RequestFields, onProgress: (@MainActor (HTTPResponse) -> Void)? = nil) async throws -> HTTPResponse {
        let urlRequest = try makeURLRequest(request)
        let url = urlRequest.url!
        let startTime = Date()
        func elapsed() -> Double { Date().timeIntervalSince(startTime) * 1000 }

        let delegate = StreamingTaskDelegate()
        let task = session.dataTask(with: urlRequest)
        task.delegate = delegate
        delegate.onTermination { task.cancel() }

        var httpResponse: HTTPURLResponse?
        var data = Data()
        var stream: StreamInfo?
        var parser: StreamEventParser?
        var assembler = StreamTextAssembler()
        var lastProgress = Date.distantPast

        func absorb(_ events: [StreamEvent]) {
            for event in events { assembler.add(event) }
            stream?.events.append(contentsOf: events)
            stream?.text = assembler.text
            stream?.firstTextTime = assembler.firstTextTime
        }
        func snapshot(_ response: HTTPURLResponse, timing: ResponseTiming?) -> HTTPResponse {
            makeResponse(response, data: data, url: url, total: timing?.total ?? elapsed(), timing: timing, stream: stream)
        }

        do {
            try await withTaskCancellationHandler {
                task.resume()
                for try await event in delegate.events {
                    switch event {
                    case .response(let response):
                        guard let response = response as? HTTPURLResponse else { throw HTTPClientError.invalidResponse }
                        httpResponse = response
                        data = Data()
                        // A HEAD response describes a stream it doesn't carry, so it isn't one.
                        if request.method != .head, let kind = StreamKind(contentType: response.value(forHTTPHeaderField: "Content-Type")) {
                            stream = StreamInfo(kind: kind)
                            parser = StreamEventParser(kind: kind)
                            assembler = StreamTextAssembler()
                            onProgress?(snapshot(response, timing: nil))
                            lastProgress = Date()
                        }
                    case .data(let chunk):
                        data.append(chunk)
                        guard let response = httpResponse, stream != nil else { continue }
                        let time = elapsed()
                        if stream?.firstByteTime == nil { stream?.firstByteTime = time }
                        if let events = parser?.feed(chunk, time: time) { absorb(events) }
                        if Date().timeIntervalSince(lastProgress) >= Self.progressInterval {
                            onProgress?(snapshot(response, timing: nil))
                            lastProgress = Date()
                        }
                    }
                }
                // A cancelled consumer's stream ends without an error.
                try Task.checkCancellation()
            } onCancel: {
                task.cancel()
            }
            stream?.end = .completed
        } catch {
            // Without the headers, or for a response that isn't a stream, it failed as before.
            guard httpResponse != nil, stream != nil else { throw error }
            let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            stream?.end = cancelled ? .stopped : .failed(error.localizedDescription)
        }

        guard let httpResponse else { throw HTTPClientError.invalidResponse }
        if let events = parser?.finish(time: elapsed()) { absorb(events) }
        return snapshot(httpResponse, timing: delegate.timing)
    }

    /// The enabled params as an encoded query (`a=1&b=2`), appended to the URL's own query, which is kept as written;
    /// nil when no param is enabled. Names and values are percent-encoded, `+ & = #` included: servers read a bare `+` as a space.
    static func encodedQuery(_ params: [KeyValuePair]) -> String? {
        let enabled = params.filter { $0.isEnabled && !$0.key.isEmpty }
        guard !enabled.isEmpty else { return nil }
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? text }
        return enabled.map { encode($0.key) + "=" + encode($0.value) }.joined(separator: "&")
    }

    /// What a query name or value may hold unencoded: `.urlQueryAllowed` without the separators `&` `=` `#` and `+`.
    private static let queryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))

    /// The URLRequest for `request`: its URL with the enabled query parameters, headers, authentication and body.
    private func makeURLRequest(_ request: some RequestFields) throws -> URLRequest {
        // Parse URL and add query parameters
        guard var urlComponents = URLComponents(string: RequestURL.encoded(request.url)) else {
            throw HTTPClientError.invalidURL
        }

        if let params = Self.encodedQuery(request.queryParams) {
            let existing = urlComponents.percentEncodedQuery ?? ""
            urlComponents.percentEncodedQuery = existing.isEmpty ? params : existing + "&" + params
        }

        guard let url = urlComponents.url else {
            throw HTTPClientError.invalidURL
        }

        // Configure the URL request. The timeout is the longest wait between packets, so long streams are fine.
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = 30
        // Send means ask the server: never answer from URLCache, which would show a cacheable response again as if fresh.
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData

        // Apply headers
        for header in request.headers where header.isEnabled && !header.key.isEmpty {
            urlRequest.setValue(header.value, forHTTPHeaderField: header.key)
        }

        // Apply authentication
        authHandler.apply(
            authenticationType: request.authenticationType,
            bearerToken: request.authBearerToken,
            basicUsername: request.authBasicUsername,
            basicPassword: request.authBasicPassword,
            to: &urlRequest
        )

        // Set request body if present
        if request.sendsBody, let fields = MultipartForm.fields(of: request) {
            let boundary = MultipartForm.makeBoundary()
            urlRequest.httpBody = MultipartForm.body(fields, boundary: boundary)
            urlRequest.setValue(MultipartForm.contentType(boundary: boundary), forHTTPHeaderField: "Content-Type")
        } else if request.sendsBody {
            urlRequest.httpBody = request.bodyContent.data(using: .utf8)

            // Set Content-Type header if not already set
            if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil,
                let mimeType = request.bodyType.mimeType
            {
                urlRequest.setValue(mimeType, forHTTPHeaderField: "Content-Type")
            }
        }
        return urlRequest
    }

    private func makeResponse(_ response: HTTPURLResponse, data: Data, url: URL, total: Double, timing: ResponseTiming?, stream: StreamInfo?) -> HTTPResponse {
        let headers = parseHeaders(from: response)
        let headerFields = Dictionary(headers.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        return HTTPResponse(
            statusCode: response.statusCode,
            headers: headers,
            // A stream can stop mid-character, so decode it leniently.
            body: stream == nil ? String(data: data, encoding: .utf8) : String(decoding: data, as: UTF8.self),
            responseTime: total,
            contentType: response.value(forHTTPHeaderField: "Content-Type"),
            cookies: ResponseCookie.parse(headerFields: headerFields, url: response.url ?? url),
            timing: timing,
            bodySize: data.count,
            stream: stream
        )
    }

    /// Parses HTTP response headers into KeyValuePair objects.
    /// Converts the raw header dictionary from URLResponse into a more usable format.
    ///
    /// - Parameter response: The HTTPURLResponse containing headers to parse
    /// - Returns: Array of KeyValuePair objects representing the headers
    private func parseHeaders(from response: HTTPURLResponse) -> [KeyValuePair] {
        response.allHeaderFields.compactMap { key, value in
            guard let keyString = key as? String,
                let valueString = value as? String
            else { return nil }
            return KeyValuePair(key: keyString, value: valueString)
        }
    }
}
