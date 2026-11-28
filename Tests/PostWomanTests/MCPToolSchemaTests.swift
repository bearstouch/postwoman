import XCTest

@testable import PostWoman

/// Every object schema inside `schema`, with a path for messages.
private func objectSchemas(in schema: JSONValue, path: String) -> [(String, [String: JSONValue])] {
    guard case .object(let object) = schema else { return [] }
    var found: [(String, [String: JSONValue])] = []
    if object["type"] == .string("object") { found.append((path, object)) }
    if case .object(let properties)? = object["properties"] {
        for (name, property) in properties { found += objectSchemas(in: property, path: "\(path).\(name)") }
    }
    if let items = object["items"] { found += objectSchemas(in: items, path: "\(path)[]") }
    return found
}

private func strings(_ value: JSONValue?) -> [String] {
    guard case .array(let items)? = value else { return [] }
    return items.compactMap { if case .string(let text) = $0 { text } else { nil } }
}

final class MCPToolSchemaTests: XCTestCase {
    func testEveryObjectSchemaAtAnyDepthIsClosedAndItsRequiredFieldsExist() {
        for tool in MCPTools.all {
            let schemas = objectSchemas(in: tool.inputSchema, path: tool.name)
            XCTAssertFalse(schemas.isEmpty, tool.name)
            for (path, schema) in schemas {
                XCTAssertEqual(schema["additionalProperties"], .bool(false), path)
                guard case .object(let properties)? = schema["properties"] else {
                    XCTFail("\(path) has no properties")
                    continue
                }
                for name in strings(schema["required"]) { XCTAssertNotNil(properties[name], "\(path) requires \(name)") }
            }
        }
    }

    func testEveryPropertyHasATypeAndADescription() {
        for tool in MCPTools.all {
            for (name, property) in tool.properties {
                XCTAssertNotNil(property["type"], "\(tool.name).\(name)")
                guard case .string(let description)? = property["description"] else {
                    XCTFail("\(tool.name).\(name) has no description")
                    continue
                }
                XCTAssertFalse(description.isEmpty, "\(tool.name).\(name)")
            }
            XCTAssertFalse(tool.description.isEmpty, tool.name)
        }
    }

    func testEnumsListWhatTheHandlerAccepts() {
        XCTAssertEqual(MCPTools.methods, HTTPMethod.allCases.map(\.rawValue))
        XCTAssertEqual(MCPTools.bodyTypes, ["none", "json", "form-data", "urlencoded", "xml", "text"])
        XCTAssertEqual(MCPTools.authTypes, ["none", "bearer", "basic", "oauth2"])
        XCTAssertEqual(strings(MCPTools.requestFields["method"]?["enum"]), MCPTools.methods)
        XCTAssertEqual(strings(MCPTools.requestFields["auth"]?["properties"]?["type"]?["enum"]), MCPTools.authTypes)
        for type in ContentType.allCases { XCTAssertEqual(MCPBodyType(type).contentType, type) }
        for type in AuthenticationType.allCases { XCTAssertEqual(MCPAuthType(type).authenticationType, type) }
    }

    func testIDsAreUUIDStrings() {
        for tool in MCPTools.all {
            for name in ["id", "collectionId", "requestId"] {
                guard let property = tool.properties[name] else { continue }
                XCTAssertEqual(property["type"], .string("string"), "\(tool.name).\(name)")
                XCTAssertEqual(property["format"], .string("uuid"), "\(tool.name).\(name)")
            }
        }
    }

    func testAnnotationsAreConsistent() {
        for tool in MCPTools.all {
            guard case .object(let annotations)? = tool.json["annotations"] else {
                XCTFail(tool.name)
                continue
            }
            XCTAssertEqual(annotations["readOnlyHint"], .bool(tool.readOnly), tool.name)
            XCTAssertEqual(annotations["openWorldHint"], .bool(tool.openWorld), tool.name)
            // A read-only tool has no destructive hint; every other tool states it.
            XCTAssertEqual(annotations["destructiveHint"], tool.readOnly ? nil : .bool(tool.destructive), tool.name)
            XCTAssertFalse(tool.readOnly && tool.destructive, tool.name)
            if tool.name.hasSuffix("_list") || tool.name.hasSuffix("_get") { XCTAssertTrue(tool.readOnly, tool.name) }
            if tool.name.hasSuffix("_delete") || tool.name.hasSuffix("_clear") { XCTAssertTrue(tool.destructive, tool.name) }
            if tool.readOnly { XCTAssertFalse(tool.waits, tool.name) }
        }
        XCTAssertEqual(MCPTools.all.filter(\.openWorld).map(\.name), ["request_execute"], "Only request_execute reaches other servers")
        XCTAssertEqual(MCPTools.all.filter(\.waits).map(\.name), ["request_execute"])
        XCTAssertEqual(Set(MCPTools.all.filter(\.untrusted).map(\.name)), ["request_execute", "history_list", "history_get"])
    }

