import Foundation

/// Reads the YAML that API tools write (OpenAPI specs, Insomnia v5 exports) into a `JSONValue`, without a dependency.
///
/// It covers block mappings and sequences, flow `[…]` and `{…}`, plain, single- and double-quoted scalars (also over
/// several lines), `|` and `>` block scalars with chomping and indentation indicators, comments, anchors, aliases, `<<`
/// merge keys and tags (which are ignored). Only the first document is read. Complex `?` keys are refused rather than
/// misread. Numbers that would lose digits as a `Double` (long IDs, leading zeros) stay strings.
struct YAMLReader {
    /// Why a file couldn't be read, with its 1-based line.
    struct Failure: LocalizedError, Equatable {
        let message: String
        let line: Int
        var errorDescription: String? { "The YAML on line \(line) couldn't be read: \(message)." }
    }

    static func parse(_ text: String) throws -> JSONValue {
        var reader = YAMLReader(text)
        return try reader.document()
    }

    /// Deeper than this is refused, so a hostile file can't exhaust the stack.
    static let maximumDepth = 200

    private var lines: [String]
    private var index = 0
    private var depth = 0
    private var anchors: [String: Anchored] = [:]
    /// Nodes that aliases have copied in so far; see ``aliasBudget``.
    private var aliasNodes = 0

    /// What an anchor names, with its size and depth, so aliases can't blow a small file up (`&a [*b, *b, …]` repeated)
    /// or nest it past ``maximumDepth``.
    struct Anchored {
        let value: JSONValue
        let nodes: Int
        let depth: Int
    }

    /// The most nodes aliases may copy into one document, well above what real specs reuse.
    static let aliasBudget = 100_000

    private init(_ text: String) {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = unified.components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("\u{FEFF}") { lines[0] = String(first.dropFirst()) }
        self.lines = lines
    }

    // MARK: - Document and blocks

    private mutating func document() throws -> JSONValue {
        // Directives and the first `---`; a later `---` or `...` ends the document.
        skipBlank()
        while index < lines.count, lines[index].hasPrefix("%") {
            index += 1
            skipBlank()
        }
        if index < lines.count, isDocumentMarker(lines[index], "---") {
            let rest = lines[index].dropFirst(3).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty || rest.hasPrefix("#") { index += 1 } else { lines[index] = rest }
        }
        if let end = lines[index...].firstIndex(where: { isDocumentMarker($0, "---") || isDocumentMarker($0, "...") }) {
            lines.removeSubrange(end...)
        }
        let value = try node(minIndent: 0)
        skipBlank()
        if index < lines.count { throw failure("unexpected indentation") }
        return value
    }

    private func isDocumentMarker(_ line: String, _ marker: String) -> Bool {
        line == marker || line.hasPrefix(marker + " ") || line.hasPrefix(marker + "\t")
    }

    /// The node whose first line is the next non-blank one, if it is indented at least `minIndent`; null otherwise.
    private mutating func node(minIndent: Int) throws -> JSONValue {
        skipBlank()
        guard index < lines.count else { return .null }
        let indent = Self.indent(of: lines[index])
        guard indent >= minIndent else { return .null }
        let content = Self.stripComment(String(lines[index].dropFirst(indent)))
        if Self.isSequenceEntry(content) { return try sequence(indent: indent) }
        if try key(in: content) != nil { return try mapping(indent: indent) }
        index += 1
        return try value(content, parentIndent: indent - 1)
    }

