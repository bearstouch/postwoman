import SwiftData
import Foundation

/// A historical record of an executed API request and its response.
/// Stores complete request/response data for debugging, auditing, and reuse.
/// Used to populate the History view and provide request replay functionality.
@Model
final class RequestHistory {
    /// Unique identifier for this history entry.
    var id: UUID

    /// When the request was executed.
    var timestamp: Date

    /// The URL that was requested.
    var url: String

    /// The HTTP method used for the request.
    var method: HTTPMethod

    /// HTTP headers sent with the request.
    var requestHeaders: [KeyValuePair]

    /// The request body content, if any.
    var requestBody: String?

    /// HTTP status code from the response (e.g., 200, 404, 500).
    var statusCode: Int?

    /// HTTP headers received in the response.
    var responseHeaders: [KeyValuePair]?

    /// The response body content.
    var responseBody: String?

    /// Time taken to receive the response in seconds.
    var responseTime: Double?

    /// Size of the response body in bytes.
    var responseSize: Int?

    /// Error message if the request failed.
    var errorMessage: String?

    /// Whether the request completed successfully (status code 200-299).
    var wasSuccessful: Bool

    /// ID of the saved request this history entry corresponds to, if any.
    /// Used to link history entries back to their originating saved request.
    var savedRequestID: UUID?

    /// Creates a new request history entry for a request about to be executed.
    /// Response fields are populated after the request completes.
    /// - Parameters:
    ///   - url: The target URL
    ///   - method: The HTTP method
    ///   - requestHeaders: Headers sent with the request
    ///   - requestBody: Request body content, if any
    init(
        url: String,
        method: HTTPMethod,
        requestHeaders: [KeyValuePair] = [],
        requestBody: String? = nil
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.url = url
        self.method = method
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.wasSuccessful = false
    }
}
