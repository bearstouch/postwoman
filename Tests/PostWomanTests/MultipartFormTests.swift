import XCTest

@testable import PostWoman

final class MultipartFormTests: XCTestCase {
    private func request(_ body: String, type: ContentType = .formData, headers: [KeyValuePair] = []) -> APIRequest {
        let request = APIRequest(name: "f", url: "https://h", method: .post)
        request.bodyType = type
        request.bodyContent = body
        request.headers = headers
        return request
    }

    func testFieldsComeFromTheFormBodyDecoded() {
        let fields = MultipartForm.fields(of: request("name=Ana%20Lu&age=3&empty"))
        XCTAssertEqual(fields?.map(\.key), ["name", "age", "empty"])
        XCTAssertEqual(fields?.map(\.value), ["Ana Lu", "3", ""])
    }

    func testOnlyFormDataWithoutItsOwnContentTypeIsEncoded() {
        XCTAssertNil(MultipartForm.fields(of: request("a=1", type: .urlEncoded)))
        XCTAssertNil(MultipartForm.fields(of: request("a=1", type: .json)))
        XCTAssertNil(
            MultipartForm.fields(of: request("--x\r\n…", headers: [KeyValuePair(key: "content-type", value: "multipart/form-data; boundary=x")])),
            "A request that names its Content-Type wrote its body by hand")
        XCTAssertNotNil(MultipartForm.fields(of: request("a=1", headers: [KeyValuePair(key: "Content-Type", value: "x", isEnabled: false)])))
    }

    func testEachFieldIsAPartAndTheBodyEndsWithTheClosingBoundary() {
        let body = MultipartForm.body([KeyValuePair(key: "name", value: "Ana Lu"), KeyValuePair(key: "note", value: "é\nline")], boundary: "B")
        XCTAssertEqual(
            String(decoding: body, as: UTF8.self),
            "--B\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\nAna Lu\r\n--B\r\nContent-Disposition: form-data; name=\"note\"\r\n\r\né\nline\r\n--B--\r\n")
        XCTAssertEqual(String(decoding: MultipartForm.body([], boundary: "B"), as: UTF8.self), "--B--\r\n")
        XCTAssertEqual(MultipartForm.contentType(boundary: "B"), "multipart/form-data; boundary=B")
    }

    func testAFieldNameCannotBreakOutOfItsHeader() {
        XCTAssertEqual(MultipartForm.escapedName("a\"b\r\nX-Injected: 1"), "a%22b%0D%0AX-Injected: 1")
        let body = String(decoding: MultipartForm.body([KeyValuePair(key: "a\"\r\nEvil: 1", value: "v")], boundary: "B"), as: UTF8.self)
        XCTAssertFalse(body.contains("\r\nEvil: 1"))
    }

    func testBoundariesDiffer() {
        XCTAssertNotEqual(MultipartForm.makeBoundary(), MultipartForm.makeBoundary())
    }
}