    private mutating func sequence(indent: Int) throws -> JSONValue {
        try enter()
        defer { depth -= 1 }
        var items: [JSONValue] = []
        while true {
            skipBlank()
            guard index < lines.count, Self.indent(of: lines[index]) == indent else { break }
            let content = Self.stripComment(String(lines[index].dropFirst(indent)))
            guard Self.isSequenceEntry(content) else { break }
            let afterDash = content.dropFirst(1)
            var rest = afterDash.drop { $0 == " " }
            // The item's column: where its first token (an anchor, if any) starts; its next keys line up under it.
            let itemIndent = indent + 1 + (afterDash.count - rest.count)
            // `- &name key: value`: the anchor (or tag) names the mapping that starts on this line.
            var anchor: String?
            while let first = rest.first, first == "&" || first == "!" {
                let token = rest.prefix { $0 != " " }
                let after = rest.dropFirst(token.count).drop { $0 == " " }
                guard !after.isEmpty, (try? key(in: String(after))) ?? nil != nil || Self.isSequenceEntry(String(after)) else { break }
                if first == "&" { anchor = String(token.dropFirst()) }
                rest = after
            }
            let startsBlock = try Self.isSequenceEntry(String(rest)) || key(in: String(rest)) != nil
            if rest.isEmpty {
                index += 1
                items.append(try node(minIndent: indent + 1))
            } else if startsBlock {
                // `- key: value` or `- - item`: the rest of the line starts a block at its own column.
                lines[index] = String(repeating: " ", count: itemIndent) + rest
                let item = try node(minIndent: itemIndent)
                if let anchor { anchors[anchor] = Self.anchored(item) }
                items.append(item)
            } else {
                index += 1
                items.append(try value(String(rest), parentIndent: indent))
            }
        }
        return .array(items)
    }

    private mutating func mapping(indent: Int) throws -> JSONValue {
        try enter()
        defer { depth -= 1 }
        var object: [String: JSONValue] = [:]
        var merged: [String: JSONValue] = [:]
        while true {
            skipBlank()
            guard index < lines.count, Self.indent(of: lines[index]) == indent else { break }
            let content = Self.stripComment(String(lines[index].dropFirst(indent)))
            guard let (name, rest) = try key(in: content) else {
                if Self.isSequenceEntry(content) { break }
                throw failure("expected \"key: value\"")
            }
            index += 1
            let entry = rest.isEmpty ? try nested(under: indent) : try value(rest, parentIndent: indent)
            if name == "<<" {
                // Merge keys: the mappings' entries, which the mapping's own keys override.
                for source in (entry.arrayItems ?? [entry]) {
                    guard case .object(let fields) = source else { throw failure("<< merges only mappings") }
                    merged.merge(fields) { current, _ in current }
                }
            } else {
                object[name] = entry
            }
        }
        return .object(object.merging(merged) { own, _ in own })
    }

    /// What follows a key with nothing after its colon: a more indented block, a sequence at the key's own indentation
    /// (YAML allows `key:` then `- item` at the same column), or null.
    private mutating func nested(under indent: Int) throws -> JSONValue {
        skipBlank()
        guard index < lines.count else { return .null }
        let next = Self.indent(of: lines[index])
        if next == indent, Self.isSequenceEntry(Self.stripComment(String(lines[index].dropFirst(next)))) { return try sequence(indent: indent) }
        return try node(minIndent: indent + 1)
    }

    // MARK: - Values

    /// A value written after `key:` or `- ` (comment already removed): an anchor, alias, tag, block scalar, flow
    /// collection, quoted or plain scalar. Continuation lines must be indented more than `parentIndent`.
    private mutating func value(_ text: String, parentIndent: Int) throws -> JSONValue {
        var text = text.trimmingCharacters(in: .whitespaces)
        var anchor: String?
        var forcesString = false
        while let first = text.first, first == "&" || first == "!" {
            let token = text.prefix { $0 != " " }
            if first == "&" { anchor = String(token.dropFirst()) }
            if token == "!!str" { forcesString = true }
            text = text.dropFirst(token.count).trimmingCharacters(in: .whitespaces)
        }
        var result: JSONValue
        if text.isEmpty {
            result = anchor == nil ? .null : try nested(under: parentIndent)
        } else if text.hasPrefix("*") {
            result = try alias(String(text.dropFirst()), line: index - 1)
        } else if text.first == "|" || text.first == ">" {
            result = .string(try blockScalar(header: text, parentIndent: parentIndent))
        } else if text.first == "[" || text.first == "{" {
            result = try flow(startingWith: text, parentIndent: parentIndent)
        } else if text.first == "\"" || text.first == "'" {
            result = .string(try quoted(startingWith: text, parentIndent: parentIndent))
        } else if text.hasPrefix("? ") || text == "?" {
            throw failure("complex keys (?) aren't supported", line: index - 1)
        } else {
            let plainText = plain(startingWith: text, parentIndent: parentIndent)
            result = forcesString ? .string(plainText) : Self.scalar(plainText)
        }
        if let anchor { anchors[anchor] = Self.anchored(result) }
        return result
    }

