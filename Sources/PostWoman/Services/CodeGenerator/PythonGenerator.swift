import Foundation

/// Generates Python code using the requests library from API request configurations.
/// Produces executable Python scripts that replicate HTTP requests with proper
/// handling of authentication, headers, query parameters, and different body types.
struct PythonGenerator {
    /// Generates Python code that replicates the given API request using the requests library.
    /// The generated code includes imports, URL construction, headers, authentication,
    /// query parameters, request body, and response handling.
    ///
    /// - Parameters:
    ///   - request: The API request to convert to Python code
    /// - Returns: A complete Python script as a string
    func generate(from request: some RequestFields) -> String {
        var code = """
            import requests

            url = \(PythonLiteral.string(RequestURL.encoded(request.url)))

            """

        let enabledParams = request.queryParams.filter { $0.isEnabled && !$0.key.isEmpty }
        if !enabledParams.isEmpty {
            code += "params = {\n"
            for param in enabledParams {
                code += "    \(PythonLiteral.string(param.key)): \(PythonLiteral.string(param.value)),\n"
            }
            code += "}\n\n"
        }

        let enabledHeaders = request.headers.filter { $0.isEnabled && !$0.key.isEmpty }
        var hasHeaders = !enabledHeaders.isEmpty

        // A JSON body that doesn't parse can't go as `json=` (requests would send it as a JSON string), so it is sent as
        // written with `data=`, and the Content-Type the app would send.
        let hasBody = request.sendsBody
        let jsonLiteral = hasBody && request.bodyType == .json ? PythonLiteral(json: request.bodyContent) : nil
        let addsJSONContentType =
            hasBody && request.bodyType == .json && jsonLiteral == nil && !enabledHeaders.contains { $0.key.lowercased() == "content-type" }
        if addsJSONContentType { hasHeaders = true }

        if request.authenticationType == .bearer, let token = request.authBearerToken, !token.isEmpty {
            hasHeaders = true
        }

        if hasHeaders {
            code += "headers = {\n"
            for header in enabledHeaders {
                code += "    \(PythonLiteral.string(header.key)): \(PythonLiteral.string(header.value)),\n"
            }

            if addsJSONContentType, let mimeType = ContentType.json.mimeType {
                code += "    \"Content-Type\": \(PythonLiteral.string(mimeType)),\n"
            }

            if request.authenticationType == .bearer,
                let token = request.authBearerToken, !token.isEmpty
            {
                code += "    \"Authorization\": \(PythonLiteral.string("Bearer " + token)),\n"
            }

            code += "}\n\n"
        }

        var authParam = ""
        if request.authenticationType == .basic,
            let (username, password) = AuthenticationHandler.basicCredentials(username: request.authBasicUsername, password: request.authBasicPassword)
        {
            code += "auth = (\(PythonLiteral.string(username)), \(PythonLiteral.string(password)))\n\n"
            authParam = ", auth=auth"
        }

        var bodyParam = ""
        if hasBody, let fields = MultipartForm.fields(of: request) {
            // `files=` makes requests send multipart/form-data with its own boundary; (None, value) is a field, not a file.
            code += "files = [\n"
            for field in fields { code += "    (\(PythonLiteral.string(field.key)), (None, \(PythonLiteral.string(field.value)))),\n" }
            code += "]\n\n"
            bodyParam = ", files=files"
        } else if hasBody {
            if let jsonLiteral {
                code += """
                    json_data = \(jsonLiteral.text)

                    """
                bodyParam = ", json=json_data"
            } else {
                code += "data = \(PythonLiteral.string(request.bodyContent, block: true))\n\n"
                bodyParam = ", data=data"
            }
        }

        let paramsArg = enabledParams.isEmpty ? "" : ", params=params"
        let headersArg = hasHeaders ? ", headers=headers" : ""
        // requests follows redirects for every method but HEAD; the app follows them for HEAD too.
        let redirectsArg = request.method == .head ? ", allow_redirects=True" : ""

        let methodName = request.method.rawValue.lowercased()
        code += """
            response = requests.\(methodName)(url\(paramsArg)\(headersArg)\(bodyParam)\(authParam)\(redirectsArg))

            print(f"Status Code: {response.status_code}")
            print(f"Headers: {dict(response.headers)}")
            print(f"Response Body:")
            print(response.text)

            # For JSON responses, you can also use:
            # print(response.json())
            """

        return code
    }

}

/// Python literals for generated scripts. A JSON body is converted by walking its text rather than a parsed `JSONSerialization`
/// value, so keys keep the order they were written in and numbers keep their literal (big integers stay exact).
struct PythonLiteral {
    /// The Python source for the value.
    let text: String

    /// `string` as a Python string literal: `"…"` with escapes, or, with `block`, a `"""…"""` block that keeps newlines as written.
    static func string(_ string: String, block: Bool = false) -> String {
        var escaped = ""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += block ? "\n" : "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case _ where scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value): escaped += "\\x" + String(scalar.value, radix: 16).leftPadded(to: 2)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        let quote = block ? "\"\"\"" : "\""
        return quote + escaped + quote
    }

