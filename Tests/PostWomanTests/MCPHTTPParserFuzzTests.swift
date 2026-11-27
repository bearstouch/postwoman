import XCTest

@testable import PostWoman

/// Parses `raw` in one read: the requests, or the status its error maps to.
private func parse(_ raw: String) -> Result<[MCPHTTPRequest], MCPHTTPParseError> {
    parseBytes(Data(raw.utf8))
}

private func parseBytes(_ data: Data) -> Result<[MCPHTTPRequest], MCPHTTPParseError> {
    var parser = MCPHTTPRequestParser()
    do {
        return .success(try parser.append(data))
    } catch {
        return .failure(error)
    }
}

private func status(_ raw: String) -> Int? {
    if case .failure(let error) = parse(raw) { return error.status }
    return nil
}

/// A request line plus `extra` header lines and the end of the head.
private func head(_ extra: [String], requestLine: String = "POST /mcp HTTP/1.1") -> String {
    ([requestLine] + extra).joined(separator: "\r\n") + "\r\n\r\n"
}

/// Deterministic xorshift, so fuzz failures can be replayed.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

final class MCPHTTPParserBoundaryTests: XCTestCase {
    // MARK: Content-Length

    func testContentLengthMustBePlainASCIIDigits() {
        for value in ["+1", "-1", "1,1", "1 1", "0x10", "1.0", " ", "abc", "١", "1e3", "123456789"] {
            XCTAssertEqual(status(head(["Host: localhost", "Content-Length: \(value)"])), 400, "Content-Length: \(value)")
        }
    }

    func testAnEmptyContentLengthIsMalformed() {
        XCTAssertEqual(status("POST /mcp HTTP/1.1\r\nContent-Length:\r\n\r\n"), 400)
    }

    func testContentLengthAtTheBodyLimitIsAcceptedAndOneMoreIs413() {
        let limit = MCPHTTPRequestParser.maximumBody
        // The limit itself waits for the body instead of failing.
        guard case .success(let none) = parse(head(["Content-Length: \(limit)"])) else { return XCTFail("The limit must be accepted") }
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(status(head(["Content-Length: \(limit + 1)"])), 413)
        XCTAssertEqual(status(head(["Content-Length: 99999999"])), 413, "Eight digits are parsed, then refused as too large")
    }

    func testLeadingZerosAndARepeatedEqualContentLengthAreAccepted() throws {
        let raw = head(["Content-Length: 0002", "content-length: 0002"]) + "{}"
        let requests = try parse(raw).get()
        XCTAssertEqual(requests.first?.body, Data("{}".utf8))
        XCTAssertEqual(status(head(["Content-Length: 2", "Content-Length: 02"])), 400, "Different spellings of a length are a conflict")
    }

    func testAnyTransferEncodingIsRefusedEvenWithAContentLength() {
        XCTAssertEqual(status(head(["Content-Length: 2", "Transfer-Encoding: identity"]) + "{}"), 411)
        XCTAssertEqual(status(head(["transfer-encoding: gzip, chunked"])), 411)
    }

    func testTheBodyIsCutAtContentLengthAndTheRestStartsTheNextRequest() throws {
        var parser = MCPHTTPRequestParser()
        let requests = try parser.append(Data((head(["Content-Length: 2"]) + "{}GET /x HTTP/1.1\r\n").utf8))
        XCTAssertEqual(requests.map(\.body), [Data("{}".utf8)])
        XCTAssertTrue(parser.hasPartialRequest, "Bytes after the body belong to the next request")
        XCTAssertEqual(try parser.append(Data("\r\n".utf8)).map(\.path), ["/x"])
        XCTAssertFalse(parser.hasPartialRequest)
    }

    // MARK: Header limits

    func testHeadersUpToTheByteLimitAreAcceptedInOneRead() throws {
        let prefix = "GET /mcp HTTP/1.1\r\nX: "
        let filler = String(repeating: "a", count: MCPHTTPRequestParser.maximumHeaderBytes - prefix.utf8.count)
        let exact = prefix + filler
        XCTAssertEqual(exact.utf8.count, MCPHTTPRequestParser.maximumHeaderBytes)
        XCTAssertEqual(try parse(exact + "\r\n\r\n").get().count, 1)
        XCTAssertEqual(status(exact + "a\r\n\r\n"), 431)
    }

