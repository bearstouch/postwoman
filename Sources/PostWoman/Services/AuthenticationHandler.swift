import Foundation

/// Service for applying various authentication methods to HTTP requests.
/// Handles Bearer token, Basic authentication, and provides framework for OAuth2.
class AuthenticationHandler {
    /// Applies the specified authentication method to an HTTP request.
    /// Modifies the request's Authorization header based on the authentication type.
    ///
    /// - Parameters:
    ///   - authenticationType: The type of authentication to apply
    ///   - bearerToken: Bearer token for Bearer authentication
    ///   - basicUsername: Username for Basic authentication
    ///   - basicPassword: Password for Basic authentication
    ///   - request: The URLRequest to modify (inout parameter)
    func apply(
        authenticationType: AuthenticationType,
        bearerToken: String?,
        basicUsername: String?,
        basicPassword: String?,
        to request: inout URLRequest
    ) {
        switch authenticationType {
        case .none:
            // No authentication required
            break

        case .bearer:
            // Apply Bearer token authentication: Authorization: Bearer <token>
            guard let token = bearerToken, !token.isEmpty else { return }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        case .basic:
            // Apply HTTP Basic authentication: Authorization: Basic <base64(username:password)>
            guard let username = basicUsername,
                let password = basicPassword
            else { return }
            let credentials = "\(username):\(password)"
            guard let data = credentials.data(using: .utf8) else { return }
            let base64Credentials = data.base64EncodedString()
            request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")

        case .oauth2:
            // OAuth2 implementation would require:
            // - ASWebAuthenticationSession for authorization flow
            // - Token storage and refresh logic
            // - Scope handling and token expiration
            // Currently not implemented
            break
        }
    }
}
