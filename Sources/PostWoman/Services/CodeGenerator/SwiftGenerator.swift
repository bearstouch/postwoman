import Foundation

/// Generates Swift code using URLSession from API request configurations.
/// Produces executable Swift code that replicates HTTP requests with proper
/// handling of authentication, headers, query parameters, and different body types.
struct SwiftGenerator {
    /// Generates Swift code that replicates the given API request using URLSession.
    /// The generated code includes URL construction, headers, authentication,
    /// query parameters, request body, and basic response handling.
    ///
    /// - Parameters:
    ///   - request: The API request to convert to Swift code
    /// - Returns: A complete Swift code snippet as a string
    func generate(from request: some RequestFields) -> String {
        var code = """
            import Foundation

            """

        let enabledParams = request.queryParams.filter { $0.isEnabled && !$0.key.isEmpty }
        if !enabledParams.isEmpty {
            code += """
                var components = URLComponents(string: \(SwiftLiteral.string(RequestURL.encoded(request.url))))!
                let queryItems = [

                """
            for param in enabledParams {
                code += "    URLQueryItem(name: \(SwiftLiteral.string(param.key)), value: \(SwiftLiteral.string(param.value))),\n"
            }
            code += """
                ]
                // Added after the URL's own query (kept as written), encoded so & = + # in a name or value stay data.
                let queryAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))
                let addedQuery = queryItems.map { item in
                    [item.name, item.value ?? ""].map { $0.addingPercentEncoding(withAllowedCharacters: queryAllowed)! }.joined(separator: "=")
                }.joined(separator: "&")
                components.percentEncodedQuery = [components.percentEncodedQuery ?? "", addedQuery].filter { !$0.isEmpty }.joined(separator: "&")
                let url = components.url!

                """
        } else {
            code += """
                let url = URL(string: \(SwiftLiteral.string(RequestURL.encoded(request.url))))!

                """
        }

        code += """
            var request = URLRequest(url: url)
            request.httpMethod = "\(request.method.rawValue)"

            """

        for header in request.headers where header.isEnabled && !header.key.isEmpty {
            code += "request.setValue(\(SwiftLiteral.string(header.value)), forHTTPHeaderField: \(SwiftLiteral.string(header.key)))\n"
        }

        switch request.authenticationType {
        case .bearer:
            if let token = request.authBearerToken, !token.isEmpty {
                code += "request.setValue(\(SwiftLiteral.string("Bearer " + token)), forHTTPHeaderField: \"Authorization\")\n"
            }
        case .basic:
            if let (username, password) = AuthenticationHandler.basicCredentials(username: request.authBasicUsername, password: request.authBasicPassword) {
                code += """

                    let credentials = \(SwiftLiteral.string(username + ":" + password))
                    let base64Credentials = Data(credentials.utf8).base64EncodedString()
                    request.setValue("Basic \\(base64Credentials)", forHTTPHeaderField: "Authorization")

                    """
            }
        default:
            break
        }

        if request.sendsBody, let fields = MultipartForm.fields(of: request), fields.isEmpty {
            // No named field, nothing to send.
        } else if request.sendsBody, let fields = MultipartForm.fields(of: request) {
            let literals = fields.map { "(\(SwiftLiteral.string(MultipartForm.escapedName($0.key))), \(SwiftLiteral.string($0.value)))" }
            code += """

                let boundary = "Boundary-\\(UUID().uuidString)"
                let fields: [(name: String, value: String)] = [\(literals.joined(separator: ", "))]
                var form = ""
                for field in fields {
                    form += "--\\(boundary)\\r\\nContent-Disposition: form-data; name=\\"\\(field.name)\\"\\r\\n\\r\\n\\(field.value)\\r\\n"
                }
                form += "--\\(boundary)--\\r\\n"
                request.httpBody = Data(form.utf8)
                request.setValue("multipart/form-data; boundary=\\(boundary)", forHTTPHeaderField: "Content-Type")

                """
        } else if request.sendsBody {
            if request.bodyType == .json {
                code += """

                    let jsonBody = \(SwiftLiteral.block(request.bodyContent))
                    request.httpBody = jsonBody.data(using: .utf8)

                    """
            } else {
                code += "\nrequest.httpBody = \(SwiftLiteral.string(request.bodyContent)).data(using: .utf8)\n"
            }

            if request.headers.first(where: { $0.key.lowercased() == "content-type" && $0.isEnabled }) == nil,
                let mimeType = request.bodyType.mimeType
            {
                code += "request.setValue(\"\(mimeType)\", forHTTPHeaderField: \"Content-Type\")\n"
            }
        }

        code += """

            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    print("Error: \\(error.localizedDescription)")
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    print("Invalid response")
                    return
                }

                print("Status Code: \\(httpResponse.statusCode)")

                if let data = data, let body = String(data: data, encoding: .utf8) {
                    print("Response Body:")
                    print(body)
                }
            }
            task.resume()

            // Keep the program running to allow the async request to complete
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 30))
            """

        return code
    }
}

/// Swift string literals for generated code, so every value reaches the generated request exactly as the user wrote it.
enum SwiftLiteral {
    /// `text` as a one-line `"…"` literal: quotes, backslashes (so no `\(` interpolation), newlines and control characters escaped.
    static func string(_ text: String) -> String {
        "\"" + escaped(text, escape: "\\", raw: false) + "\""
    }

    /// `text` as a raw multiline literal (`#"""` … `"""#`) that keeps its lines readable. It uses one more `#` than the longest run of
    /// `#` in `text`, so nothing in it can close the literal, start an escape or interpolate; carriage returns and other control
    /// characters are written as escapes, because a multiline literal would normalize or reject them.
    static func block(_ text: String) -> String {
        var longest = 0
        var run = 0
        for scalar in text.unicodeScalars {
            run = scalar == "#" ? run + 1 : 0
            longest = max(longest, run)
        }
        let hashes = String(repeating: "#", count: longest + 1)
        return hashes + "\"\"\"\n" + escaped(text, escape: "\\" + hashes, raw: true) + "\n\"\"\"" + hashes
    }

    /// `text` with what a literal can't hold as written replaced by escapes starting with `escape` (`\`, or `\#…` in a raw literal).
    /// A raw literal keeps quotes, backslashes, newlines and tabs as text.
    private static func escaped(_ text: String, escape: String, raw: Bool) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n" where raw, "\t" where raw: result.unicodeScalars.append(scalar)
            case "\\" where !raw: result += "\\\\"
            case "\"" where !raw: result += "\\\""
            case "\n": result += escape + "n"
            case "\r": result += escape + "r"
            case "\t": result += escape + "t"
            case _ where scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value): result += escape + "u{" + String(scalar.value, radix: 16) + "}"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
