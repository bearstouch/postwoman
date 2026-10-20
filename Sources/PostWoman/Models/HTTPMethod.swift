import SwiftUI

/// Supported HTTP methods for API requests.
/// Each method has an associated color for visual distinction in the UI.
enum HTTPMethod: String, Codable, CaseIterable, Identifiable {
    /// HTTP GET method - retrieves data from a resource
    case get = "GET"

    /// HTTP POST method - creates a new resource
    case post = "POST"

    /// HTTP PUT method - updates/replaces an existing resource
    case put = "PUT"

    /// HTTP DELETE method - removes a resource
    case delete = "DELETE"

    /// Unique identifier for use in SwiftUI lists
    var id: String { rawValue }

    /// Color associated with each HTTP method for UI visualization
    var color: Color {
        switch self {
        case .get: return .green  // Safe read operations
        case .post: return .orange  // Resource creation
        case .put: return .blue  // Resource updates
        case .delete: return .red  // Destructive operations
        }
    }
}
