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

    /// Human-readable status text (e.g., "OK", "Not Found").
    var statusText: String {
        HTTPURLResponse.localizedString(forStatusCode: statusCode)
    }

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
/// Main-actor isolated because it reads SwiftData `APIRequest` models, which belong to the
/// main context; the network wait itself suspends without blocking the main thread.
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

    /// Executes an HTTP request and returns the response.
    /// This method handles the complete request lifecycle: URL construction with query parameters,
    /// header application, authentication, body encoding, and response parsing.
    ///
    /// - Parameters:
    ///   - request: The API request configuration to execute
    /// - Returns: HTTPResponse containing the server's response
    /// - Throws: HTTPClientError if the request cannot be completed
    func execute(request: APIRequest) async throws -> HTTPResponse {
        let startTime = Date()

        // Parse URL and add query parameters
        guard var urlComponents = URLComponents(string: request.url) else {
            throw HTTPClientError.invalidURL
        }

        let enabledParams = request.queryParams.filter { $0.isEnabled && !$0.key.isEmpty }
        if !enabledParams.isEmpty {
            urlComponents.queryItems = enabledParams.map {
                URLQueryItem(name: $0.key, value: $0.value)
            }
        }

        guard let url = urlComponents.url else {
            throw HTTPClientError.invalidURL
        }

        // Configure the URL request
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = 30

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
        if request.bodyType != .none && !request.bodyContent.isEmpty {
            urlRequest.httpBody = request.bodyContent.data(using: .utf8)

            // Set Content-Type header if not already set
            if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil,
                let mimeType = request.bodyType.mimeType
            {
                urlRequest.setValue(mimeType, forHTTPHeaderField: "Content-Type")
            }
        }

        // Execute the request
        let (data, response) = try await session.data(for: urlRequest)
        let endTime = Date()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPClientError.invalidResponse
        }

        return HTTPResponse(
            statusCode: httpResponse.statusCode,
            headers: parseHeaders(from: httpResponse),
            body: String(data: data, encoding: .utf8),
            responseTime: endTime.timeIntervalSince(startTime) * 1000,
            contentType: httpResponse.value(forHTTPHeaderField: "Content-Type")
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