    func testAHeadAtTheByteLimitIsAcceptedHoweverTheTerminatorIsSplit() throws {
        let prefix = "GET /mcp HTTP/1.1\r\nX: "
        let exact = prefix + String(repeating: "a", count: MCPHTTPRequestParser.maximumHeaderBytes - prefix.utf8.count)
        for split in [["\r", "\n", "\r", "\n"], ["\r\n", "\r\n"], ["\r\n\r", "\n"], ["\r\n\r\n"]] {
            var parser = MCPHTTPRequestParser()
            XCTAssertEqual(try parser.append(Data(exact.utf8)).count, 0)
            var requests: [MCPHTTPRequest] = []
            for piece in split { requests += try parser.append(Data(piece.utf8)) }
            XCTAssertEqual(requests.count, 1, "\(split)")
            XCTAssertEqual(requests.first?.header("X")?.utf8.count, MCPHTTPRequestParser.maximumHeaderBytes - prefix.utf8.count)
            XCTAssertFalse(parser.hasPartialRequest)
        }
        // A head of one byte under the limit, with its terminator split too.
        var shorter = MCPHTTPRequestParser()
        XCTAssertEqual(try shorter.append(Data(exact.dropLast().utf8)).count, 0)
        XCTAssertEqual(try shorter.append(Data("\r\n\r".utf8)).count, 0)
        XCTAssertEqual(try shorter.append(Data("\n".utf8)).count, 1)
    }

    func testAHeadOverTheByteLimitIs431HoweverItIsSplit() {
        let prefix = "GET /mcp HTTP/1.1\r\nX: "
        let over = prefix + String(repeating: "a", count: MCPHTTPRequestParser.maximumHeaderBytes + 1 - prefix.utf8.count)
        for split in [["\r", "\n", "\r", "\n"], ["\r\n", "\r\n"], ["\r\n\r\n"]] {
            var parser = MCPHTTPRequestParser()
            var thrown: MCPHTTPParseError?
            do {
                _ = try parser.append(Data(over.utf8))
                for piece in split { _ = try parser.append(Data(piece.utf8)) }
            } catch { thrown = error }
            XCTAssertEqual(thrown, .headersTooLarge, "\(split)")
        }
        // Unterminated data past the limit is refused at once, so the buffer stays bounded.
        var parser = MCPHTTPRequestParser()
        let exact = prefix + String(repeating: "a", count: MCPHTTPRequestParser.maximumHeaderBytes - prefix.utf8.count)
        XCTAssertThrowsError(try parser.append(Data((exact + "\r\na").utf8))) { XCTAssertEqual($0 as? MCPHTTPParseError, .headersTooLarge) }
    }

    func testAHeadThatNeverEndsIsRefusedOnceItPassesTheLimit() {
        var parser = MCPHTTPRequestParser()
        XCTAssertNoThrow(try parser.append(Data(String(repeating: "a", count: MCPHTTPRequestParser.maximumHeaderBytes).utf8)))
        XCTAssertThrowsError(try parser.append(Data("a".utf8))) { XCTAssertEqual($0 as? MCPHTTPParseError, .headersTooLarge) }
    }

    func testBareLineFeedsNeverEndAHeadSoTheyHitTheLimit() {
        var parser = MCPHTTPRequestParser()
        XCTAssertEqual(try parser.append(Data("GET /mcp HTTP/1.1\nHost: localhost\n\n".utf8)).count, 0, "LF LF is not the end of a head")
        XCTAssertTrue(parser.hasPartialRequest)
        XCTAssertThrowsError(try parser.append(Data(String(repeating: "\n", count: MCPHTTPRequestParser.maximumHeaderBytes).utf8))) {
            XCTAssertEqual($0 as? MCPHTTPParseError, .headersTooLarge)
        }
    }

    func testAtMostSixtyFourHeaderLines() throws {
        let lines = (0..<MCPHTTPRequestParser.maximumHeaderCount).map { "X-\($0): v" }
        XCTAssertEqual(try parse(head(lines)).get().first?.headers.count, MCPHTTPRequestParser.maximumHeaderCount)
        XCTAssertEqual(status(head(lines + ["X-Extra: v"])), 431)
    }

    func testObsoleteLineFoldingAndSpaceBeforeTheColonAreMalformed() {
        XCTAssertEqual(status(head(["Host: localhost", "X-A: one", " folded"])), 400)
        XCTAssertEqual(status(head(["Host: localhost", "X-A: one", "\tfolded: two"])), 400)
        XCTAssertEqual(status(head(["Host : localhost"])), 400)
        XCTAssertEqual(status(head(["Host\t: localhost"])), 400)
        XCTAssertEqual(status(head([": no-name"])), 400)
        XCTAssertEqual(status(head(["NoColon"])), 400)
        XCTAssertEqual(status(head(["Hóst: localhost"])), 400, "Header names are ASCII")
    }

    func testHostCannotBeRepeatedInAnyCase() {
        XCTAssertEqual(status(head(["Host: localhost", "HOST: localhost"])), 400)
    }

