import XCTest

@testable import Reqs

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

    func testAVariablesValueStaysInsideItsFieldWhateverItContains() {
        // Resolved as text, `a&b=c+d%41` would add a field `b` and turn `+` and `%41` into a space and an A.
        let resolver = VariableResolver(defaults: [Variable(key: "pw", value: "a&b=c+d%41"), Variable(key: "field", value: "us er")], selected: nil)
        let sent = RequestSnapshot(request("password={{pw}}&{{field}}=ana&plain=x%20y")).resolved(with: resolver)
        let fields = MultipartForm.fields(of: sent)
        XCTAssertEqual(fields?.map(\.key), ["password", "us er", "plain"])
        XCTAssertEqual(fields?.map(\.value), ["a&b=c+d%41", "ana", "x y"])
    }

    func testAVariableTypedInAFormFieldIsStillAVariable() {
        // The editor used to store the braces percent-encoded, where the resolver never saw them.
        let typed = FormBody.body(from: [KeyValuePair(key: "token", value: "{{token}}")])
        XCTAssertEqual(typed, "token={{token}}")
        let resolver = VariableResolver(defaults: [Variable(key: "token", value: "abc")], selected: nil)
        for type in [ContentType.formData, .urlEncoded] {
            let template = RequestSnapshot(request(typed, type: type))
            XCTAssertEqual(template.missingVariables(with: .empty), ["token"], type.rawValue)
            XCTAssertEqual(template.resolved(with: resolver).bodyContent, "token=abc", type.rawValue)
        }
        let stored = RequestSnapshot(request("token=%7B%7Btoken%7D%7D")).resolved(with: resolver)
        XCTAssertEqual(MultipartForm.fields(of: stored)?.first?.value, "abc", "A Form Data body saved before still resolves")
    }

    func testASecretInAFormFieldStaysANameWhenRedacted() {
        let resolver = VariableResolver(defaults: [Variable(key: "pw", value: "s3cret&x=1", isSecret: true)], selected: nil)
        let recorded = RequestSnapshot(request("password={{pw}}")).resolved(with: resolver, redactSecrets: true)
        XCTAssertEqual(recorded.bodyContent, "password={{pw}}")
    }

    func testAFormWithNoNamedFieldSendsNoBodyAnywhere() throws {
        let empty = request("&")
        XCTAssertEqual(MultipartForm.fields(of: empty), [])
        XCTAssertFalse(CURLGenerator().generate(from: empty).contains("form"))
        XCTAssertFalse(SwiftGenerator().generate(from: empty).contains("httpBody"))
        XCTAssertFalse(SwiftGenerator().generate(from: empty).contains("Content-Type"))
    }

    func testBoundariesDiffer() {
        XCTAssertNotEqual(MultipartForm.makeBoundary(), MultipartForm.makeBoundary())
    }
}
