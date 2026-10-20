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
    func generate(from request: APIRequest) -> String {
        var code = """
            import Foundation

            """

        let enabledParams = request.queryParams.filter { $0.isEnabled && !$0.key.isEmpty }
        if !enabledParams.isEmpty {
            code += """
                var components = URLComponents(string: "\(request.url)")!
                components.queryItems = [

                """
            for param in enabledParams {
                code += "    URLQueryItem(name: \"\(param.key)\", value: \"\(param.value)\"),\n"
            }
            code += """
                ]
                let url = components.url!

                """
        } else {
            code += """
                let url = URL(string: "\(request.url)")!

                """
        }

        code += """
            var request = URLRequest(url: url)
            request.httpMethod = "\(request.method.rawValue)"

            """

        for header in request.headers where header.isEnabled && !header.key.isEmpty {
            code += "request.setValue(\"\(escapeString(header.value))\", forHTTPHeaderField: \"\(header.key)\")\n"
        }

        switch request.authenticationType {
        case .bearer:
            if let token = request.authBearerToken, !token.isEmpty {
                code += "request.setValue(\"Bearer \(escapeString(token))\", forHTTPHeaderField: \"Authorization\")\n"
            }
        case .basic:
            if let username = request.authBasicUsername,
                let password = request.authBasicPassword
            {
                code += """

                    let credentials = "\(escapeString(username)):\(escapeString(password))"
                    let base64Credentials = Data(credentials.utf8).base64EncodedString()
                    request.setValue("Basic \\(base64Credentials)", forHTTPHeaderField: "Authorization")

                    """
            }
        default:
            break
        }

        if request.bodyType != .none && !request.bodyContent.isEmpty {
            if request.bodyType == .json {
                code += """

                    let jsonBody = \"\"\"
                    \(request.bodyContent)
                    \"\"\"
                    request.httpBody = jsonBody.data(using: .utf8)

                    """
            } else {
                code += "\nrequest.httpBody = \"\(escapeString(request.bodyContent))\".data(using: .utf8)\n"
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

    /// Escapes special characters in strings for safe inclusion in Swift string literals.
    /// Handles backslashes, quotes, and escape sequences to prevent syntax errors.
    ///
    /// - Parameter string: The string to escape
    /// - Returns: The escaped string safe for Swift string literals
    private func escapeString(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
