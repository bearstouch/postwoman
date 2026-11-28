import AppKit
import XCTest

@testable import Reqs

@MainActor
final class RequestPreviewTests: XCTestCase {
    private func preview(_ request: APIRequest, resolver: VariableResolver = .empty) throws -> String {
        guard case .request(let text) = RequestPreview.make(RequestSnapshot(request).resolved(with: resolver, redactSecrets: true)) else {
            throw XCTSkip("no preview")
        }
        return text
    }

    private func lines(_ request: APIRequest, resolver: VariableResolver = .empty) throws -> [String] {
        try preview(request, resolver: resolver).components(separatedBy: "\n")
    }

    func testTheRequestLineHostAndQueryAreAsSent() throws {
        let request = APIRequest(name: "r", url: "https://api.example.com:8443/users/a b?sort=name", method: .get)
        request.queryParams = [KeyValuePair(key: "q", value: "a&b"), KeyValuePair(key: "off", value: "x", isEnabled: false)]
        let lines = try lines(request)
        XCTAssertEqual(lines[0], "GET /users/a%20b?sort=name&q=a%26b HTTP/1.1")
        XCTAssertEqual(lines[1], "Host: api.example.com:8443")
        XCTAssertEqual(try self.lines(APIRequest(name: "r", url: "https://example.com"))[0], "GET / HTTP/1.1", "An empty path is /")
        XCTAssertEqual(try self.lines(APIRequest(name: "r", url: "https://example.com"))[1], "Host: example.com", "No port when the URL names none")
    }