    func testOtherRepeatedHeadersKeepTheirFirstValue() throws {
        let request = try XCTUnwrap(try parse(head(["Authorization: Bearer first", "authorization: Bearer second"])).get().first)
        XCTAssertEqual(request.header("Authorization"), "Bearer first")
    }

    func testHeaderNamesAreLowercasedAndValuesTrimmed() throws {
        let request = try XCTUnwrap(try parse(head(["X-Mixed-Case: \t value with  spaces \t"])).get().first)
        XCTAssertEqual(request.headers.keys.sorted(), ["x-mixed-case"])
        XCTAssertEqual(request.header("X-MIXED-CASE"), "value with  spaces")
    }

    func testInvalidUTF8InTheHeadIsMalformed() {
        var bytes = Data("GET /mcp HTTP/1.1\r\nX: ".utf8)
        bytes.append(contentsOf: [0xFF, 0xFE])
        bytes.append(Data("\r\n\r\n".utf8))
        guard case .failure(let error) = parseBytes(bytes) else { return XCTFail("Expected an error") }
        XCTAssertEqual(error, .malformed)
    }

    // MARK: Request line

    func testMalformedRequestLines() {
        for line in [
            "get /mcp HTTP/1.1", "GET  /mcp HTTP/1.1", "GET /mcp  HTTP/1.1", "GET mcp HTTP/1.1", "GET http://localhost/mcp HTTP/1.1", "GET * HTTP/1.1",
            "GET /mcp", "/mcp HTTP/1.1", " GET /mcp HTTP/1.1", "M-SEARCH /mcp HTTP/1.1", "GET /mcp http/1.1", "GET /mcp FTP/1.1"
        ] {
            XCTAssertEqual(status(head([], requestLine: line)), 400, line)
        }
    }

    func testOnlyHTTP10And11AreSupported() {
        for version in ["HTTP/2", "HTTP/0.9", "HTTP/1.2", "HTTP/3.0"] {
            XCTAssertEqual(status(head([], requestLine: "GET /mcp \(version)")), 505, version)
        }
    }

    func testTheQueryIsDroppedFromThePathButNotAFragment() throws {
        XCTAssertEqual(try parse(head([], requestLine: "GET /mcp?token=x&y HTTP/1.1")).get().first?.path, "/mcp")
        XCTAssertEqual(try parse(head([], requestLine: "GET /mcp? HTTP/1.1")).get().first?.path, "/mcp")
        XCTAssertEqual(try parse(head([], requestLine: "GET /mcp#x HTTP/1.1")).get().first?.path, "/mcp#x")
    }

    // MARK: Feeding

    func testFeedingAPipelinedStreamOneByteAtATimeGivesEveryRequestOnce() throws {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let one = head(["Host: localhost", "Content-Length: \(body.utf8.count)"]) + body
        let two = head(["Host: localhost"], requestLine: "DELETE /mcp HTTP/1.0")
        let stream = Data((one + "\r\n" + two + one).utf8)
        var parser = MCPHTTPRequestParser()
        var requests: [MCPHTTPRequest] = []
        for byte in stream { requests += try parser.append(Data([byte])) }
        XCTAssertEqual(requests.map(\.method), ["POST", "DELETE", "POST"])
        XCTAssertEqual(requests.map(\.body.count), [body.utf8.count, 0, body.utf8.count])
        XCTAssertEqual(requests[1].version, "HTTP/1.0")
        XCTAssertFalse(parser.hasPartialRequest)
        // The same stream in one read gives the same requests.
        XCTAssertEqual(try parseBytes(stream).get(), requests)
    }

    func testEveryRandomSplitGivesTheSameRequests() throws {
        let body = String(repeating: "é", count: 40)
        let stream = Data(String(repeating: head(["Host: localhost", "Content-Length: \(body.utf8.count)"]) + body, count: 5).utf8)
        let expected = try parseBytes(stream).get()
        XCTAssertEqual(expected.count, 5)
        var random = SeededGenerator(state: 0x9E37_79B9_7F4A_7C15)
        for _ in 0..<50 {
            var parser = MCPHTTPRequestParser()
            var requests: [MCPHTTPRequest] = []
            var offset = 0
            while offset < stream.count {
                let size = Int.random(in: 1...64, using: &random)
                let end = min(offset + size, stream.count)
                requests += try parser.append(stream.subdata(in: offset..<end))
                offset = end
            }
            XCTAssertEqual(requests, expected)
        }
    }