    func testTheCatalogIsComplete() {
        let expected: Set<String> = [
            "collection_list", "collection_get", "collection_create", "collection_update", "collection_delete", "request_list", "request_get", "request_create",
            "request_update", "request_delete", "request_execute", "environment_list", "environment_get", "environment_create", "environment_update",
            "environment_delete", "environment_select", "history_list", "history_get", "history_create", "history_update", "history_delete", "history_clear"
        ]
        XCTAssertEqual(Set(MCPTools.all.map(\.name)), expected)
        XCTAssertEqual(MCPTools.byName.count, MCPTools.all.count)
    }

    func testCredentialFieldsAreDescribedAsWriteOnly() {
        let auth = MCPTools.requestFields["auth"]
        guard case .string(let description)? = auth?["description"] else { return XCTFail("auth has no description") }
        XCTAssertTrue(description.contains("write-only"))
        guard case .string(let secret)? = MCPTools.byName["environment_update"]?.properties["variables"]?["items"]?["properties"]?["secret"]?["description"] else {
            return XCTFail("secret has no description")
        }
        XCTAssertTrue(secret.contains("write-only"))
    }

    func testRequiredIsOmittedWhenEmpty() {
        XCTAssertNil(MCPTools.byName["collection_list"]?.inputSchema["required"])
        XCTAssertEqual(MCPTools.byName["history_create"]?.inputSchema["required"], .array([.string("url")]))
    }

    func testSuccessfulObjectResultsCarryStructuredContent() throws {
        let tool = try XCTUnwrap(MCPTools.byName["collection_list"])
        let value = JSONValue.object(["a": .number(1)])
        let result = MCPTools.callResult(.success(value), tool: tool)
        XCTAssertEqual(result["isError"], .bool(false))
        XCTAssertEqual(result["structuredContent"], value)
        XCTAssertEqual(result["content"], .array([.object(["type": .string("text"), "text": .string(value.text)])]))
        let array = MCPTools.callResult(.success(.array([.null])), tool: tool)
        XCTAssertNil(array["structuredContent"], "Only objects are structured content")
    }

    func testErrorResultsCarryCodeMessageRetryableAndDetails() throws {
        let tool = try XCTUnwrap(MCPTools.byName["history_get"])
        let result = MCPTools.callResult(.failure(.invalidParams("id must be a UUID.", field: "id")), tool: tool)
        XCTAssertEqual(result["isError"], .bool(true))
        let error = result["structuredContent"]?["error"]
        XCTAssertEqual(error?["code"], .string("INVALID_PARAMS"))
        XCTAssertEqual(error?["message"], .string("id must be a UUID."))
        XCTAssertEqual(error?["retryable"], .bool(false))
        XCTAssertEqual(error?["details"], .object(["field": .string("id")]))
        guard case .array(let content)? = result["content"] else { return XCTFail("No content") }
        XCTAssertEqual(content.count, 1, "Errors carry no untrusted notice: they are PostWoman's own text")
        XCTAssertNil(MCPTools.callResult(.failure(.internalError("x")), tool: tool)["structuredContent"]?["error"]?["details"])
        XCTAssertEqual(MCPToolError.limitExceeded("x").retryable, true)
    }
}

