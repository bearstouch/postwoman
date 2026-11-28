import SwiftUI

/// How the editor shows `{{variables}}`: tooltips and the resolved URL under the URL bar.
@MainActor
enum VariableDescription {
    static let mask = "••••••"

    /// The color of a variable from `source`: the selected environment, Default, or not defined.
    static func color(_ source: VariableResolver.Source) -> Color {
        switch source {
        case .selected: Theme.success
        case .default: Theme.info
        case .missing: Theme.failure
        }
    }

    /// One line per variable: its value and where it comes from. Secrets are masked, also inside other variables' values.
    static func help(for tokens: [VariableResolver.Token], resolver: VariableResolver) -> String {
        var seen: Set<String> = []
        return tokens.filter { seen.insert($0.name).inserted }.map { line(for: $0, resolver: resolver) }.joined(separator: "\n")
    }

    static func line(for token: VariableResolver.Token, resolver: VariableResolver) -> String {
        guard let entry = resolver.entry(token.name) else { return "\(token.name) is not defined, so it is sent as written." }
        let value = entry.isSecret ? mask : resolver.resolve(entry.value, maskingSecretsWith: mask)
        switch entry.source {
        case .selected: return "\(token.name) = \(value)  (\(resolver.selectedName ?? "selected environment"))"
        case .default: return "\(token.name) = \(value)  (\(resolver.defaultName))"
        case .missing: return "\(token.name) is not defined."
        }
    }

    /// `text` as it will be sent: each variable's value in its source's color, secrets masked,
    /// names that aren't defined in red as written.
    static func resolvedText(_ text: String, resolver: VariableResolver) -> AttributedString {
        var result = AttributedString()
        var cursor = text.startIndex
        for token in resolver.tokens(in: text) {
            var plain = AttributedString(String(text[cursor..<token.range.lowerBound]))
            plain.foregroundColor = .secondary
            result += plain
            cursor = token.range.upperBound
            let value: String
            if let entry = resolver.entry(token.name) {
                value = entry.isSecret ? mask : resolver.resolve(entry.value, maskingSecretsWith: mask)
            } else {
                value = String(text[token.range])
            }
            var piece = AttributedString(value)
            piece.foregroundColor = color(token.source)
            result += piece
        }
        var rest = AttributedString(String(text[cursor...]))
        rest.foregroundColor = .secondary
        result += rest
        return result
    }
}