    /// The literal for the JSON value in `json`, or nil if it isn't valid JSON.
    init?(json: String) {
        guard let data = json.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil else { return nil }
        var reader = JSONReader(scalars: Array(json.unicodeScalars))
        guard let text = reader.value(indent: 0) else { return nil }
        reader.skipWhitespace()
        guard reader.isAtEnd else { return nil }
        self.text = text
    }

    /// Reads JSON text (already checked by `JSONSerialization`) and writes the Python literal for each value, indented 4 spaces a level.
    private struct JSONReader {
        let scalars: [Unicode.Scalar]
        var index = 0

        var isAtEnd: Bool { index >= scalars.count }

        mutating func skipWhitespace() {
            while !isAtEnd, [" ", "\n", "\r", "\t"].contains(scalars[index]) { index += 1 }
        }

        mutating func value(indent: Int) -> String? {
            skipWhitespace()
            guard !isAtEnd else { return nil }
            switch scalars[index] {
            case "{":
                return container(close: "}", indent: indent) { reader in
                    reader.skipWhitespace()
                    guard let key = reader.string() else { return nil }
                    reader.skipWhitespace()
                    guard !reader.isAtEnd, reader.scalars[reader.index] == ":" else { return nil }
                    reader.index += 1
                    guard let value = reader.value(indent: indent + 1) else { return nil }
                    return "\(PythonLiteral.string(key)): \(value)"
                }
            case "[": return container(close: "]", indent: indent) { $0.value(indent: indent + 1) }
            case "\"": return string().map { PythonLiteral.string($0) }
            case "t": return keyword("true", as: "True")
            case "f": return keyword("false", as: "False")
            case "n": return keyword("null", as: "None")
            default:
                let start = index
                while !isAtEnd, "-+.eE0123456789".unicodeScalars.contains(scalars[index]) { index += 1 }
                return index > start ? String(String.UnicodeScalarView(scalars[start..<index])) : nil
            }
        }

        /// An object or array: `element` reads one member; the result has one member per line, or is `{}`/`[]` when empty.
        mutating func container(close: Unicode.Scalar, indent: Int, element: (inout JSONReader) -> String?) -> String? {
            let open = String(scalars[index])
            index += 1
            skipWhitespace()
            if !isAtEnd, scalars[index] == close {
                index += 1
                return open + String(close)
            }
            var members: [String] = []
            while true {
                guard let member = element(&self) else { return nil }
                members.append(member)
                skipWhitespace()
                guard !isAtEnd else { return nil }
                let next = scalars[index]
                index += 1
                if next == close { break }
                guard next == "," else { return nil }
            }
            let inner = String(repeating: "    ", count: indent + 1)
            return open + "\n" + members.map { inner + $0 + ",\n" }.joined() + String(repeating: "    ", count: indent) + String(close)
        }

        /// A JSON string's value, its escapes decoded (a lone surrogate becomes U+FFFD).
        mutating func string() -> String? {
            guard !isAtEnd, scalars[index] == "\"" else { return nil }
            index += 1
            var result = String.UnicodeScalarView()
            while !isAtEnd {
                let scalar = scalars[index]
                index += 1
                if scalar == "\"" { return String(result) }
                guard scalar == "\\" else {
                    result.append(scalar)
                    continue
                }
                guard !isAtEnd else { return nil }
                let escape = scalars[index]
                index += 1
                switch escape {
                case "b": result.append("\u{8}")
                case "f": result.append("\u{C}")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "u":
                    guard let unit = hex4() else { return nil }
                    if (0xD800..<0xDC00).contains(unit), index + 1 < scalars.count, scalars[index] == "\\", scalars[index + 1] == "u" {
                        let save = index
                        index += 2
                        if let low = hex4(), (0xDC00..<0xE000).contains(low) {
                            result.append(Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)) ?? "\u{FFFD}")
                            continue
                        }
                        index = save
                    }
                    result.append(Unicode.Scalar(unit) ?? "\u{FFFD}")
                default: result.append(escape)
                }
            }
            return nil
        }

        mutating func hex4() -> UInt32? {
            guard index + 4 <= scalars.count, let unit = UInt32(String(String.UnicodeScalarView(scalars[index..<(index + 4)])), radix: 16) else { return nil }
            index += 4
            return unit
        }

        mutating func keyword(_ word: String, as python: String) -> String? {
            let word = Array(word.unicodeScalars)
            guard index + word.count <= scalars.count, Array(scalars[index..<(index + word.count)]) == word else { return nil }
            index += word.count
            return python
        }
    }
}

extension String {
    fileprivate func leftPadded(to width: Int) -> String { String(repeating: "0", count: max(0, width - count)) + self }
}