final class JSONValueTests: XCTestCase {
    private func decode(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

    func testDecodesEveryKindAndKeepsBooleansApartFromNumbers() throws {
        let value = try decode(#"{"n":null,"t":true,"f":false,"one":1,"zero":0,"pi":3.5,"neg":-2e3,"s":"x","a":[1,"1",true],"o":{}}"#)
        XCTAssertEqual(value["n"], .null)
        XCTAssertEqual(value["t"], .bool(true))
        XCTAssertEqual(value["f"], .bool(false))
        XCTAssertEqual(value["one"], .number(1))
        XCTAssertEqual(value["zero"], .number(0))
        XCTAssertEqual(value["pi"], .number(3.5))
        XCTAssertEqual(value["neg"], .number(-2000))
        XCTAssertEqual(value["s"], .string("x"))
        XCTAssertEqual(value["a"], .array([.number(1), .string("1"), .bool(true)]))
        XCTAssertEqual(value["o"], .object([:]))
        XCTAssertNil(value["missing"])
        XCTAssertNil(JSONValue.string("x")["key"], "Only objects have keys")
    }

    func testRoundTripsAndEncodesWithSortedKeysAndPlainSlashes() throws {
        let value: JSONValue = .object(["b": .string("http://x/y"), "a": .array([.number(1.5), .null, .bool(false)]), "c": .object(["é": .string("\"q\"\n")])])
        XCTAssertEqual(value.text, #"{"a":[1.5,null,false],"b":"http://x/y","c":{"é":"\"q\"\n"}}"#)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: value.data), value)
    }

    func testAValueThatCannotBeEncodedBecomesAnInternalError() throws {
        let broken = JSONValue.object(["n": .number(.nan)])
        XCTAssertEqual(try decode(broken.text)["error"]?["code"], .number(-32603))
    }

    func testInvalidJSONIsAnError() {
        for text in ["", "{", "{'a':1}", "nul", "[1 2]", "{\"a\" 1}"] {
            XCTAssertThrowsError(try decode(text), text)
        }
    }

    func testNestingIsCountedOnRawBytesIgnoringStrings() {
        func nested(_ depth: Int) -> Data { Data((String(repeating: "[", count: depth) + String(repeating: "]", count: depth)).utf8) }
        XCTAssertFalse(JSONValue.exceedsNesting(nested(64)))
        XCTAssertTrue(JSONValue.exceedsNesting(nested(65)))
        XCTAssertTrue(JSONValue.exceedsNesting(Data(String(repeating: "{\"a\":", count: 65).utf8)), "Unclosed objects count too")
        XCTAssertFalse(JSONValue.exceedsNesting(Data(#"{"a":"\#(String(repeating: "[{", count: 200))"}"#.utf8)), "Brackets inside strings don't count")
        XCTAssertFalse(JSONValue.exceedsNesting(Data(#"{"a":"\"[[[[\\"}"#.utf8)), "Escaped quotes don't end a string")
        XCTAssertTrue(JSONValue.exceedsNesting(nested(3), limit: 2))
        XCTAssertFalse(JSONValue.exceedsNesting(Data(String(repeating: "[]", count: 10_000).utf8)), "Siblings are not depth")
    }

    func testFromHelpersMapNilToNull() {
        XCTAssertEqual(JSONValue.from(nil as String?), .null)
        XCTAssertEqual(JSONValue.from("a"), .string("a"))
        XCTAssertEqual(JSONValue.from(nil as Int?), .null)
        XCTAssertEqual(JSONValue.from(3 as Int?), .number(3))
        XCTAssertEqual(JSONValue.from(nil as Double?), .null)
        XCTAssertEqual(JSONValue.from(Date(timeIntervalSince1970: 0)), .string("1970-01-01T00:00:00Z"))
    }
}

final class RemoteAgentSettingsBoundaryTests: XCTestCase {
    func testPortRangeBoundaries() {
        XCTAssertFalse(RemoteAgentSettings(port: 0).isValid)
        XCTAssertFalse(RemoteAgentSettings(port: 1023).isValid)
        XCTAssertTrue(RemoteAgentSettings(port: 1024).isValid)
        XCTAssertTrue(RemoteAgentSettings(port: 65_535).isValid)
    }

    func testBindAddressesMustBeIPLiterals() {
        for address in ["127.0.0.1", "0.0.0.0", "::", "::1", "192.168.1.2", "fd7a:115c:a1e0::1"] { XCTAssertTrue(RemoteAgentSettings(bindAddress: address).isValid, address) }
        for address in ["", "localhost", "example.com", "127.1", "fe80::1%en0", "1.2.3.4.5", " 127.0.0.1", String(repeating: "1", count: 46)] {
            XCTAssertFalse(RemoteAgentSettings(bindAddress: address).isValid, address)
        }
    }

    func testLoopbackAndTailnetRanges() {
        XCTAssertTrue(IPAddressLiteral("127.255.255.255")?.isLoopback == true)
        XCTAssertFalse(IPAddressLiteral("128.0.0.1")?.isLoopback == true)
        XCTAssertFalse(IPAddressLiteral("::2")?.isLoopback == true)
        XCTAssertFalse(IPAddressLiteral("::ffff:127.0.0.1")?.isLoopback == true, "IPv4-mapped addresses are not treated as loopback")
        XCTAssertTrue(IPAddressLiteral("100.64.0.0")?.isTailnet == true)
        XCTAssertTrue(IPAddressLiteral("100.127.255.255")?.isTailnet == true)
        XCTAssertFalse(IPAddressLiteral("100.63.255.255")?.isTailnet == true)
        XCTAssertFalse(IPAddressLiteral("100.128.0.0")?.isTailnet == true)
        XCTAssertTrue(IPAddressLiteral("fd7a:115c:a1e0::1")?.isTailnet == true)
        XCTAssertFalse(IPAddressLiteral("fd7a:115c:a1e1::1")?.isTailnet == true)
        XCTAssertFalse(RemoteAgentSettings(bindAddress: "::").isLoopback)
    }

    func testClientAndEndpointURLs() {
        XCTAssertEqual(RemoteAgentSettings(bindAddress: "::", port: 9000).clientURL, "http://[::1]:9000/mcp")
        XCTAssertEqual(RemoteAgentSettings(bindAddress: "192.168.1.2", port: 9000).clientURL, "http://192.168.1.2:9000/mcp")
        XCTAssertEqual(RemoteAgentSettings.endpointURL(address: "fd7a::1", port: 1), "http://[fd7a::1]:1/mcp")
    }

    func testPartialOrUnreadableSavedSettingsFallBackToDefaults() throws {
        let suite = "PostWomanTests.settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"mcpEnabled":true}"#.utf8), forKey: RemoteAgentSettings.defaultsKey)
        XCTAssertEqual(RemoteAgentSettings.load(from: defaults), RemoteAgentSettings(mcpEnabled: true))
        defaults.set(Data(#"{"port":70000}"#.utf8), forKey: RemoteAgentSettings.defaultsKey)
        XCTAssertEqual(RemoteAgentSettings.load(from: defaults), RemoteAgentSettings(), "An out-of-range port is unreadable, so the server stays off")
        defaults.set(Data("garbage".utf8), forKey: RemoteAgentSettings.defaultsKey)
        XCTAssertEqual(RemoteAgentSettings.load(from: defaults), RemoteAgentSettings())
        defaults.set("not data", forKey: RemoteAgentSettings.defaultsKey)
        XCTAssertFalse(RemoteAgentSettings.load(from: defaults).mcpEnabled)
    }

    func testTokensAreLongRandomAndURLSafe() {
        let tokens = (0..<50).map { _ in RemoteAgentToken.generate() }
        XCTAssertEqual(Set(tokens).count, 50)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        for token in tokens {
            XCTAssertTrue(token.hasPrefix("pwm_"))
            XCTAssertEqual(token.count, 4 + 43, "32 bytes in unpadded base64url")
            XCTAssertTrue(token.dropFirst(4).allSatisfy(allowed.contains), token)
        }
    }

    func testAnInvalidSavedTokenIsReplacedAndPermissionsAreTightened() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pw-token-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "nested").appending(path: "token")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for invalid in ["", "pwm_short", "abc_0123456789012345678901234567890123456789"] {
            try Data(invalid.utf8).write(to: url)
            let token = RemoteAgentToken.loadOrCreate(at: url)
            XCTAssertNotEqual(token, invalid)
            XCTAssertTrue(token.hasPrefix("pwm_"))
        }
        let saved = "pwm_" + String(repeating: "k", count: 40)
        try Data("  \(saved)\n".utf8).write(to: url)
        XCTAssertEqual(RemoteAgentToken.loadOrCreate(at: url), saved, "Surrounding whitespace is ignored")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let regenerated = RemoteAgentToken.regenerate(at: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), regenerated)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600, "An existing file is made private again")
    }

    func testClientSnippetsUseThePlaceholderOrEnvironmentVariable() {
        XCTAssertTrue(MCPClientSetup.claudeCode.snippet(url: "u").contains("Bearer <TOKEN>"))
        XCTAssertTrue(MCPClientSetup.codex.snippet(url: "u").contains(MCPClientSetup.tokenVariable))
        XCTAssertTrue(MCPClientSetup.json.snippet(url: "u").contains(#""url": "u""#))
    }
}
