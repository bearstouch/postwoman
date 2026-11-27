import AppKit

/// Splits JSON text into tokens for syntax coloring.
///
/// It is a lenient scanner, not a parser: invalid JSON still gets colored as far as it makes sense.
/// Ranges are UTF-16 offsets, ready for `NSAttributedString`.
enum JSONHighlighter {
    enum Kind: Equatable {
        case key, string, number, literal, punctuation
    }

    struct Token: Equatable {
        let kind: Kind
        let range: NSRange
    }

    static func tokens(in text: String) -> [Token] {
        let units = Array(text.utf16)
        let count = units.count
        var tokens: [Token] = []
        var index = 0

        func isWhitespace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D }
        func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }
        func isLetter(_ unit: UInt16) -> Bool { unit >= 0x61 && unit <= 0x7A }

        while index < count {
            let unit = units[index]
            let start = index
            switch unit {
            case 0x22:  // "
                index += 1
                while index < count {
                    if units[index] == 0x5C {  // backslash: skip the escaped character
                        index += 2
                    } else if units[index] == 0x22 {
                        index += 1
                        break
                    } else {
                        index += 1
                    }
                }
                index = min(index, count)
                var next = index
                while next < count, isWhitespace(units[next]) { next += 1 }
                let kind: Kind = next < count && units[next] == 0x3A ? .key : .string
                tokens.append(Token(kind: kind, range: NSRange(location: start, length: index - start)))
            case 0x7B, 0x7D, 0x5B, 0x5D, 0x3A, 0x2C:  // { } [ ] : ,
                index += 1
                tokens.append(Token(kind: .punctuation, range: NSRange(location: start, length: 1)))
            case 0x2D, 0x30...0x39:  // - and digits
                index += 1
                while index < count, isDigit(units[index]) || [0x2E, 0x65, 0x45, 0x2B, 0x2D].contains(units[index]) { index += 1 }
                tokens.append(Token(kind: .number, range: NSRange(location: start, length: index - start)))
            case _ where isLetter(unit):
                while index < count, isLetter(units[index]) { index += 1 }
                let word = String(utf16CodeUnits: Array(units[start..<index]), count: index - start)
                if word == "true" || word == "false" || word == "null" {
                    tokens.append(Token(kind: .literal, range: NSRange(location: start, length: index - start)))
                }
            default:
                index += 1
            }
        }
        return tokens
    }

    /// Colors the JSON tokens in `text` with `CodePalette`, leaving other attributes alone.
    static func colorize(_ text: NSMutableAttributedString) {
        for token in tokens(in: text.string) {
            text.addAttribute(.foregroundColor, value: color(for: token.kind), range: token.range)
        }
    }

    static func color(for kind: Kind) -> NSColor {
        switch kind {
        case .key: return CodePalette.key
        case .string: return CodePalette.string
        case .number: return CodePalette.number
        case .literal: return CodePalette.literal
        case .punctuation: return CodePalette.punctuation
        }
    }
}
