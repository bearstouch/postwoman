import Foundation

/// Utility enum for JSON formatting, minification, and validation operations.
/// Provides static methods to work with JSON strings, useful for displaying
/// API response bodies and validating JSON content in request bodies.
enum JSONFormatter {
    /// Formats a JSON string with proper indentation and structure.
    /// Converts compact JSON to human-readable format with consistent key ordering.
    ///
    /// - Parameter jsonString: The JSON string to format
    /// - Returns: A formatted JSON string, or nil if the input is invalid JSON
    static func format(_ jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8) else {
            return nil
        }

        do {
            let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
            let prettyData = try JSONSerialization.data(
                withJSONObject: jsonObject,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            return String(data: prettyData, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// Minifies a JSON string by removing unnecessary whitespace.
    /// Useful for reducing payload size in API requests.
    ///
    /// - Parameter jsonString: The JSON string to minify
    /// - Returns: A minified JSON string, or nil if the input is invalid JSON
    static func minify(_ jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8) else {
            return nil
        }

        do {
            let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
            let minifiedData = try JSONSerialization.data(
                withJSONObject: jsonObject,
                options: [.withoutEscapingSlashes]
            )
            return String(data: minifiedData, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// Validates whether a string contains valid JSON syntax.
    /// Useful for checking user input before sending requests.
    ///
    /// - Parameter jsonString: The string to validate
    /// - Returns: True if the string is valid JSON, false otherwise
    static func isValid(_ jsonString: String) -> Bool {
        guard let data = jsonString.data(using: .utf8) else {
            return false
        }

        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [])
            return true
        } catch {
            return false
        }
    }
}
