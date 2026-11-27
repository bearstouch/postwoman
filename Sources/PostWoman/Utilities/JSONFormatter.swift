import Foundation

/// Utility enum for JSON formatting, minification, and validation operations.
/// Provides static methods to work with JSON strings, useful for displaying
/// API response bodies and validating JSON content in request bodies.
/// A top-level scalar (`42`, `true`, `null`, `"x"`) is JSON too (RFC 8259), so a body of `true` shows as JSON.
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
            let jsonObject = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let prettyData = try JSONSerialization.data(
                withJSONObject: jsonObject,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
            )
            return String(data: prettyData, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// Re-indents a JSON string for editing, keeping it otherwise exactly as written.
    ///
    /// Unlike ``format(_:)``, it keeps key order, number literals and string escapes,
    /// because it only rewrites the whitespace between tokens.
    ///
    /// - Parameters:
    ///   - jsonString: The JSON string to prettify
    ///   - indent: The string used for one level of indentation
    /// - Returns: The re-indented JSON, or nil if the input is invalid JSON
    static func prettify(_ jsonString: String, indent: String = "  ") -> String? {
        guard isValid(jsonString) else { return nil }

        let scalars = Array(jsonString.unicodeScalars)
        var output = String.UnicodeScalarView()
        var level = 0
        var inString = false
        var escaped = false

        func newline() {
            output.append("\n")
            for _ in 0..<level { output.append(contentsOf: indent.unicodeScalars) }
        }

        func nextSignificant(after index: Int) -> Unicode.Scalar? {
            var next = index + 1
            while next < scalars.count, isWhitespace(scalars[next]) { next += 1 }
            return next < scalars.count ? scalars[next] : nil
        }

        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            defer { index += 1 }

            if inString {
                output.append(scalar)
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    inString = false
                }
                continue
            }

            switch scalar {
            case _ where isWhitespace(scalar):
                break
            case "\"":
                inString = true
                output.append(scalar)
            case "{", "[":
                output.append(scalar)
                let close: Unicode.Scalar = scalar == "{" ? "}" : "]"
                if nextSignificant(after: index) == close {
                    output.append(close)
                    while scalars[index] != close { index += 1 }
                } else {
                    level += 1
                    newline()
                }
            case "}", "]":
                level -= 1
                newline()
                output.append(scalar)
            case ",":
                output.append(scalar)
                newline()
            case ":":
                output.append(contentsOf: ": ".unicodeScalars)
            default:
                output.append(scalar)
            }
        }
        return String(output)
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
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
            let jsonObject = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let minifiedData = try JSONSerialization.data(
                withJSONObject: jsonObject,
                options: [.withoutEscapingSlashes, .fragmentsAllowed]
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
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return true
        } catch {
            return false
        }
    }
}
