import Foundation

/// A Sendable JSON tree for MCP (JSON-RPC) messages, tool arguments and results.
enum JSONValue: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    /// Sorted keys and unescaped slashes, so output is stable and readable.
    var data: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data(#"{"error":{"code":-32603,"message":"Internal error."},"id":null,"jsonrpc":"2.0"}"#.utf8)
    }

    var text: String { String(decoding: data, as: UTF8.self) }

    /// More than `limit` levels of arrays and objects, checked on the raw bytes before decoding.
    static func exceedsNesting(_ data: Data, limit: Int = 64) -> Bool {
        var depth = 0, inString = false, escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
            } else if byte == 0x22 {
                inString = true
            } else if byte == 0x5B || byte == 0x7B {
                depth += 1
                if depth > limit { return true }
            } else if byte == 0x5D || byte == 0x7D {
                depth -= 1
            }
        }
        return false
    }
}

extension JSONValue {
    static func from(_ string: String?) -> JSONValue { string.map(JSONValue.string) ?? .null }
    static func from(_ number: Int?) -> JSONValue { number.map { .number(Double($0)) } ?? .null }
    static func from(_ number: Double?) -> JSONValue { number.map(JSONValue.number) ?? .null }
    static func from(_ date: Date) -> JSONValue { .string(date.formatted(.iso8601)) }
}