    func testHeadersKeepTheirOrderWithEachNameOnceThenWhatReqsAdds() throws {
        let request = APIRequest(name: "r", url: "https://h/items", method: .post)
        request.headers = [
            KeyValuePair(key: "X-Trace", value: "1"), KeyValuePair(key: "Accept", value: "text/plain"), KeyValuePair(key: "x-trace", value: "2"),
            KeyValuePair(key: "X-Off", value: "no", isEnabled: false)
        ]
        request.bodyType = .json
        request.bodyContent = #"{"name":"Ada"}"#
        XCTAssertEqual(
            try lines(request),
            ["POST /items HTTP/1.1", "Host: h", "X-Trace: 2", "Accept: text/plain", "Content-Type: application/json", "Content-Length: 14", "", #"{"name":"Ada"}"#])
    }

    func testThePreviewSaysWhatTheClientSends() throws {
        let request = APIRequest(name: "r", url: "https://h/u?a=1", method: .put)
        request.headers = [KeyValuePair(key: "Content-Type", value: "application/vnd.custom"), KeyValuePair(key: "X-A", value: "b")]
        request.bodyType = .xml
        request.bodyContent = "<a/>"
        let sent = try HTTPClient.urlRequest(for: request, timeout: 30, boundary: RequestPreview.boundary)
        let shown = try lines(request)
        for (name, value) in sent.allHTTPHeaderFields ?? [:] { XCTAssertTrue(shown.contains("\(name): \(value)"), "\(name): \(shown)") }
        XCTAssertEqual(shown.last, "<a/>")
    }

    func testAGetSendsNoBodySoThePreviewShowsNone() throws {
        let request = APIRequest(name: "r", url: "https://h/u", method: .get)
        request.bodyType = .json
        request.bodyContent = "{}"
        XCTAssertEqual(try lines(request), ["GET /u HTTP/1.1", "Host: h", ""])
    }

    func testCredentialsAreMaskedAndSecretsStayNames() throws {
        let resolver = VariableResolver(
            defaults: [Variable(key: "host", value: "api.example.com"), Variable(key: "key", value: "s3cret", isSecret: true)], selected: nil)
        let request = APIRequest(name: "r", url: "https://{{host}}/u?key={{key}}", method: .get)
        request.authenticationType = .bearer
        request.authBearerToken = "literal-token"
        let text = try preview(request, resolver: resolver)
        XCTAssertTrue(text.hasPrefix("GET /u?key=%7B%7Bkey%7D%7D HTTP/1.1\nHost: api.example.com"), text)
        XCTAssertTrue(text.contains("Authorization: Bearer •••••••••••••"), text)
        XCTAssertFalse(text.contains("literal-token") || text.contains("s3cret"), text)

        request.authBearerToken = "{{key}}"
        XCTAssertTrue(try preview(request, resolver: resolver).contains("Authorization: Bearer {{key}}"), "A secret variable shows as its name")

        request.authenticationType = .basic
        request.authBasicUsername = "ada"
        request.authBasicPassword = "pw"
        let basic = try preview(request, resolver: resolver)
        XCTAssertTrue(basic.contains("Authorization: Basic ••••••••"), basic)
        XCTAssertFalse(basic.contains(Data("ada:pw".utf8).base64EncodedString()), basic)
    }

    func testTheRequestsOwnAuthorizationHeaderIsShownAsWritten() throws {
        let request = APIRequest(name: "r", url: "https://h/u")
        request.headers = [KeyValuePair(key: "Authorization", value: "Token abc")]
        XCTAssertTrue(try lines(request).contains("Authorization: Token abc"), "Headers tab values are shown there too, so they aren't masked")
    }

    func testFormDataShowsItsPartsWithAFixedBoundary() throws {
        let request = APIRequest(name: "r", url: "https://h/u", method: .post)
        request.bodyType = .formData
        request.bodyContent = "a=1&b=two"
        let text = try preview(request)
        XCTAssertTrue(text.contains("Content-Type: multipart/form-data; boundary=\(RequestPreview.boundary)"), text)
        XCTAssertTrue(text.contains("--\(RequestPreview.boundary)\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n"), text)
        XCTAssertEqual(try preview(request), text, "The same request previews the same way every time")
    }

    func testAFileIsDescribedNotPrinted() throws {
        let request = APIRequest(name: "r", url: "https://h/u", method: .post)
        request.bodyType = .file
        request.attachFile(Data([0x00, 0xFF, 0x41]), name: "photo.png")
        let lines = try lines(request)
        XCTAssertTrue(lines.contains("Content-Type: image/png"), "\(lines)")
        XCTAssertTrue(lines.contains("Content-Length: 3"), "\(lines)")
        XCTAssertEqual(lines.last, "[File: photo.png · \(FileBody.formattedSize(3))]")

        request.bodyFile = nil
        request.bodyFileSize = nil
        let missing = try self.lines(request)
        XCTAssertEqual(missing.last, "[No file attached. \(FileBody.missingFileMessage(fileName: "photo.png"))]")
        XCTAssertFalse(missing.contains { $0.hasPrefix("Content-Length") }, "Nothing would be sent: \(missing)")
    }

    func testLongAndBinaryBodiesAreShortened() {
        let request = APIRequest(name: "r", url: "https://h", method: .post)
        request.bodyType = .text
        let long = Data(String(repeating: "é", count: RequestPreview.maximumBodyBytes).utf8)  // 2 bytes each
        let text = RequestPreview.bodyText(long, request: request)
        XCTAssertTrue(text.hasPrefix("éé"))
        XCTAssertTrue(text.hasSuffix("more"), String(text.suffix(30)))
        XCTAssertLessThanOrEqual(text.utf8.count, RequestPreview.maximumBodyBytes + 40)
        XCTAssertEqual(RequestPreview.bodyText(Data([0xFF, 0xFE, 0x00]), request: request), "[\(FileBody.formattedSize(3)) of binary data]")
        XCTAssertEqual(RequestPreview.bodyText(Data("short".utf8), request: request), "short")
    }

    func testALongTextBodyCutInsideAThreeByteCharacterIsStillText() {
        let request = APIRequest(name: "r", url: "https://h", method: .post)
        request.bodyType = .text
        let body = Data(String(repeating: "漢", count: RequestPreview.maximumBodyBytes).utf8)  // 3 bytes each: 100,000 cuts after 1 of 3
        let text = RequestPreview.bodyText(body, request: request)
        XCTAssertTrue(text.hasPrefix("漢漢"), String(text.prefix(20)))
        XCTAssertTrue(text.hasSuffix("more"))
        let fourBytes = Data(String(repeating: "💅", count: RequestPreview.maximumBodyBytes).utf8)
        XCTAssertTrue(RequestPreview.bodyText(fourBytes, request: request).hasPrefix("💅"))
    }

    func testTheHostIsWhatGoesOnTheWire() throws {
        XCTAssertEqual(try lines(APIRequest(name: "r", url: "https://bücher.de/a"))[1], "Host: xn--bcher-kva.de")
        XCTAssertEqual(try lines(APIRequest(name: "r", url: "http://[fe80::1%25en0]:8080/"))[1], "Host: [fe80::1]:8080", "No IPv6 zone")
        XCTAssertEqual(try lines(APIRequest(name: "r", url: "http://[::1]/"))[1], "Host: [::1]")
    }

    func testTheRequestsOwnHostAndContentLengthAreReplacedNotRepeated() throws {
        let request = APIRequest(name: "r", url: "https://h/u", method: .post)
        request.headers = [KeyValuePair(key: "Content-Length", value: "999"), KeyValuePair(key: "Host", value: "other")]
        request.bodyType = .text
        request.bodyContent = "abc"
        let lines = try lines(request)
        XCTAssertEqual(lines.filter { $0.lowercased().hasPrefix("content-length") }, ["Content-Length: 3"])
        XCTAssertEqual(lines.filter { $0.lowercased().hasPrefix("host") }, ["Host: h"])
    }

    func testAFormBodysLengthIsTheLengthSent() throws {
        let request = APIRequest(name: "r", url: "https://h/u", method: .post)
        request.bodyType = .formData
        request.bodyContent = "a=1&b=2&c=3"
        let sent = try XCTUnwrap(try HTTPClient.urlRequest(for: request, timeout: 30).httpBody)  // a random boundary, as a send has
        XCTAssertTrue(try lines(request).contains("Content-Length: \(sent.count)"))
        XCTAssertEqual(RequestPreview.boundary.count, MultipartForm.makeBoundary().count)
    }

    func testSecretsInBodiesAndBasicAuthStayHidden() throws {
        let resolver = VariableResolver(defaults: [Variable(key: "pw", value: "hunter2", isSecret: true)], selected: nil)
        let request = APIRequest(name: "r", url: "https://h/u", method: .post)
        request.bodyType = .formData
        request.bodyContent = "password={{pw}}"
        request.authenticationType = .basic
        request.authBasicUsername = "ada"
        request.authBasicPassword = "{{pw}}"
        let text = try preview(request, resolver: resolver)
        XCTAssertTrue(text.contains("{{pw}}"), text)
        XCTAssertFalse(text.contains("hunter2"), text)
        XCTAssertFalse(text.contains(Data("ada:hunter2".utf8).base64EncodedString()), text)
        XCTAssertFalse(text.contains(Data("ada:{{pw}}".utf8).base64EncodedString()), "Basic is masked whole")
    }

    func testASavedFileIsPreviewedFromItsSizeWithoutItsBytes() throws {
        let request = APIRequest(name: "r", url: "https://h/u", method: .post)
        request.bodyType = .file
        request.attachFile(Data(count: 2048), name: "photo.png")
        XCTAssertNil(RequestSnapshot(request, includingFile: false).bodyFile, "The preview's snapshot doesn't read the bytes")
        guard case .request(let text) = RequestPreview.make(request, resolver: .empty) else { return XCTFail("no preview") }
        let lines = text.components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("Content-Length: 2048"), "\(lines)")
        XCTAssertTrue(lines.contains("Content-Type: image/png"), "\(lines)")
        XCTAssertEqual(lines.last, "[File: photo.png · \(FileBody.formattedSize(2048))]")
        request.attachFile(nil, name: nil)
        request.bodyFileName = "photo.png"
        guard case .request(let missing) = RequestPreview.make(request, resolver: .empty) else { return XCTFail("no preview") }
        XCTAssertTrue(missing.hasSuffix("[No file attached. \(FileBody.missingFileMessage(fileName: "photo.png"))]"), missing)
    }

    func testAnURLThatCantBeSentHasNoPreview() {
        for url in ["", "   ", "not a url", "/relative/path", "https://"] {
            XCTAssertEqual(RequestPreview.make(RequestSnapshot(APIRequest(name: "r", url: url))), .invalidURL, url)
        }
    }

    func testThePreviewTabIsLastAndOnlyForSavedRequests() {
        XCTAssertEqual(RequestTab.allCases, [.params, .headers, .body, .auth, .preview])
        XCTAssertEqual(RequestTab.historyTabs, [.params, .headers, .body, .auth])
        XCTAssertNil(RequestTab.preview.badge(for: APIRequest(name: "r", url: "https://h")))
    }

    // MARK: Colors

    private func color(_ text: NSAttributedString, at substring: String) -> NSColor? {
        let range = (text.string as NSString).range(of: substring)
        return text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }

    func testTheHeadIsColoredAndTheBodyOnlyAsJSON() {
        let message = "POST /naïve/{{id}} HTTP/1.1\nHost: h\nX-Café: {{token}}\n\n{\"key\": 1}"
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let styled = ResponseTextView.attributedText(message, highlightsJSON: true, highlightsHTTP: true, font: font)
        XCTAssertEqual(styled.string, message)
        XCTAssertEqual(color(styled, at: "POST"), CodePalette.literal)
        XCTAssertEqual(color(styled, at: "HTTP/1.1"), CodePalette.punctuation)
        XCTAssertEqual(color(styled, at: "X-Café"), CodePalette.key)
        XCTAssertEqual(color(styled, at: "Host"), CodePalette.key)
        XCTAssertEqual(color(styled, at: "{{token}}"), CodePalette.variable, "After a non-ASCII character too")
        XCTAssertEqual(color(styled, at: "{{id}}"), CodePalette.variable)
        XCTAssertNotEqual(color(styled, at: "\"key\""), CodePalette.text, "The JSON body is colored")

        let plain = ResponseTextView.attributedText("POST / HTTP/1.1\nHost: h\n\n{\"key\": 1}", highlightsJSON: false, highlightsHTTP: true, font: font)
        XCTAssertEqual(color(plain, at: "\"key\""), CodePalette.text, "A body that isn't JSON stays plain")
        XCTAssertEqual(ResponseTextView.attributedText("", highlightsJSON: true, highlightsHTTP: true, font: font).string, "")
    }
}
