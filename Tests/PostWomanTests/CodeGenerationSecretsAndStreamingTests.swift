import Foundation
import XCTest

@testable import PostWoman

private let resolver = VariableResolver(
    defaults: [Variable(key: "host", value: "https://api.example.com"), Variable(key: "user", value: "ada")],
    selected: [Variable(key: "token", value: "tok-SECRET", isSecret: true), Variable(key: "pw", value: "pw-SECRET", isSecret: true)], selectedName: "Prod")

/// Every generator, by name, so each assertion says which one failed.
private let generators: [(String, @Sendable (RequestSnapshot) -> String)] = [
    ("curl", { CURLGenerator().generate(from: $0) }), ("swift", { SwiftGenerator().generate(from: $0) }), ("python", { PythonGenerator().generate(from: $0) })
]

/// A request whose secrets appear in a header, a param, the body and the credentials.
private func secretive(_ auth: AuthenticationType) -> RequestSnapshot {
    let request = APIRequest(name: "s", url: "{{host}}/users/{{user}}", method: .post)
    request.headers = [KeyValuePair(key: "X-Api-Key", value: "{{token}}")]
    request.queryParams = [KeyValuePair(key: "sig", value: "{{pw}}")]
    request.bodyType = .text
    request.bodyContent = "user={{user}}&token={{token}}"
    request.authenticationType = auth
    request.authBearerToken = "{{token}}"
    request.authBasicUsername = "{{user}}"
    request.authBasicPassword = "{{pw}}"
    return RequestSnapshot(request).resolved(with: resolver, redactSecrets: true)
}

private func streaming(headers: [KeyValuePair] = [], body: String? = nil, type: ContentType = .json) -> APIRequest {
    let request = APIRequest(name: "chat", url: "https://llm.test/v1/chat", method: .post)
    request.headers = headers
    if let body {
        request.bodyType = type
        request.bodyContent = body
    }
    return request
}

final class CodeGenerationSecretsTests: XCTestCase {
    func testNoGeneratorEverPrintsASecretValue() {
        for auth in AuthenticationType.allCases {
            for (name, generate) in generators {
                let code = generate(secretive(auth))
                XCTAssertFalse(code.contains("SECRET"), "\(name) / \(auth.rawValue): \(code)")
                XCTAssertTrue(code.contains("https://api.example.com/users/ada"), "\(name) / \(auth.rawValue): plain variables still resolve")
            }
        }
    }

