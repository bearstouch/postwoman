import XCTest

@testable import Reqs

/// Files that once crashed, hung or misread an import: each must fail with a message, or import as written, quickly.
final class ImportHardeningTests: XCTestCase {
    private func read(_ text: String, fileName: String = "file.yaml") throws -> ImportedFile {
        try CollectionImport.read(Data(text.utf8), fileName: fileName)
    }

    // MARK: YAML

    func testUnclosedFlowAfterAnApostropheFailsInsteadOfCrashing() {
        XCTAssertThrowsError(try YAMLReader.parse("x: [a', [b, 'c]', d',"))
    }

    func testApostrophesInsidePlainFlowScalars() throws {
        XCTAssertEqual(try YAMLReader.parse("enum: [don't, do]")["enum"], .array([.string("don't"), .string("do")]))
        XCTAssertEqual(try YAMLReader.parse("a: [it's]")["a"], .array([.string("it's")]))
    }

    func testAliasBombsAreRefused() {
        var yaml = "l0: &l0 [x, x, x, x, x, x, x, x, x, x]\n"
        for level in 1...6 { yaml += "l\(level): &l\(level) [" + Array(repeating: "*l\(level - 1)", count: 10).joined(separator: ", ") + "]\n" }
        let start = Date()
        XCTAssertThrowsError(try YAMLReader.parse(yaml)) { error in XCTAssertTrue(error.localizedDescription.contains("too much data")) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testAliasChainsCantNestPastTheLimit() {
        var yaml = "l0: &l0 [x]\n"
        for level in 1...2_000 { yaml += "l\(level): &l\(level) [*l\(level - 1)]\n" }
        XCTAssertThrowsError(try YAMLReader.parse(yaml)) { error in XCTAssertTrue(error.localizedDescription.contains("nested too deeply")) }
    }

    func testAnAnchorOnACompactMappingNamesTheMapping() throws {
        let tree = try YAMLReader.parse("items:\n  - &a name: x\n    url: y\ncopy: *a\n")
        XCTAssertEqual(tree["items"]?[0], .object(["name": .string("x"), "url": .string("y")]))
        XCTAssertEqual(tree["copy"], tree["items"]?[0])
    }

    func testStringTagsKeepText() throws {
        XCTAssertEqual(try YAMLReader.parse("a: !!str 123")["a"], .string("123"))
    }

    func testEscapedLineBreakJoinsWithoutASpace() throws {
        XCTAssertEqual(try YAMLReader.parse("a: \"line1\\\n  line2\"")["a"], .string("line1line2"))
    }

    func testNumbersKeepTheirSpelling() throws {
        let tree = try YAMLReader.parse("a: 1.10\nb: 1.0\nc: 2\nd: 2.5")
        XCTAssertEqual(tree["a"]?.scalarText, "1.10")
        XCTAssertEqual(tree["b"]?.scalarText, "1.0")
        XCTAssertEqual(tree["c"], .number(2))
        XCTAssertEqual(tree["d"], .number(2.5))
    }

    func testLongMultiLineStringsAndFlowsAreReadQuickly() throws {
        let start = Date()
        let quoted = "a: \"" + Array(repeating: "word", count: 5_000).joined(separator: "\n  ") + "\"\n"
        XCTAssertEqual(try YAMLReader.parse(quoted)["a"]?.scalarText?.count, 5_000 * 5 - 1)
        let flow = "a: [\n" + Array(repeating: "  x,", count: 5_000).joined(separator: "\n") + "\n]\n"
        XCTAssertEqual(try YAMLReader.parse(flow)["a"]?.arrayItems?.count, 5_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testBrokenJSONFailsAsJSONQuickly() {
        let broken = "{\n" + Array(repeating: "  \"k\": 1, // comment", count: 5_000).joined(separator: "\n") + "\n}"
        let start = Date()
        XCTAssertThrowsError(try read(broken, fileName: "broken.json")) { error in
            XCTAssertEqual(error as? CollectionImport.Failure, .unreadable("broken.json", "it isn't valid JSON."))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    // MARK: Importers

    func testInsomniaFoldersThatAreTheirOwnParentsDontLoop() throws {
        let file = try read(
            #"{"_type":"export","resources":[{"_type":"workspace","_id":"w","name":"W"},{"_type":"request_group","_id":"w","parentId":"w"},{"_type":"request_group","_id":"g","parentId":"w"},{"_type":"request_group","_id":"g","parentId":"g"},{"_type":"request","_id":"r","parentId":"g","name":"R","url":"https://h"}]}"#,
            fileName: "cycle.json")
        XCTAssertEqual(file.collections.first?.requests.count, 1)
    }

    func testTooManyRequestsAreRefused() {
        let items = Array(repeating: #"{"name":"r","request":"https://h"}"#, count: CollectionImport.maximumRequests + 1).joined(separator: ",")
        XCTAssertThrowsError(try read(#"{"info":{"name":"Big"},"item":["# + items + "]}", fileName: "big.json")) { error in
            XCTAssertTrue(error.localizedDescription.contains("more than the 20000"))
        }
    }

    func testOpenAPISchemasThatReferToEachOtherWidelyStaySmall() throws {
        var schemas: [String] = []
        for index in 0..<5 {
            let properties = (0..<25).map { "p\($0): {$ref: '#/components/schemas/S\((index + 1) % 5)'}" }.joined(separator: ", ")
            schemas.append("    S\(index): {type: object, properties: {\(properties)}}")
        }
        let spec = """
            openapi: 3.0.0
            info: {title: Wide}
            paths:
              /x:
                post:
                  requestBody:
                    content:
                      application/json:
                        schema: {$ref: '#/components/schemas/S0'}
            components:
              schemas:
            \(schemas.joined(separator: "\n"))
            """
        let start = Date()
        let body = try XCTUnwrap(try read(spec).collections.first?.requests.first?.bodyContent)
        XCTAssertLessThan(body.count, 100_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    @MainActor func testPostmanQueryValuesAreDecodedOnce() throws {
        let file = try read(
            #"{"info":{"name":"Q"},"item":[{"name":"R","request":{"method":"GET","url":{"raw":"https://h/?redirect=https%3A%2F%2Fx&q=a%20b","query":[{"key":"redirect","value":"https%3A%2F%2Fx"},{"key":"q","value":"a%20b"},{"key":"pct","value":"100%"}]}}}]}"#,
            fileName: "q.json")
        let params = try XCTUnwrap(file.collections.first?.requests.first?.queryParams)
        XCTAssertEqual(params.map(\.value), ["https://x", "a b", "100%"])
        XCTAssertEqual(HTTPClient.encodedQuery(params), "redirect=https://x&q=a%20b&pct=100%25")
    }

    func testInsomniaCookieAPIKeysAreSentAsACookie() throws {
        let file = try read(
            #"{"_type":"export","resources":[{"_type":"workspace","_id":"w","name":"W"},{"_type":"request","_id":"r","parentId":"w","name":"R","url":"https://h","authentication":{"type":"apikey","key":"session","value":"abc","addTo":"cookie"}}]}"#,
            fileName: "cookie.json")
        XCTAssertEqual(file.collections.first?.requests.first?.headers.map { "\($0.key): \($0.value)" }, ["Cookie: session=abc"])
    }

    func testInsomniaV5FolderHeadersAreInherited() throws {
        let yaml = """
            type: collection.insomnia.rest/5.0
            name: H
            collection:
              - name: F
                headers:
                  - name: X-Team
                    value: core
                  - name: Accept
                    value: text/plain
                children:
                  - url: https://h
                    name: R
                    method: GET
                    headers:
                      - name: Accept
                        value: application/json
            """
        let headers = try XCTUnwrap(try read(yaml).collections.first?.requests.first?.headers)
        XCTAssertEqual(headers.map { "\($0.key): \($0.value)" }, ["X-Team: core", "Accept: application/json"])
    }

    func testSwaggerKeepsTheJSONBodyWhenJSONIsAmongWhatItConsumes() throws {
        let file = try read(
            #"{"swagger":"2.0","info":{"title":"S"},"host":"h","paths":{"/x":{"post":{"consumes":["application/xml","application/json"],"parameters":[{"in":"body","name":"b","schema":{"type":"object","properties":{"a":{"type":"string"}}}}]}}}}"#,
            fileName: "s.json")
        XCTAssertEqual(file.collections.first?.requests.first?.bodyType, .json)
        XCTAssertTrue(file.collections.first?.requests.first?.bodyContent.contains("\"a\"") == true)
    }

    func testTraceOperationsAreLeftOutWithANote() throws {
        let file = try read("openapi: 3.0.0\ninfo: {title: T}\npaths:\n  /x:\n    get: {}\n    trace: {}\n")
        XCTAssertEqual(file.collections.first?.requests.map(\.method), [.get])
        XCTAssertTrue(file.notes.contains { $0.contains("TRACE") })
    }
}
