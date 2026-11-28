import Foundation

/// The parts of a request that sending it and generating code read. `APIRequest` and `RequestSnapshot` have them.
protocol RequestFields {
    var url: String { get }
    var method: HTTPMethod { get }
    var headers: [KeyValuePair] { get }
    var queryParams: [KeyValuePair] { get }
    var bodyType: ContentType { get }
    var bodyContent: String { get }
    var bodyFile: Data? { get }
    var bodyFileName: String? { get }
    var authenticationType: AuthenticationType { get }
    var authBearerToken: String? { get }
    var authBasicUsername: String? { get }
    var authBasicPassword: String? { get }
}

extension APIRequest: RequestFields {}

extension RequestFields {
    /// Whether the body goes out with the request: a body type, some content (for File, an attached file, even an empty
    /// one), and a method that sends a body (not GET or HEAD).
    var sendsBody: Bool {
        guard method.sendsBody else { return false }
        switch bodyType {
        case .none: return false
        case .file: return bodyFile != nil
        default: return !bodyContent.isEmpty
        }
    }

    /// Whether generated code sends a file: a File body the method sends, with a file or at least its name (code reads
    /// the file by name, so a request restored from History or imported still gets it).
    var generatesFileBody: Bool { method.sendsBody && bodyType == .file && (bodyFile != nil || !(bodyFileName ?? "").isEmpty) }

    /// A File body the method would send but that has no bytes: sending it fails instead of going out empty.
    var lacksBodyFile: Bool { method.sendsBody && bodyType == .file && bodyFile == nil }

    /// The Content-Type the body is sent with unless a header names one: a file's from its name, else the body type's.
    var bodyMIMEType: String? { bodyType == .file ? FileBody.mimeType(forFileName: bodyFileName) : bodyType.mimeType }
}

/// A copy of a request's fields as plain values, so it can be resolved, sent and recorded without touching the model.
struct RequestSnapshot: RequestFields, Sendable, Equatable {
    var url: String
    var method: HTTPMethod
    var headers: [KeyValuePair]
    var queryParams: [KeyValuePair]
    var bodyType: ContentType
    var bodyContent: String
    var bodyFile: Data?
    var bodyFileName: String?
    var authenticationType: AuthenticationType
    var authBearerToken: String?
    var authBasicUsername: String?
    var authBasicPassword: String?

    /// `includingFile: false` leaves `bodyFile` nil without reading it: a File body's bytes live beside the store, and
    /// the Preview, which redraws on every edit, needs only their size.
    init(_ request: some RequestFields, includingFile: Bool = true) {
        url = request.url
        method = request.method
        headers = request.headers
        queryParams = request.queryParams
        bodyType = request.bodyType
        bodyContent = request.bodyContent
        bodyFile = includingFile ? request.bodyFile : nil
        bodyFileName = request.bodyFileName
        authenticationType = request.authenticationType
        authBearerToken = request.authBearerToken
        authBasicUsername = request.authBasicUsername
        authBasicPassword = request.authBasicPassword
    }

    /// Every field with its `{{variables}}` replaced: URL, header and parameter names and values, body and credentials.
    /// With `redactSecrets`, secret variables stay as `{{name}}`. A file's bytes are sent as they are.
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
        copy.bodyContent = MultipartForm.encodes(self) ? MultipartForm.resolved(bodyContent, with: resolve) : resolve(bodyContent)
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
        if bodyType != .none && bodyType != .file && method.sendsBody { texts.append(bodyContent) }
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
