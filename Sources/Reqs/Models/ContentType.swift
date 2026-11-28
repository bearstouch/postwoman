import Foundation

/// Content types for HTTP request bodies.
/// Each type specifies how the request body should be formatted and what MIME type to use.
enum ContentType: String, Codable, CaseIterable, Identifiable {
    /// No request body
    case none = "None"

    /// JSON formatted body
    case json = "JSON"

    /// Multipart form data for file uploads
    case formData = "Form Data"

    /// URL-encoded form data
    case urlEncoded = "URL Encoded"

    /// XML formatted body
    case xml = "XML"

    /// Plain text body
    case text = "Plain Text"

    /// Unique identifier for use in SwiftUI lists
    var id: String { rawValue }

    /// The MIME type string to use in Content-Type headers.
    /// Returns nil for .none case as no Content-Type header is needed.
    var mimeType: String? {
        switch self {
        case .none: return nil
        case .json: return "application/json"
        case .formData: return "multipart/form-data"
        case .urlEncoded: return "application/x-www-form-urlencoded"
        case .xml: return "application/xml"
        case .text: return "text/plain"
        }
    }
}