    /// The value an alias names, counted against ``aliasBudget`` and ``maximumDepth``.
    private mutating func alias(_ name: String, line: Int, extraDepth: Int = 0) throws -> JSONValue {
        guard let stored = anchors[name] else { throw failure("unknown alias *\(name)", line: line) }
        aliasNodes += stored.nodes
        guard aliasNodes <= Self.aliasBudget else { throw failure("its aliases expand to too much data", line: line) }
        guard depth + extraDepth + stored.depth <= Self.maximumDepth else { throw failure("it is nested too deeply", line: line) }
        return stored.value
    }

    /// `value` with its node count (stopping past ``aliasBudget``) and depth, measured without recursion.
    static func anchored(_ value: JSONValue) -> Anchored {
        var nodes = 0
        var deepest = 0
        var stack: [(JSONValue, Int)] = [(value, 1)]
        while let (node, level) = stack.popLast(), nodes <= aliasBudget {
            nodes += 1
            deepest = max(deepest, level)
            switch node {
            case .array(let items): stack += items.map { ($0, level + 1) }
            case .object(let fields): stack += fields.values.map { ($0, level + 1) }
            default: break
            }
        }
        return Anchored(value: value, nodes: nodes, depth: deepest)
    }

    /// A plain scalar and its continuation lines, folded into one line.
    private mutating func plain(startingWith text: String, parentIndent: Int) -> String {
        var result = text
        var breaks = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                breaks += 1
                index += 1
                continue
            }
            guard Self.indent(of: line) > parentIndent, !trimmed.hasPrefix("#") else { break }
            let content = Self.stripComment(trimmed)
            result += breaks == 0 ? " " + content : String(repeating: "\n", count: breaks) + content
            breaks = 0
            index += 1
        }
        // Blank lines after the scalar belong to no one; leave the reader on the next content line.
        return result
    }

    /// A quoted scalar, which may run over several lines (folded like plain ones).
    private mutating func quoted(startingWith text: String, parentIndent: Int) throws -> String {
        let quote = text.first!
        var source = text
        let startLine = index - 1
        // Each new line is scanned once: rescanning everything for each line would take minutes on a long string.
        var scanner = QuoteScanner(quote: quote)
        var close = scanner.scan(source, from: source.index(after: source.startIndex))
        while close == nil {
            guard index < lines.count else { throw failure("a quoted string isn't closed", line: startLine) }
            let next = lines[index].trimmingCharacters(in: .whitespaces)
            let start = source.endIndex
            if quote == "\"" && scanner.endsWithEscape {
                // `\` at the end of a line joins the next one without a space.
                source.removeLast()
                scanner.endsWithEscape = false
                let joinAt = source.endIndex
                source += next
                close = scanner.scan(source, from: joinAt)
            } else {
                source += next.isEmpty ? "\n" : (source.hasSuffix("\n") ? next : " " + next)
                close = scanner.scan(source, from: start)
            }
            index += 1
        }
        guard let close else { throw failure("a quoted string isn't closed", line: startLine) }
        let rest = Self.stripComment(String(source[source.index(after: close)...])).trimmingCharacters(in: .whitespaces)
        guard rest.isEmpty else { throw failure("unexpected text after a quoted string", line: startLine) }
        return try Self.unquote(String(source[source.startIndex...close]), line: startLine)
    }

    /// A `|` (literal) or `>` (folded) block scalar, with its `-`/`+` chomping and indentation indicators.
    private mutating func blockScalar(header: String, parentIndent: Int) throws -> String {
        let folded = header.first == ">"
        var chomp: Character = " "
        var explicitIndent: Int?
        for character in header.dropFirst() {
            if character == "-" || character == "+" {
                chomp = character
            } else if let digit = character.wholeNumberValue, digit > 0 {
                explicitIndent = digit
            } else if character == " " || character == "#" {
                break
            } else {
                throw failure("unexpected \"\(character)\" after a block scalar indicator", line: index - 1)
            }
        }
        var blockIndent = explicitIndent.map { max(parentIndent, 0) + $0 }
        var content: [String] = []
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                content.append(blockIndent.map { line.count > $0 ? String(line.dropFirst($0)) : "" } ?? "")
                index += 1
                continue
            }
            let indent = Self.indent(of: line)
            if blockIndent == nil {
                guard indent > parentIndent else { break }
                blockIndent = indent
            }
            guard let blockIndent, indent >= blockIndent else { break }
            content.append(String(line.dropFirst(blockIndent)))
            index += 1
        }
        var trailing = 0
        while let last = content.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            trailing += 1
            content.removeLast()
        }
        var text = folded ? Self.fold(content) : content.joined(separator: "\n")
        switch chomp {
        case "-": break
        case "+": text += String(repeating: "\n", count: (content.isEmpty ? 0 : 1) + trailing)
        default: if !content.isEmpty { text += "\n" }
        }
        return text
    }

    /// YAML folding: a break between two lines is a space, blank lines are breaks, and more indented lines keep theirs.
    private static func fold(_ lines: [String]) -> String {
        var result = ""
        var breaks = 0
        var previousWasNormal = false
        var first = true
        for line in lines {
            if line.isEmpty {
                breaks += 1
                continue
            }
            let normal = !(line.first?.isWhitespace ?? false)
            if first {
                result += String(repeating: "\n", count: breaks)
                first = false
            } else if breaks == 0 {
                result += normal && previousWasNormal ? " " : "\n"
            } else {
                result += String(repeating: "\n", count: normal && previousWasNormal ? breaks : breaks + 1)
            }
            result += line
            breaks = 0
            previousWasNormal = normal
        }
        return result
    }

    /// A flow collection, joined over lines until its brackets close.
    private mutating func flow(startingWith text: String, parentIndent: Int) throws -> JSONValue {
        var source = text
        let startLine = index - 1
        var scanner = FlowScanner()
        scanner.feed(source)
        while !scanner.isClosed {
            guard index < lines.count else { throw failure("a [ or { isn't closed", line: startLine) }
            let next = " " + Self.stripComment(lines[index].trimmingCharacters(in: .whitespaces))
            source += next
            scanner.feed(next)
            index += 1
        }
        var parser = FlowParser(Array(source), line: startLine + 1, depth: depth, anchors: anchors, aliasNodes: aliasNodes)
        let result = try parser.value()
        parser.skipSpaces()
        guard parser.atEnd else { throw Failure(message: "unexpected text after a ] or }", line: startLine + 1) }
        aliasNodes = parser.aliasNodes
        return result
    }

    // MARK: - Lines

    private mutating func skipBlank() {
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty || trimmed.hasPrefix("#") else { return }
            index += 1
        }
    }

    private mutating func enter() throws {
        depth += 1
        if depth > Self.maximumDepth { throw failure("it is nested too deeply") }
    }

    /// A failure at `line` (an index into `lines`), the current line by default.
    private func failure(_ message: String, line: Int? = nil) -> Failure {
        Failure(message: message, line: min(line ?? index, max(lines.count - 1, 0)) + 1)
    }

    private static func indent(of line: String) -> Int { line.prefix { $0 == " " }.count }

    private static func isSequenceEntry(_ content: String) -> Bool { content == "-" || content.hasPrefix("- ") || content.hasPrefix("-\t") }

    /// The key and what follows its colon, or nil when `content` isn't a `key: value` line.
    private func key(in content: String) throws -> (String, String)? {
        guard let first = content.first else { return nil }
        if first == "?" && (content.count == 1 || content.dropFirst().first == " ") { throw failure("complex keys (?) aren't supported") }
        if first == "\"" || first == "'" {
            guard let close = Self.closingQuote(in: content, quote: first) else { return nil }
            let after = content[content.index(after: close)...].drop { $0 == " " }
            guard after.first == ":", after.count == 1 || after.dropFirst().first == " " else { return nil }
            return (try Self.unquote(String(content[...close]), line: index + 1), after.dropFirst().trimmingCharacters(in: .whitespaces))
        }
        if "[{|>*&!%@`".contains(first) || Self.isSequenceEntry(content) { return nil }
        var position = content.startIndex
        while let colon = content[position...].firstIndex(of: ":") {
            let next = content.index(after: colon)
            if next == content.endIndex || content[next] == " " || content[next] == "\t" {
                let name = content[..<colon].trimmingCharacters(in: .whitespaces)
                return (name, String(content[next...]).trimmingCharacters(in: .whitespaces))
            }
            position = next
        }
        return nil
    }

    /// `text` without a trailing `# comment` (a `#` after whitespace, outside quotes), trailing spaces removed.
    static func stripComment(_ text: String) -> String {
        let characters = Array(text)
        var quote: Character?
        var end = characters.count
        var position = 0
        while position < characters.count {
            let character = characters[position]
            let previous: Character = position == 0 ? " " : characters[position - 1]
            if let open = quote {
                if open == "\"" && character == "\\" {
                    position += 1  // skips the escaped character
                } else if character == open {
                    // `''` inside single quotes is a quote, not the end.
                    if open == "'" && position + 1 < characters.count && characters[position + 1] == "'" { position += 1 } else { quote = nil }
                }
            } else if character == "\"" || character == "'" {
                if previous == " " || previous == "\t" || "[{,:-".contains(previous) || position == 0 { quote = character }
            } else if character == "#" && (previous == " " || previous == "\t" || position == 0) {
                end = position
                break
            }
            position += 1
        }
        var result = String(characters[..<end])
        while let last = result.last, last == " " || last == "\t" { result.removeLast() }
        return result
    }

    /// Where the quoted scalar that `text` starts with ends, or nil if it doesn't on this text.
    private static func closingQuote(in text: String, quote: Character) -> String.Index? {
        var scanner = QuoteScanner(quote: quote)
        return scanner.scan(text, from: text.index(after: text.startIndex))
    }

    /// The text of a quoted scalar, its quotes included: `''` in single quotes, backslash escapes in double ones.
    static func unquote(_ text: String, line: Int) throws -> String {
        let quote = text.first!
        let inner = text.dropFirst().dropLast()
        if quote == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
        var result = ""
        var iterator = Array(inner)[...]
        while let character = iterator.popFirst() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard let escape = iterator.popFirst() else { break }
            switch escape {
            case "n": result.append("\n")
            case "t", "\t": result.append("\t")
            case "r": result.append("\r")
            case "0": result.append("\0")
            case "b": result.append("\u{08}")
            case "f": result.append("\u{0C}")
            case "e": result.append("\u{1B}")
            case "a": result.append("\u{07}")
            case "v": result.append("\u{0B}")
            case " ": result.append(" ")
            case "N": result.append("\u{85}")
            case "_": result.append("\u{A0}")
            case "x", "u", "U":
                let count = escape == "x" ? 2 : escape == "u" ? 4 : 8
                let digits = String(iterator.prefix(count))
                iterator = iterator.dropFirst(count)
                guard digits.count == count, let code = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(code) else {
                    throw Failure(message: "a \\\(escape) escape isn't valid", line: line)
                }
                result.unicodeScalars.append(scalar)
            default: result.append(escape)  // \" \\ \/ and the like
            }
        }
        return result
    }

    /// A plain scalar's value: null, a boolean, a number that a `Double` holds exactly as written, else the text.
    static func scalar(_ text: String) -> JSONValue {
        switch text {
        case "", "~", "null", "Null", "NULL": return .null
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        default: break
        }
        let digits = text.filter(\.isNumber).count
        let unsigned = text.first == "-" || text.first == "+" ? String(text.dropFirst()) : text
        let leadingZero = unsigned.count > 1 && unsigned.hasPrefix("0") && !unsigned.hasPrefix("0.")
        // Only numbers that read back as written: `1.10` or `1.0` stay text, so a version or example keeps its spelling.
        if digits <= 15, !leadingZero, text.wholeMatch(of: /[-+]?(\d+(\.\d*)?|\.\d+)([eE][-+]?\d+)?/) != nil, let number = Double(text),
            JSONValue.number(number).scalarText == (text.hasPrefix("+") ? String(text.dropFirst()) : text)
        {
            return .number(number)
        }
        return .string(text)
    }
}