    func testManyBlankLinesBetweenRequestsAreSkipped() throws {
        let raw = String(repeating: "\r\n", count: 500) + head([], requestLine: "GET /a HTTP/1.1") + String(repeating: "\r\n", count: 500) + head([], requestLine: "GET /b HTTP/1.1")
        XCTAssertEqual(try parse(raw).get().map(\.path), ["/a", "/b"])
    }

    func testAnErrorAfterAGoodRequestStillThrows() {
        // The listener answers the error and closes, so a smuggled second request never runs.
        XCTAssertEqual(status(head([], requestLine: "GET /a HTTP/1.1") + head(["Transfer-Encoding: chunked"])), 411)
    }

    func testRandomBytesNeverCrashTheParser() {
        var random = SeededGenerator(state: 42)
        let alphabet = Array("GET POST /mcp HTTP/1.1\r\n:Content-Length: 12 Host: localhost\r\n\r\n{}\t -+,".utf8)
        for _ in 0..<500 {
            var parser = MCPHTTPRequestParser()
            let length = Int.random(in: 0...400, using: &random)
            let bytes = (0..<length).map { _ in
                Bool.random(using: &random) ? alphabet[Int.random(in: 0..<alphabet.count, using: &random)] : UInt8.random(in: 0...255, using: &random)
            }
            // Fed in random pieces: whatever the outcome, it is a result or a typed error.
            var offset = 0
            while offset < bytes.count {
                let end = min(bytes.count, offset + Int.random(in: 1...50, using: &random))
                do { _ = try parser.append(Data(bytes[offset..<end])) } catch { break }
                offset = end
            }
        }
    }

    // MARK: Requests and responses

    func testKeepAliveFollowsTheVersionAndConnectionHeader() {
        func request(_ version: String, _ connection: String?) -> MCPHTTPRequest {
            MCPHTTPRequest(method: "GET", path: "/", version: version, headers: connection.map { ["Connection": $0] } ?? [:])
        }
        XCTAssertTrue(request("HTTP/1.1", nil).keepAlive)
        XCTAssertFalse(request("HTTP/1.1", "close").keepAlive)
        XCTAssertFalse(request("HTTP/1.1", "Keep-Alive, Close").keepAlive)
        XCTAssertFalse(request("HTTP/1.0", nil).keepAlive)
        XCTAssertTrue(request("HTTP/1.0", "Keep-Alive").keepAlive)
    }

    func testRequestHeadersAreCaseInsensitiveAndKeepTheFirstOfDuplicates() {
        let request = MCPHTTPRequest(method: "GET", path: "/", headers: ["Host": "a", "HOST": "b"])
        XCTAssertEqual(request.headers.count, 1)
        XCTAssertNotNil(request.header("host"))
    }

    func testSerializedResponsesAlwaysCarryLengthNoStoreAndConnection() {
        let body = Data("héllo".utf8)
        let wire = String(decoding: MCPHTTPResponse(status: 200, headers: [("X-A", "1")], body: body).serialized(keepAlive: true), as: UTF8.self)
        XCTAssertTrue(wire.hasPrefix("HTTP/1.1 200 OK\r\nX-A: 1\r\n"))
        XCTAssertTrue(wire.contains("\r\nContent-Length: \(body.count)\r\n"), "Content-Length counts bytes, not characters")
        XCTAssertTrue(wire.contains("\r\nCache-Control: no-store\r\n"))
        XCTAssertTrue(wire.hasSuffix("\r\nConnection: keep-alive\r\n\r\nhéllo"))
        let closing = String(decoding: MCPHTTPResponse.empty(204).serialized(keepAlive: false), as: UTF8.self)
        XCTAssertEqual(closing, "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n")
        XCTAssertFalse(closing.lowercased().contains("access-control"), "No CORS headers")
    }

    func testEveryParseErrorHasAReasonPhrase() {
        for error in [MCPHTTPParseError.malformed, .headersTooLarge, .bodyTooLarge, .lengthRequired, .unsupportedVersion] {
            XCTAssertNotEqual(MCPHTTPResponse.reason(error.status), "Error", "\(error)")
        }
        XCTAssertEqual(MCPHTTPResponse.reason(418), "Error")
    }

    func testResponseHelpersSetContentTypes() {
        XCTAssertEqual(MCPHTTPResponse.json(200, Data("{}".utf8)).header("content-type"), "application/json")
        let plain = MCPHTTPResponse.plain(403, "Forbidden origin.")
        XCTAssertEqual(plain.header("Content-Type"), "text/plain; charset=utf-8")
        XCTAssertEqual(plain.body, Data("Forbidden origin.\n".utf8))
        XCTAssertEqual(MCPHTTPResponse.empty(405, headers: [("Allow", "POST")]).header("allow"), "POST")
    }
}
