import Foundation
import SwiftData

/// A historical record of an executed API request and its response.
/// Stores a snapshot of the request as it was sent and the response it got, so the History view
/// can show both and the request can be restored into a new one.
@Model
final class RequestHistory {
    /// Unique identifier for this history entry.
    var id: UUID

    /// When the request was executed.
    var timestamp: Date

    /// The URL that was requested, without the query parameters in `queryParams`.
    var url: String

    /// The HTTP method used for the request.
    var method: HTTPMethod

    /// HTTP headers sent with the request.
    var requestHeaders: [KeyValuePair]

    /// The request body content, if any.
    var requestBody: String?

    /// The name of the saved request this was sent from. Nil in older entries.
    var requestName: String?

    /// Query parameters sent with the request.
    var queryParams: [KeyValuePair]?

    /// The content type of the request body.
    var bodyType: ContentType?

    /// The authentication the request used, and its credentials.
    var authenticationType: AuthenticationType?
    var authBearerToken: String?
    var authBasicUsername: String?
    var authBasicPassword: String?

    /// HTTP status code from the response (e.g., 200, 404, 500).
    var statusCode: Int?

    /// HTTP headers received in the response.
    var responseHeaders: [KeyValuePair]?

    /// The response body content.
    var responseBody: String?

    /// The response's `Content-Type` header.
    var responseContentType: String?

    /// Time taken to receive the response, in milliseconds.
    var responseTime: Double?

    /// Size of the response body in bytes.
    var responseSize: Int?

    /// The encoded `ResponseTiming` of the response, when URLSession reported one.
    var responseTimingData: Data?

    /// The encoded `StreamInfo` of a streamed response (its events, assembled text and how it ended).
    var responseStreamData: Data?

    /// Error message if the request failed.
    var errorMessage: String?

    /// Whether the request completed successfully (status code 200-299).
    var wasSuccessful: Bool

    /// ID of the saved request this history entry corresponds to, if any.
    /// Used to link history entries back to their originating saved request.
    var savedRequestID: UUID?

    /// The collection environment its `{{variables}}` were resolved with ("Default" when only Default applied).
    /// Nil for entries recorded without one.
    var environmentName: String?

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

    /// Creates a history entry for `request` as it is about to be sent.
    /// - Parameters:
    ///   - sent: What is sent: the request resolved with its environment, secrets left as `{{name}}`.
    ///     Defaults to the request as it is.
    ///   - environmentName: The environment it was resolved with.
    convenience init(request: APIRequest, sent: RequestSnapshot? = nil, environmentName: String? = nil) {
        let sent = sent ?? RequestSnapshot(request)
        self.init(
            url: sent.url,
            method: sent.method,
            requestHeaders: sent.headers,
            requestBody: sent.bodyContent.isEmpty || !sent.method.sendsBody ? nil : sent.bodyContent
        )
        requestName = request.name
        queryParams = sent.queryParams
        bodyType = sent.method.sendsBody ? sent.bodyType : ContentType.none
        authenticationType = sent.authenticationType
        authBearerToken = sent.authBearerToken
        authBasicUsername = sent.authBasicUsername
        authBasicPassword = sent.authBasicPassword
        savedRequestID = request.id
        self.environmentName = environmentName
    }

    /// Records the response the request got.
    func record(_ response: HTTPResponse) {
        statusCode = response.statusCode
        responseHeaders = response.headers
        responseBody = response.body
        responseContentType = response.contentType
        responseTime = response.responseTime
        responseSize = response.bodySize ?? response.body?.utf8.count
        responseTimingData = response.timing.flatMap { try? JSONEncoder().encode($0) }
        responseStreamData = response.stream.flatMap { try? JSONEncoder().encode($0) }
        wasSuccessful = response.isSuccess
        errorMessage = nil
    }

    /// Records that the request failed without a response.
    func record(_ error: Error) {
        errorMessage = error.localizedDescription
        wasSuccessful = false
    }

    /// The recorded response, as the response viewer shows it; an error response when the request failed.
    var response: HTTPResponse? {
        if let errorMessage, statusCode == nil {
            return HTTPResponse(statusCode: 0, headers: [], body: "Error: \(errorMessage)", responseTime: 0, contentType: nil)
        }
        guard let statusCode else { return nil }
        let headers = responseHeaders ?? []
        let headerFields = Dictionary(headers.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        return HTTPResponse(
            statusCode: statusCode,
            headers: headers,
            body: responseBody,
            responseTime: responseTime ?? 0,
            contentType: responseContentType
                ?? headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value,
            cookies: URL(string: url).map { ResponseCookie.parse(headerFields: headerFields, url: $0) } ?? [],
            timing: responseTimingData.flatMap { try? JSONDecoder().decode(ResponseTiming.self, from: $0) },
            bodySize: responseSize,
            stream: responseStreamData.flatMap { try? JSONDecoder().decode(StreamInfo.self, from: $0) }
        )
    }

    /// A new, unsaved request with this entry's request configuration.
    func makeRequest(folder: Folder? = nil) -> APIRequest {
        let request = APIRequest(name: requestName ?? url, url: url, method: method, folder: folder)
        request.headers = requestHeaders
        request.queryParams = queryParams ?? []
        if let requestBody {
            request.bodyContent = requestBody
            request.bodyType = bodyType ?? .json
        }
        request.authenticationType = authenticationType ?? .none
        request.authBearerToken = authBearerToken
        request.authBasicUsername = authBasicUsername
        request.authBasicPassword = authBasicPassword
        return request
    }
}
