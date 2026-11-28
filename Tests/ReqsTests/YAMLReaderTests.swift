import XCTest

@testable import Reqs

final class YAMLReaderTests: XCTestCase {
    func testNestedMappingsAndSequencesOfMappings() throws {
        let yaml = """
            openapi: 3.0.3
            info:
              title: Pets   # the API's name
              version: "1.0"
            servers:
              - url: https://api.example.com/v1
                description: Production
              - url: http://localhost:8080
            tags:
            - name: pets
            - name: owners
            """
        let tree = try YAMLReader.parse(yaml)
        XCTAssertEqual(tree["openapi"], .string("3.0.3"))
        XCTAssertEqual(tree["info"]?["title"], .string("Pets"))
        XCTAssertEqual(tree["info"]?["version"], .string("1.0"))
        XCTAssertEqual(tree["servers"]?[0]?["url"], .string("https://api.example.com/v1"))
        XCTAssertEqual(tree["servers"]?[0]?["description"], .string("Production"))
        XCTAssertEqual(tree["servers"]?[1]?["url"], .string("http://localhost:8080"))
        XCTAssertEqual(tree["tags"]?.arrayItems?.compactMap { $0["name"]?.scalarText }, ["pets", "owners"])
    }

    func testScalarsKeepTheirTypesAndLongNumbersStayText() throws {
        let tree = try YAMLReader.parse(
            """
            yes: true
            no: false
            nothing: ~
            empty:
            count: 42
            ratio: -1.5
            id: 12345678901234567890
            zip: 01234
            version: 3.0.0
            url: http://host:80/path
            """)
        XCTAssertEqual(tree["yes"], .bool(true))
        XCTAssertEqual(tree["no"], .bool(false))
        XCTAssertEqual(tree["nothing"], .null)
        XCTAssertEqual(tree["empty"], .null)
        XCTAssertEqual(tree["count"], .number(42))
        XCTAssertEqual(tree["ratio"], .number(-1.5))
        XCTAssertEqual(tree["id"], .string("12345678901234567890"))
        XCTAssertEqual(tree["zip"], .string("01234"))
        XCTAssertEqual(tree["version"], .string("3.0.0"))
        XCTAssertEqual(tree["url"], .string("http://host:80/path"))
    }

    func testQuotedScalarsAndEscapes() throws {
        let tree = try YAMLReader.parse(
            #"""
            double: "a \"quoted\" # not a comment\né"
            single: 'it''s # here'
            "quoted key": value
            colon: "a: b"
            """#)
        XCTAssertEqual(tree["double"], .string("a \"quoted\" # not a comment\né"))
        XCTAssertEqual(tree["single"], .string("it's # here"))
        XCTAssertEqual(tree["quoted key"], .string("value"))
        XCTAssertEqual(tree["colon"], .string("a: b"))
    }

    func testBlockScalarsFollowChompingAndFolding() throws {
        let tree = try YAMLReader.parse(
            """
            literal: |
              {"name": "Ada",
                "id": 1}
            stripped: |-
              line one
              line two

            folded: >
              one
              two

              three
            kept: |+
              end

            next: value
            """)
        XCTAssertEqual(tree["literal"], .string("{\"name\": \"Ada\",\n  \"id\": 1}\n"))
        XCTAssertEqual(tree["stripped"], .string("line one\nline two"))
        XCTAssertEqual(tree["folded"], .string("one two\nthree\n"))
        XCTAssertEqual(tree["kept"], .string("end\n\n"))
        XCTAssertEqual(tree["next"], .string("value"))
    }

    func testFlowCollectionsAndMultiLinePlainScalars() throws {
        let tree = try YAMLReader.parse(
            """
            list: [a, "b, c", 3]
            map: {type: string, enum: [x, y]}
            spread: [
              one,
              two
            ]
            description: This text
              continues here
            """)
        XCTAssertEqual(tree["list"], .array([.string("a"), .string("b, c"), .number(3)]))
        XCTAssertEqual(tree["map"]?["type"], .string("string"))
        XCTAssertEqual(tree["map"]?["enum"], .array([.string("x"), .string("y")]))
        XCTAssertEqual(tree["spread"], .array([.string("one"), .string("two")]))
        XCTAssertEqual(tree["description"], .string("This text continues here"))
    }

    func testAnchorsAliasesAndMergeKeys() throws {
        let tree = try YAMLReader.parse(
            """
            base: &base
              a: 1
              b: 2
            copy: *base
            merged:
              <<: *base
              b: 3
            """)
        XCTAssertEqual(tree["copy"], tree["base"])
        XCTAssertEqual(tree["merged"]?["a"], .number(1))
        XCTAssertEqual(tree["merged"]?["b"], .number(3))
    }

    func testOnlyTheFirstDocumentIsRead() throws {
        let tree = try YAMLReader.parse("%YAML 1.2\n---\nfirst: 1\n---\nsecond: 2\n")
        XCTAssertEqual(tree, .object(["first": .number(1)]))
    }

    func testNestedSequencesAndEmptyItems() throws {
        let tree = try YAMLReader.parse("matrix:\n  - - 1\n    - 2\n  - - 3\nitems:\n  -\n  - x\n")
        XCTAssertEqual(tree["matrix"], .array([.array([.number(1), .number(2)]), .array([.number(3)])]))
        XCTAssertEqual(tree["items"], .array([.null, .string("x")]))
    }

    func testWindowsLineEndingsAndByteOrderMark() throws {
        let tree = try YAMLReader.parse("\u{FEFF}a: 1\r\nb:\r\n  c: two\r\n")
        XCTAssertEqual(tree["a"], .number(1))
        XCTAssertEqual(tree["b"]?["c"], .string("two"))
    }

    func testMalformedInputFailsWithALine() {
        XCTAssertThrowsError(try YAMLReader.parse("a: \"open\nb: 1")) { error in
            XCTAssertEqual((error as? YAMLReader.Failure)?.line, 1)
        }
        XCTAssertThrowsError(try YAMLReader.parse("a: *missing"))
        XCTAssertThrowsError(try YAMLReader.parse("? complex\n: key"))
        XCTAssertThrowsError(try YAMLReader.parse("list: [a, b"))
    }

    func testDeepNestingIsRefusedInsteadOfCrashing() {
        let deep = (0..<300).map { String(repeating: " ", count: $0) + "k:" }.joined(separator: "\n")
        XCTAssertThrowsError(try YAMLReader.parse(deep))
        XCTAssertThrowsError(try YAMLReader.parse("a: " + String(repeating: "[", count: 300) + String(repeating: "]", count: 300)))
    }
}