/// The inside of a flow collection: `[a, b]`, `{k: v}`, nested, with quoted and plain scalars.
private struct FlowParser {
    private let characters: [Character]
    private var position = 0
    private let line: Int
    private let anchors: [String: YAMLReader.Anchored]
    private var depth: Int
    /// The document's alias count, carried on (see `YAMLReader.aliasBudget`).
    private(set) var aliasNodes: Int

    init(_ characters: [Character], line: Int, depth: Int, anchors: [String: YAMLReader.Anchored], aliasNodes: Int) {
        self.characters = characters
        self.line = line
        self.depth = depth
        self.anchors = anchors
        self.aliasNodes = aliasNodes
    }

    var atEnd: Bool { position >= characters.count }

    mutating func skipSpaces() {
        while position < characters.count, characters[position].isWhitespace { position += 1 }
    }

    mutating func value() throws -> JSONValue {
        skipSpaces()
        guard position < characters.count else { return .null }
        depth += 1
        defer { depth -= 1 }
        guard depth <= YAMLReader.maximumDepth else { throw failure("it is nested too deeply") }
        switch characters[position] {
        case "[":
            position += 1
            var items: [JSONValue] = []
            while true {
                skipSpaces()
                if try consume("]") { break }
                items.append(try entry())
                skipSpaces()
                if try consume(",") { continue }
                guard try consume("]") else { throw failure("expected , or ]") }
                break
            }
            return .array(items)
        case "{":
            position += 1
            var object: [String: JSONValue] = [:]
            while true {
                skipSpaces()
                if try consume("}") { break }
                guard position < characters.count else { throw failure("a { isn't closed") }
                let key = try scalarText(inKey: true)
                skipSpaces()
                var item = JSONValue.null
                if try consume(":") { item = try value() }
                object[key] = item
                skipSpaces()
                if try consume(",") { continue }
                guard try consume("}") else { throw failure("expected , or }") }
                break
            }
            return .object(object)
        case "\"", "'":
            return .string(try scalarText(inKey: false))
        case "*":
            position += 1
            let name = String(characters[position...].prefix { !",]} ".contains($0) })
            position += name.count
            guard let stored = anchors[name] else { throw failure("unknown alias *\(name)") }
            aliasNodes += stored.nodes
            guard aliasNodes <= YAMLReader.aliasBudget else { throw failure("its aliases expand to too much data") }
            guard depth + stored.depth <= YAMLReader.maximumDepth else { throw failure("it is nested too deeply") }
            return stored.value
        default:
            return YAMLReader.scalar(try scalarText(inKey: false))
        }
    }

