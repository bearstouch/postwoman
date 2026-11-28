import Foundation

/// Types of HTTP authentication supported for API requests.
/// Determines how authentication credentials are included in requests.
enum AuthenticationType: String, Codable, CaseIterable, Identifiable {
    /// No authentication required
    case none = "None"

    /// Bearer token authentication (Authorization: Bearer <token>)
    case bearer = "Bearer Token"

    /// HTTP Basic authentication (Authorization: Basic <base64>)
    case basic = "Basic Auth"

    /// OAuth 2.0 authentication flow
    case oauth2 = "OAuth 2.0"

    /// Unique identifier for use in SwiftUI lists
    var id: String { rawValue }
}

/// Configuration for OAuth 2.0 authentication.
/// Contains the necessary parameters to perform OAuth 2.0 authorization flows.
struct OAuthConfig: Codable, Hashable {
    /// The OAuth 2.0 authorization endpoint URL
    var authorizationURL: String = ""

    /// The OAuth 2.0 token endpoint URL for exchanging authorization codes
    var tokenURL: String = ""

    /// The OAuth 2.0 client identifier issued by the authorization server
    var clientID: String = ""

    /// The OAuth 2.0 client secret issued by the authorization server
    var clientSecret: String = ""

    /// Space-separated list of OAuth 2.0 scopes being requested
    var scope: String = ""

    /// The redirect URI registered with the authorization server
    var redirectURI: String = ""
}
