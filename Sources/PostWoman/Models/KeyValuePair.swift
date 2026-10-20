import Foundation

/// A key-value pair with enable/disable functionality.
/// Used for HTTP headers, query parameters, and other configurable key-value data.
/// Supports environment variable substitution in both keys and values using {{variable}} syntax.
struct KeyValuePair: Codable, Identifiable, Hashable {
    /// Unique identifier for the key-value pair.
    var id: UUID = UUID()

    /// The key/name of the pair (e.g., "Content-Type", "Authorization").
    var key: String

    /// The value associated with the key. Supports {{variable}} substitution.
    var value: String

    /// Whether this key-value pair is enabled/active.
    /// Disabled pairs are ignored when building requests.
    var isEnabled: Bool = true

    /// Creates a new key-value pair.
    /// - Parameters:
    ///   - key: The key/name (defaults to empty string)
    ///   - value: The value (defaults to empty string)
    ///   - isEnabled: Whether the pair is enabled (defaults to true)
    init(key: String = "", value: String = "", isEnabled: Bool = true) {
        self.id = UUID()
        self.key = key
        self.value = value
        self.isEnabled = isEnabled
    }
}
