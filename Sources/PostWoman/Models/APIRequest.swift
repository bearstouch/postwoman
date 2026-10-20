import SwiftData
import Foundation

/// Represents a complete HTTP API request configuration.
/// Contains all the information needed to make an HTTP request including URL, method,
/// headers, body, authentication, and query parameters. Supports environment variable
/// substitution via {{variable}} syntax in URLs, headers, and body content.
@Model
final class APIRequest {
    /// Unique identifier for the request.
    var id: UUID

    /// Display name for the request as shown in the UI.
    var name: String

    /// The target URL for the HTTP request. Supports {{variable}} substitution.
    var url: String

    /// The HTTP method (GET, POST, PUT, etc.) for the request.
    var method: HTTPMethod

    /// Timestamp when the request was first created.
    var createdAt: Date

    /// Timestamp when the request was last modified.
    var updatedAt: Date

    /// Sort order for displaying requests within their folder.
    var sortOrder: Int

    /// HTTP headers as key-value pairs. Supports {{variable}} substitution in values.
    var headers: [KeyValuePair]

    /// Query parameters as key-value pairs. Supports {{variable}} substitution in values.
    var queryParams: [KeyValuePair]

    /// The content type for the request body.
    var bodyType: ContentType

    /// The raw body content. Supports {{variable}} substitution.
    var bodyContent: String

    /// The type of authentication to use for this request.
    var authenticationType: AuthenticationType

    /// Bearer token for authentication (used when authenticationType is .bearer).
    var authBearerToken: String?

    /// Username for basic authentication (used when authenticationType is .basic).
    var authBasicUsername: String?

    /// Password for basic authentication (used when authenticationType is .basic).
    var authBasicPassword: String?

    /// OAuth configuration (used when authenticationType is .oauth).
    var authOAuthConfig: OAuthConfig?

    /// The folder that contains this request. Nil for requests not in any folder.
    var folder: Folder?

    /// Creates a new API request with default values.
    /// - Parameters:
    ///   - name: Display name for the request
    ///   - url: Target URL (defaults to empty string)
    ///   - method: HTTP method (defaults to GET)
    ///   - folder: Parent folder (defaults to nil)
    init(
        name: String,
        url: String = "",
        method: HTTPMethod = .get,
        folder: Folder? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.url = url
        self.method = method
        self.createdAt = Date()
        self.updatedAt = Date()
        self.sortOrder = 0
        self.headers = []
        self.queryParams = []
        self.bodyType = .none
        self.bodyContent = ""
        self.authenticationType = .none
        self.folder = folder
    }
}