    /// A sequence entry, which may be a single-pair mapping (`[a: 1]`).
    private mutating func entry() throws -> JSONValue {
        skipSpaces()
        guard position < characters.count else { throw failure("a [ isn't closed") }
        let start = position
        let first = characters[position]
        if first != "[" && first != "{" {
            let key = try scalarText(inKey: true)
            skipSpaces()
            if try consume(":") { return .object([key: try value()]) }
            position = start
        }
        return try value()
    }

    /// A quoted scalar's text, or a plain one up to `,` `]` `}` (and `: ` in a key).
    private mutating func scalarText(inKey: Bool) throws -> String {
        skipSpaces()
        guard position < characters.count else { return "" }
        let quote = characters[position]
        if quote == "\"" || quote == "'" {
            let start = position
            position += 1
            while position < characters.count {
                let character = characters[position]
                if quote == "\"" && character == "\\" {
                    position += 2
                    continue
                }
                if character == quote {
                    if quote == "'" && position + 1 < characters.count && characters[position + 1] == "'" {
                        position += 2
                        continue
                    }
                    break
                }
                position += 1
            }
            guard position < characters.count else { throw failure("a quoted string isn't closed") }
            position += 1
            return try YAMLReader.unquote(String(characters[start..<position]), line: line)
        }
        let start = position
        while position < characters.count {
            let character = characters[position]
            if character == "," || character == "]" || character == "}" { break }
            if character == ":" && (position + 1 == characters.count || characters[position + 1].isWhitespace || ",]}".contains(characters[position + 1])) { break }
            position += 1
        }
        return String(characters[start..<position]).trimmingCharacters(in: .whitespaces)
    }

