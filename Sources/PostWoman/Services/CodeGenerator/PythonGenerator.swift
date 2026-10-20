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
    func generate(from request: APIRequest) -> String {
        var code = """
            import requests

            url = "\(request.url)"

            """

        let enabledParams = request.queryParams.filter { $0.isEnabled && !$0.key.isEmpty }
        if !enabledParams.isEmpty {
            code += "params = {\n"
            for param in enabledParams {
                code += "    \"\(param.key)\": \"\(escapeString(param.value))\",\n"
            }
            code += "}\n\n"
        }

        let enabledHeaders = request.headers.filter { $0.isEnabled && !$0.key.isEmpty }
        var hasHeaders = !enabledHeaders.isEmpty

        if request.authenticationType == .bearer, let token = request.authBearerToken, !token.isEmpty {
            hasHeaders = true
        }

        if hasHeaders {
            code += "headers = {\n"
            for header in enabledHeaders {
                code += "    \"\(header.key)\": \"\(escapeString(header.value))\",\n"
            }

            if request.authenticationType == .bearer,
                let token = request.authBearerToken, !token.isEmpty
            {
                code += "    \"Authorization\": \"Bearer \(escapeString(token))\",\n"
            }

            code += "}\n\n"
        }

        var authParam = ""
        if request.authenticationType == .basic,
            let username = request.authBasicUsername,
            let password = request.authBasicPassword
        {
            code += "auth = (\"\(escapeString(username))\", \"\(escapeString(password))\")\n\n"
            authParam = ", auth=auth"
        }

        var bodyParam = ""
        if request.bodyType != .none && !request.bodyContent.isEmpty {
            if request.bodyType == .json {
                code += """
                    json_data = \(formatPythonDict(request.bodyContent))

                    """
                bodyParam = ", json=json_data"
            } else if request.bodyType == .formData || request.bodyType == .urlEncoded {
                code += "data = \"\"\"\(request.bodyContent)\"\"\"\n\n"
                bodyParam = ", data=data"
            } else {
                code += "data = \"\"\"\(request.bodyContent)\"\"\"\n\n"
                bodyParam = ", data=data"
            }
        }

        let paramsArg = enabledParams.isEmpty ? "" : ", params=params"
        let headersArg = hasHeaders ? ", headers=headers" : ""

        let methodName = request.method.rawValue.lowercased()
        code += """
            response = requests.\(methodName)(url\(paramsArg)\(headersArg)\(bodyParam)\(authParam))

            print(f"Status Code: {response.status_code}")
            print(f"Headers: {dict(response.headers)}")
            print(f"Response Body:")
            print(response.text)

            # For JSON responses, you can also use:
            # print(response.json())
            """

        return code
    }

    /// Escapes special characters in strings for safe inclusion in Python code.
    /// Handles backslashes, quotes, and newlines to prevent syntax errors.
    ///
    /// - Parameter string: The string to escape
    /// - Returns: The escaped string safe for Python string literals
    private func escapeString(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Converts JSON strings to Python dictionary syntax.
    /// Attempts to parse JSON and convert it to properly formatted Python dict syntax,
    /// converting JSON null/true/false to Python None/True/False.
    ///
    /// - Parameter jsonString: JSON string to convert
    /// - Returns: Python dictionary syntax or triple-quoted string if conversion fails
    private func formatPythonDict(_ jsonString: String) -> String {
        // Try to pretty-print the JSON as a Python dict
        guard let data = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data, options: []),
            let prettyData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
            let prettyString = String(data: prettyData, encoding: .utf8)
        else {
            return "\"\"\"\(jsonString)\"\"\""
        }

        // Convert JSON syntax to Python syntax
        let pythonDict =
            prettyString
            .replacingOccurrences(of: "null", with: "None")
            .replacingOccurrences(of: "true", with: "True")
            .replacingOccurrences(of: "false", with: "False")

        return pythonDict
    }
}