    func testSecretsStayAsVariablesInEachField() {
        let bearer = secretive(.bearer)
        let curl = CURLGenerator().generate(from: bearer)
        XCTAssertTrue(curl.contains("-H 'X-Api-Key: {{token}}'"), curl)
        XCTAssertTrue(curl.contains("-H 'Authorization: Bearer {{token}}'"), curl)
        XCTAssertTrue(curl.contains("-d 'user=ada&token={{token}}'"), curl)
        XCTAssertTrue(curl.contains("sig=%7B%7Bpw%7D%7D"), "A redacted param is percent-encoded like any other value: \(curl)")

        let swift = SwiftGenerator().generate(from: bearer)
        XCTAssertTrue(swift.contains(#"request.setValue("Bearer {{token}}", forHTTPHeaderField: "Authorization")"#), swift)
        XCTAssertTrue(swift.contains(#"URLQueryItem(name: "sig", value: "{{pw}}")"#), swift)

        let python = PythonGenerator().generate(from: bearer)
        XCTAssertTrue(python.contains(#""Authorization": "Bearer {{token}}","#), python)
        XCTAssertTrue(python.contains(#""X-Api-Key": "{{token}}","#), python)
        XCTAssertTrue(python.contains(#"data = """user=ada&token={{token}}""""#), python)
    }

    func testBasicPasswordIsRedactedButTheUsernameResolves() {
        let basic = secretive(.basic)
        XCTAssertTrue(CURLGenerator().generate(from: basic).contains("-u 'ada:{{pw}}'"))
        XCTAssertTrue(SwiftGenerator().generate(from: basic).contains(#"let credentials = "ada:{{pw}}""#))
        XCTAssertTrue(PythonGenerator().generate(from: basic).contains(#"auth = ("ada", "{{pw}}")"#))
    }

    func testWithoutRedactionSecretsAreResolved() {
        let request = APIRequest(name: "s", url: "https://h")
        request.authenticationType = .bearer
        request.authBearerToken = "{{token}}"
        let resolved = RequestSnapshot(request).resolved(with: resolver)
        for (name, generate) in generators {
            XCTAssertTrue(generate(resolved).contains("Bearer tok-SECRET"), name)
        }
    }

    func testUnresolvedTemplatesAreGeneratedAsWritten() {
        let request = APIRequest(name: "s", url: "{{host}}/x")
        request.authenticationType = .bearer
        request.authBearerToken = "{{token}}"
        for (name, generate) in generators {
            let code = generate(RequestSnapshot(request))
            XCTAssertTrue(code.contains("{{host}}/x"), name)
            XCTAssertTrue(code.contains("Bearer {{token}}"), name)
        }
    }
}

final class CodeGenerationStreamingTests: XCTestCase {
    func testStreamFlagComesRightAfterCurlAndBeforeTheMethod() {
        let lines = CURLGenerator().generate(from: streaming(body: #"{"stream":true}"#)).components(separatedBy: " \\\n  ")
        XCTAssertEqual(Array(lines.prefix(4)), ["curl", "-N", "-X POST", "'https://llm.test/v1/chat'"])
        XCTAssertEqual(lines.filter { $0 == "-N" }.count, 1)
    }

    func testAcceptEventStreamAmongOtherTypesAsksForAStream() {
        for value in ["text/event-stream", "TEXT/EVENT-STREAM", "application/json, text/event-stream;q=0.9"] {
            let request = streaming(headers: [KeyValuePair(key: "ACCEPT", value: value)])
            XCTAssertTrue(request.expectsStream, value)
            XCTAssertTrue(CURLGenerator().generate(from: request).hasPrefix("curl \\\n  -N"), value)
        }
    }

    func testOnlyATopLevelBooleanStreamTrueCounts() {
        let cases: [(String, ContentType, Bool)] = [
            (#"{"stream":true,"model":"m"}"#, .json, true), (#"{"stream":"true"}"#, .json, false), (#"{"stream":null}"#, .json, false),
            (#"{"options":{"stream":true}}"#, .json, false), (#"[{"stream":true}]"#, .json, false), (#"{"stream":true"#, .json, false),
            (#"{"stream":true}"#, .text, true), (#"{"stream":true}"#, .none, false), ("", .json, false)
        ]
        for (body, type, expected) in cases {
            let request = streaming(body: body, type: type)
            XCTAssertEqual(request.expectsStream, expected, "\(type.rawValue): \(body)")
            XCTAssertEqual(CURLGenerator().generate(from: request).contains("-N"), expected, "\(type.rawValue): \(body)")
        }
    }

    func testOtherAcceptHeadersDoNotAskForAStream() {
        for header in [KeyValuePair(key: "Accept", value: "application/json"), KeyValuePair(key: "Content-Type", value: "text/event-stream")] {
            XCTAssertFalse(streaming(headers: [header]).expectsStream, header.key)
        }
    }

    func testAResolvedSnapshotStillAsksForAStream() {
        let request = streaming(headers: [KeyValuePair(key: "Accept", value: "{{accept}}")])
        let resolver = VariableResolver(defaults: [Variable(key: "accept", value: "text/event-stream")], selected: nil)
        XCTAssertFalse(RequestSnapshot(request).expectsStream, "Before resolving, the header is just a variable")
        XCTAssertTrue(RequestSnapshot(request).resolved(with: resolver).expectsStream)
    }

    func testSwiftAndPythonAreTheSameForAStreamedRequest() {
        let streamed = streaming(body: #"{"stream":true}"#)
        let plain = streaming(body: #"{"stream":false}"#)
        XCTAssertEqual(
            SwiftGenerator().generate(from: streamed).replacingOccurrences(of: "true", with: "false"), SwiftGenerator().generate(from: plain),
            "Only the body differs")
        XCTAssertFalse(PythonGenerator().generate(from: streamed).contains("stream=True"), "requests still reads the whole body; not added yet")
    }
}