    private mutating func consume(_ character: Character) throws -> Bool {
        guard position < characters.count, characters[position] == character else { return false }
        position += 1
        return true
    }

    private func failure(_ message: String) -> YAMLReader.Failure { YAMLReader.Failure(message: message, line: line) }
}

extension JSONValue {
    /// The elements of an array, else nil.
    var arrayItems: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    /// The fields of an object, else nil.
    var objectFields: [String: JSONValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }

    /// A string as written; a number or boolean as text (integers without `.0`); nil for null, arrays and objects.
    var scalarText: String? {
        switch self {
        case .string(let text): return text
        case .bool(let value): return value ? "true" : "false"
        case .number(let number):
            if number.rounded() == number, abs(number) < 1e15 { return String(Int64(number)) }
            return String(number)
        default: return nil
        }
    }

    /// True or false; also the strings "true" and "false", which some exports write.
    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .string(let text): return text == "true" ? true : text == "false" ? false : nil
        default: return nil
        }
    }

    /// Indexes an array, or nil.
    subscript(position: Int) -> JSONValue? {
        guard let items = arrayItems, items.indices.contains(position) else { return nil }
        return items[position]
    }
}

/// Finds a quoted scalar's closing quote one piece of text at a time, so a string over many lines is scanned once.
private struct QuoteScanner {
    let quote: Character
    /// The text so far ends inside a `\` escape (double quotes): the next line joins without a space.
    var endsWithEscape = false

