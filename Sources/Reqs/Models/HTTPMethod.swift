import SwiftUI

/// Supported HTTP methods for API requests.
/// Each method has an associated color for visual distinction in the UI. The raw values are stored and exported,
/// and the case order is the menu order.
enum HTTPMethod: String, Codable, CaseIterable, Identifiable {
    /// HTTP GET method - retrieves data from a resource
    case get = "GET"

    /// HTTP POST method - creates a new resource
    case post = "POST"

    /// HTTP PUT method - updates/replaces an existing resource
    case put = "PUT"

    /// HTTP PATCH method - changes part of an existing resource
    case patch = "PATCH"

    /// HTTP DELETE method - removes a resource
    case delete = "DELETE"

    /// HTTP HEAD method - a GET that returns only the status and headers
    case head = "HEAD"

    /// HTTP OPTIONS method - asks which methods and headers a resource allows (as CORS preflight does)
    case options = "OPTIONS"

    /// Unique identifier for use in SwiftUI lists
    var id: String { rawValue }

    /// Whether a request with this method carries the body it was given. GET and HEAD don't: URLSession fails a GET with a
    /// body before sending it ("resource exceeds maximum size") and waits on a HEAD with one until it times out, and
    /// `curl -I` can't send one. The body is kept on the request but not sent.
    var sendsBody: Bool { self != .get && self != .head }

    /// Color associated with each HTTP method for UI visualization. The method's name is always shown next to it.
    @MainActor var color: Color {
        switch self {
        case .get, .head: return Theme.success  // Safe read operations
        case .post: return Theme.warning  // Resource creation
        case .put, .patch: return Theme.info  // Resource updates
        case .delete: return Theme.failure  // Destructive operations
        case .options: return Theme.neutral  // Asks about the resource, changes nothing
        }
    }
}
