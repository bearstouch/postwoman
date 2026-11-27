import Foundation

/// Replaces `{{name}}` in request text with a collection's variables.
///
/// The selected environment's enabled variables override Default's; everything else comes from Default.
/// A name neither defines is left as written. A value may use other variables, resolved up to
/// `maximumDepth` levels so a cycle can't loop forever.
struct VariableResolver: Sendable, Equatable {
    /// Where a variable's value comes from.
    enum Source: Sendable, Equatable {
        case selected, `default`, missing
    }

    struct Entry: Sendable, Equatable {
        let value: String
        let isSecret: Bool
        let source: Source
    }

    /// One `{{name}}` in a text.
    struct Token: Sendable, Equatable {
        /// The whole `{{ name }}`, as a range of the text.
        let range: Range<String.Index>
        let name: String
        let source: Source
        let isSecret: Bool
    }

    static let maximumDepth = 5

    /// Resolves nothing: every name is missing.
    static let empty = VariableResolver(defaults: [], selected: nil)

    private(set) var entries: [String: Entry] = [:]

    /// The selected environment's name; nil when only Default applies.
    let selectedName: String?

    /// The Default environment's name, which the user may have changed.
    let defaultName: String

    init(defaults: [Variable], selected: [Variable]?, selectedName: String? = nil, defaultName: String = CollectionEnvironment.defaultName) {
        self.selectedName = selected == nil ? nil : selectedName
        self.defaultName = defaultName
        for variable in defaults where variable.isEnabled {
            let key = variable.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            entries[key] = Entry(value: variable.value, isSecret: variable.isSecret, source: .default)
        }
        for variable in selected ?? [] where variable.isEnabled {
            let key = variable.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            entries[key] = Entry(value: variable.value, isSecret: variable.isSecret, source: .selected)
        }
    }

    /// The variable called `name`, if one is defined and enabled.
    func entry(_ name: String) -> Entry? { entries[name] }

    /// Every `{{name}}` in `text`, with where its value comes from.
    func tokens(in text: String) -> [Token] {
        Self.references(in: text).map { range, name in
            let entry = entries[name]
            return Token(range: range, name: name, source: entry?.source ?? .missing, isSecret: entry?.isSecret ?? false)
        }
    }

    /// `text` with its variables replaced. With `redactSecrets`, a secret variable stays as `{{name}}`
    /// (for History, generated code and agents).
    func resolve(_ text: String, redactSecrets: Bool = false) -> String {
        var missing: Set<String> = []
        return resolve(text, secrets: redactSecrets ? .reference : .value, depth: 0, missing: &missing)
    }

    /// `text` with its variables replaced and every secret, nested ones included, shown as `mask` (for the editor).
    func resolve(_ text: String, maskingSecretsWith mask: String) -> String {
        var missing: Set<String> = []
        return resolve(text, secrets: .mask(mask), depth: 0, missing: &missing)
    }

    /// What a secret variable becomes in resolved text.
    private enum SecretOutput {
        case value, reference, mask(String)
    }

    /// The names `text` uses that neither environment defines, nested ones included, in order of appearance.
    func missingVariables(in text: String) -> [String] {
        var missing: Set<String> = []
        _ = resolve(text, secrets: .value, depth: 0, missing: &missing)
        var seen: Set<String> = []
        var ordered: [String] = []
        // Keep the order they appear in, top level first.
        for name in Self.references(in: text).map(\.1) + missing.sorted() where missing.contains(name) && !seen.contains(name) {
            seen.insert(name)
            ordered.append(name)
        }
        return ordered
    }

    private func resolve(_ text: String, secrets: SecretOutput, depth: Int, missing: inout Set<String>) -> String {
        let references = Self.references(in: text)
        guard !references.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for (range, name) in references {
            result += text[cursor..<range.lowerBound]
            cursor = range.upperBound
            guard let entry = entries[name] else {
                missing.insert(name)
                result += text[range]
                continue
            }
            switch (entry.isSecret, secrets) {
            case (true, .reference): result += "{{\(name)}}"
            case (true, .mask(let mask)): result += mask
            case _ where depth + 1 >= Self.maximumDepth: result += entry.value
            default: result += resolve(entry.value, secrets: secrets, depth: depth + 1, missing: &missing)
            }
        }
        result += text[cursor...]
        return result
    }

    /// The `{{ name }}` references in `text`: their ranges and trimmed names. Empty names (`{{}}`) are not references.
    static func references(in text: String) -> [(Range<String.Index>, String)] {
        var found: [(Range<String.Index>, String)] = []
        var searchStart = text.startIndex
        while let open = text.range(of: "{{", range: searchStart..<text.endIndex) {
            guard let close = text.range(of: "}}", range: open.upperBound..<text.endIndex) else { break }
            let inner = text[open.upperBound..<close.lowerBound]
            // `{{a {{b}}`: the reference is the innermost one.
            if let nested = inner.range(of: "{{", options: .backwards) {
                searchStart = nested.lowerBound
                continue
            }
            let name = inner.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !name.contains("}"), !name.contains(where: \.isNewline) {
                found.append((open.lowerBound..<close.upperBound, name))
            }
            searchStart = close.upperBound
        }
        return found
    }
}