    /// The closing quote at or after `start`, or nil when `text` ends first.
    mutating func scan(_ text: String, from start: String.Index) -> String.Index? {
        var position = start
        while position < text.endIndex {
            let character = text[position]
            if quote == "\"" && character == "\\" {
                position = text.index(after: position)
                if position == text.endIndex {
                    endsWithEscape = true
                    return nil
                }
                position = text.index(after: position)
                continue
            }
            if character == quote {
                let next = text.index(after: position)
                // `''` inside single quotes is a quote. A line never ends inside one: lines are joined by a space or a break.
                if quote == "'" && next < text.endIndex && text[next] == "'" {
                    position = text.index(after: next)
                    continue
                }
                return position
            }
            position = text.index(after: position)
        }
        return nil
    }
}

/// Whether a flow collection's brackets have closed, fed one line at a time. Quotes count only where a scalar starts
/// (after `[ { , :` or at the start), as `FlowParser` reads them, so `[don't, do]` is closed.
private struct FlowScanner {
    private var depth = 0
    private var quote: Character?
    private var escaped = false
    private var previous: Character = "["
    private var started = false

    var isClosed: Bool { started && depth <= 0 && quote == nil }

    mutating func feed(_ text: String) {
        for character in text {
            if let open = quote {
                if escaped {
                    escaped = false
                } else if open == "\"" && character == "\\" {
                    escaped = true
                } else if character == open {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                if "[{,:".contains(previous) { quote = character }
            } else if character == "[" || character == "{" {
                depth += 1
                started = true
            } else if character == "]" || character == "}" {
                depth -= 1
            }
            if !character.isWhitespace { previous = quote == nil ? character : previous }
            if quote != nil, character == quote { previous = "x" }
        }
    }
}
