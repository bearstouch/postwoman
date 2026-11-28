import Foundation

/// The parts of a request that sending it and generating code read. `APIRequest` and `RequestSnapshot` have them.
protocol RequestFields {
    var url: String { get }
    var method: HTTPMethod { get }
    var headers: [KeyValuePair] { get }
    var queryParams: [KeyValuePair] { get }
    var bodyType: ContentType { get }
    var bodyContent: String { get }
    var authenticationType: AuthenticationType { get }
    var authBearerToken: String? { get }
    var authBasicUsername: String? { get }
    var authBasicPassword: String? { get }
}

extension APIRequest: RequestFields {}

extension RequestFields {
    /// Whether the body goes out with the request: a body type, some content, and a method that sends a body (not HEAD).
    var sendsBody: Bool { method.sendsBody && bodyType != .none && !bodyContent.isEmpty }
}

/// A copy of a request's fields as plain values, so it can be resolved, sent and recorded without touching the model.
struct RequestSnapshot: RequestFields, Sendable, Equatable {
    var url: String
    var method: HTTPMethod
    var headers: [KeyValuePair]
    var queryParams: [KeyValuePair]
    var bodyType: ContentType
    var bodyContent: String
    var authenticationType: AuthenticationType
    var authBearerToken: String?
    var authBasicUsername: String?
    var authBasicPassword: String?

    init(_ request: some RequestFields) {
        url = request.url
        method = request.method
        headers = request.headers
        queryParams = request.queryParams
        bodyType = request.bodyType
        bodyContent = request.bodyContent
        authenticationType = request.authenticationType
        authBearerToken = request.authBearerToken
        authBasicUsername = request.authBasicUsername
        authBasicPassword = request.authBasicPassword
    }

    /// Every field with its `{{variables}}` replaced: URL, header and parameter names and values, body and credentials.
    /// With `redactSecrets`, secret variables stay as `{{name}}`.
    func resolved(with resolver: VariableResolver, redactSecrets: Bool = false) -> RequestSnapshot {
        var copy = self
        func resolve(_ text: String) -> String { resolver.resolve(text, redactSecrets: redactSecrets) }
        func resolve(_ pairs: [KeyValuePair]) -> [KeyValuePair] {
            pairs.map { pair in
                var pair = pair
                pair.key = resolve(pair.key)
                pair.value = resolve(pair.value)
                return pair
            }
        }
        copy.url = resolve(url)
        copy.headers = resolve(headers)
        copy.queryParams = resolve(queryParams)
        copy.bodyContent = resolve(bodyContent)
        copy.authBearerToken = authBearerToken.map(resolve)
        copy.authBasicUsername = authBasicUsername.map(resolve)
        copy.authBasicPassword = authBasicPassword.map(resolve)
        return copy
    }

    /// The text that is sent: the URL, enabled headers and parameters, the body (when there is one) and the
    /// credentials the auth type uses.
    var sentText: [String] {
        var texts = [url]
        for pair in headers + queryParams where pair.isEnabled { texts += [pair.key, pair.value] }
        if bodyType != .none && method.sendsBody { texts.append(bodyContent) }
        switch authenticationType {
        case .bearer: texts.append(authBearerToken ?? "")
        case .basic: texts += [authBasicUsername ?? "", authBasicPassword ?? ""]
        case .none, .oauth2: break
        }
        return texts
    }

    /// The variables the sent text uses that the resolver doesn't define, in order of appearance.
    func missingVariables(with resolver: VariableResolver) -> [String] {
        var seen: Set<String> = []
        return sentText.flatMap { resolver.missingVariables(in: $0) }.filter { seen.insert($0).inserted }
    }
}
