import Foundation
import XCTest

@testable import PostWoman

/// The command's arguments, one per continuation line.
private func parts(_ request: APIRequest) -> [String] {
    CURLGenerator().generate(from: request).components(separatedBy: " \\\n  ")
}

private func post(_ body: String, type: ContentType = .json) -> APIRequest {
    let request = APIRequest(name: "p", url: "https://api.example.com/items", method: .post)
    request.bodyType = type
    request.bodyContent = body
    return request
}

/// Runs the generated command through `/bin/sh` with `curl` swapped for `printf`, returning the words the shell passed.
private func shellWords(_ command: String) throws -> [String] {
    let script = "printf '%s\\0'" + command.dropFirst("curl".count)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    process.environment = ["HOME": "/should-not-expand", "PATH": "/usr/bin:/bin"]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, script)
    return String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
}

final class CURLGeneratorEdgeCaseTests: XCTestCase {
    func testEmptyRequestIsCurlAndAnEmptyQuotedURL() {
        XCTAssertEqual(CURLGenerator().generate(from: APIRequest(name: "empty")), "curl \\\n  ''")
    }

    func testGetOmitsTheMethodAndEveryOtherMethodIsSpelledOut() {
        for method in HTTPMethod.allCases {
            let lines = parts(APIRequest(name: "m", url: "https://api.example.com", method: method))
            if method == .get {
                XCTAssertEqual(lines, ["curl", "'https://api.example.com'"], method.rawValue)
            } else if method == .head {
                XCTAssertEqual(lines, ["curl", "-I", "'https://api.example.com'"], "HEAD is -I, since curl -X HEAD waits for a body")
            } else {
                XCTAssertEqual(lines, ["curl", "-X \(method.rawValue)", "'https://api.example.com'"], method.rawValue)
            }
        }
    }

    func testFormDataFieldsAreSentAsLiteralMultipartFields() throws {
        let request = post("name=Ana%20Lu&file=@/etc/hosts&q=%3Cx&it's=1", type: .formData)
        XCTAssertEqual(
            parts(request),
            [
                "curl", "-X POST", "'https://api.example.com/items'", "--form-string 'name=Ana Lu'", "--form-string 'file=@/etc/hosts'", "--form-string 'q=<x'",
                "--form-string 'it'\\''s=1'"
            ], "No -d and no Content-Type: curl writes the multipart header with its boundary, and never reads a file for a value")
        XCTAssertEqual(
            try shellWords(CURLGenerator().generate(from: request)),
            ["-X", "POST", "https://api.example.com/items", "--form-string", "name=Ana Lu", "--form-string", "file=@/etc/hosts", "--form-string", "q=<x", "--form-string", "it's=1"])
    }

    func testGetWithABodySpellsOutTheMethodSoCurlDoesNotSendAPost() throws {
        let request = APIRequest(name: "g", url: "https://h", method: .get)
        request.bodyType = .text
        request.bodyContent = "x"
        // The app can't send a GET with a body, so the command leaves it out too: nothing turns the GET into a POST.
        XCTAssertEqual(parts(request), ["curl", "'https://h'"])
        XCTAssertEqual(try shellWords(CURLGenerator().generate(from: request)), ["https://h"])
    }

    func testGetWithoutAnEmittedBodyStillOmitsTheMethod() {
        for (type, content) in [(ContentType.none, "ignored"), (.json, "")] {
            let request = APIRequest(name: "g", url: "https://h")
            request.bodyType = type
            request.bodyContent = content
            XCTAssertEqual(parts(request), ["curl", "'https://h'"], type.rawValue)
        }
    }

    func testHeadIsDashIAndLeavesTheBodyAndItsContentTypeOut() throws {
        let request = post(#"{"a":1}"#)
        request.method = .head
        request.headers = [KeyValuePair(key: "Accept", value: "*/*")]
        XCTAssertEqual(parts(request), ["curl", "-I", "'https://api.example.com/items'", "-H 'Accept: */*'"])
        XCTAssertEqual(try shellWords(CURLGenerator().generate(from: request)), ["-I", "https://api.example.com/items", "-H", "Accept: */*"])
    }

    func testPatchAndOptionsSpellOutTheMethodAndSendTheBody() throws {
        for method in [HTTPMethod.patch, .options] {
            let request = post(#"{"a":1}"#)
            request.method = method
            XCTAssertEqual(
                try shellWords(CURLGenerator().generate(from: request)),
                ["-X", method.rawValue, "https://api.example.com/items", "-d", #"{"a":1}"#, "-H", "Content-Type: application/json"], method.rawValue)
        }
    }

    func testArgumentsComeInMethodURLHeadersAuthBodyContentTypeOrder() {
        let request = post(#"{"a":1}"#)
        request.headers = [KeyValuePair(key: "Accept", value: "*/*"), KeyValuePair(key: "X-Trace", value: "1")]
        request.queryParams = [KeyValuePair(key: "v", value: "2")]
        request.authenticationType = .bearer
        request.authBearerToken = "t"
        XCTAssertEqual(
            parts(request),
            [
                "curl", "-X POST", "'https://api.example.com/items?v=2'", "-H 'Accept: */*'", "-H 'X-Trace: 1'", "-H 'Authorization: Bearer t'", #"-d '{"a":1}'"#,
                "-H 'Content-Type: application/json'"
            ])
    }

    func testDisabledAndKeylessHeadersAreLeftOut() {
        let request = APIRequest(name: "h", url: "https://api.example.com")
        request.headers = [KeyValuePair(key: "Off", value: "1", isEnabled: false), KeyValuePair(key: "", value: "keyless"), KeyValuePair(key: "On", value: "")]
        XCTAssertEqual(parts(request), ["curl", "'https://api.example.com'", "-H 'On: '"], "An enabled header with an empty value is still sent")
    }

    func testDisabledAndKeylessParamsLeaveTheURLWithoutAQuestionMark() {
        let request = APIRequest(name: "q", url: "https://api.example.com/items")
        request.queryParams = [KeyValuePair(key: "off", value: "1", isEnabled: false), KeyValuePair(key: "", value: "keyless")]
        XCTAssertEqual(parts(request), ["curl", "'https://api.example.com/items'"])
    }

    func testParamsAppendWithAmpersandWhenTheURLAlreadyHasAQuery() {
        let request = APIRequest(name: "q", url: "https://api.example.com/items?fixed=1")
        request.queryParams = [KeyValuePair(key: "a", value: "1"), KeyValuePair(key: "b", value: "2")]
        XCTAssertEqual(parts(request)[1], "'https://api.example.com/items?fixed=1&a=1&b=2'")
    }

    func testParamKeysAndValuesArePercentEncoded() {
        let cases: [(KeyValuePair, String)] = [
            (KeyValuePair(key: "q", value: "hello world"), "q=hello%20world"),
            (KeyValuePair(key: "city", value: "São Paulo"), "city=S%C3%A3o%20Paulo"),
            (KeyValuePair(key: "tag", value: "#swift"), "tag=%23swift"),
            (KeyValuePair(key: "emoji", value: "💅"), "emoji=%F0%9F%92%85"),
            (KeyValuePair(key: "my key", value: "v"), "my%20key=v"),
            (KeyValuePair(key: "empty", value: ""), "empty="),
            (KeyValuePair(key: "path", value: "a/b?c"), "path=a/b?c")
        ]
        for (param, expected) in cases {
            let request = APIRequest(name: "q", url: "https://h")
            request.queryParams = [param]
            XCTAssertEqual(parts(request)[1], "'https://h?\(expected)'", param.key)
        }
    }

    func testQuerySeparatorsInParamNamesAndValuesAreEncodedSoEachParamStaysOne() {
        let cases: [(KeyValuePair, String)] = [
            (KeyValuePair(key: "q", value: "a&b=c"), "q=a%26b%3Dc"),
            (KeyValuePair(key: "sum", value: "a+b"), "sum=a%2Bb"),
            (KeyValuePair(key: "a=b&c", value: "1"), "a%3Db%26c=1"),
            (KeyValuePair(key: "k+#", value: "#x"), "k%2B%23=%23x")
        ]
        for (param, expected) in cases {
            let request = APIRequest(name: "q", url: "https://h")
            request.queryParams = [param]
            XCTAssertEqual(parts(request)[1], "'https://h?\(expected)'", param.key)
            let query = URLComponents(string: "https://h?\(expected)")?.queryItems
            XCTAssertEqual(query, [URLQueryItem(name: param.key, value: param.value)], "A server reads back exactly one param: \(param.key)")
        }
    }

    func testParamsGoBeforeTheURLsFragmentAndTheExistingQueryIsKeptAsWritten() {
        let cases = [
            ("https://h/p#top", "https://h/p?a=1#top"),
            ("https://h/p?x=a+b&y#top", "https://h/p?x=a+b&y&a=1#top"),
            ("https://h/p#frag?not=query", "https://h/p?a=1#frag?not=query"),
            ("https://h/p?x=%20", "https://h/p?x=%20&a=1")
        ]
        for (url, expected) in cases {
            let request = APIRequest(name: "q", url: url)
            request.queryParams = [KeyValuePair(key: "a", value: "1")]
            XCTAssertEqual(parts(request)[1], "'\(expected)'", url)
        }
    }

    func testBodyIsLeftOutForTheNoneTypeOrEmptyContent() {
        XCTAssertEqual(parts(post("ignored", type: .none)), ["curl", "-X POST", "'https://api.example.com/items'"])
        XCTAssertEqual(parts(post("", type: .json)), ["curl", "-X POST", "'https://api.example.com/items'"], "No -d and no Content-Type for an empty body")
    }

    func testEachBodyTypeAddsItsContentType() {
        // Form Data goes as --form-string fields (testFormDataFieldsAreSentAsLiteralMultipartFields).
        for type in ContentType.allCases where type != .none && type != .formData {
            let lines = parts(post("x", type: type))
            XCTAssertEqual(lines.suffix(2), ["-d 'x'", "-H 'Content-Type: \(type.mimeType!)'"], type.rawValue)
        }
    }

    func testAnEnabledContentTypeHeaderInAnyCaseIsNotDuplicated() {
        for key in ["Content-Type", "content-type", "CONTENT-TYPE"] {
            let request = post("a,b", type: .text)
            request.headers = [KeyValuePair(key: key, value: "text/csv")]
            let lines = parts(request)
            XCTAssertEqual(lines.filter { $0.lowercased().hasPrefix("-h 'content-type") }, ["-H '\(key): text/csv'"], key)
        }
    }

    func testADisabledContentTypeHeaderStillGetsTheBodyDefault() {
        let request = post("<a/>", type: .xml)
        request.headers = [KeyValuePair(key: "Content-Type", value: "text/csv", isEnabled: false)]
        XCTAssertEqual(parts(request).last, "-H 'Content-Type: application/xml'")
    }

    func testBodyQuotesAreClosedEscapedAndReopened() {
        let cases = [("it's", #"-d 'it'\''s'"#), ("''", #"-d ''\'''\'''"#), ("'start", #"-d ''\''start'"#), ("end'", #"-d 'end'\'''"#)]
        for (body, expected) in cases {
            XCTAssertEqual(parts(post(body, type: .text))[3], expected, body)
        }
    }

    func testBodiesRoundTripThroughAShellUnchanged() throws {
        let bodies = [
            #"{"name":"it's"}"#, "$HOME and `whoami` and $(id)", #"back\slash \n not a newline"#, "two\nlines\ttab", "naïve café 💅", "'", "!event", "*.swift ~"
        ]
        for body in bodies {
            let words = try shellWords(CURLGenerator().generate(from: post(body, type: .text)))
            XCTAssertEqual(words, ["-X", "POST", "https://api.example.com/items", "-d", body, "-H", "Content-Type: text/plain"], body)
        }
    }

    func testHeaderValuesWithShellCharactersStayLiteral() throws {
        let request = APIRequest(name: "h", url: "https://api.example.com")
        request.headers = [KeyValuePair(key: "X-Cmd", value: "$HOME `id` \\ \"q\"")]
        XCTAssertEqual(try shellWords(CURLGenerator().generate(from: request)), ["https://api.example.com", "-H", "X-Cmd: $HOME `id` \\ \"q\""])
    }

    func testSingleQuotesInEveryArgumentRoundTripThroughAShell() throws {
        let request = APIRequest(name: "q", url: "https://api.example.com/it's")
        request.headers = [KeyValuePair(key: "X-'A'", value: "it's")]
        request.authenticationType = .bearer
        request.authBearerToken = "to'ken"
        XCTAssertEqual(
            try shellWords(CURLGenerator().generate(from: request)),
            ["https://api.example.com/it's", "-H", "X-'A': it's", "-H", "Authorization: Bearer to'ken"])
        XCTAssertEqual(parts(request)[2], #"-H 'X-'\''A'\'': it'\''s'"#)
    }

    func testBasicCredentialsWithSingleQuotesRoundTripThroughAShell() throws {
        let request = APIRequest(name: "a", url: "https://h")
        request.authenticationType = .basic
        request.authBasicUsername = "o'neil"
        request.authBasicPassword = "p'a$s `id`"
        XCTAssertEqual(try shellWords(CURLGenerator().generate(from: request)), ["https://h", "-u", "o'neil:p'a$s `id`"])
    }

    func testBearerNeedsANonEmptyToken() {
        for token in [nil, ""] as [String?] {
            let request = APIRequest(name: "a", url: "https://h")
            request.authenticationType = .bearer
            request.authBearerToken = token
            XCTAssertEqual(parts(request), ["curl", "'https://h'"], String(describing: token))
        }
    }

    func testBasicAuthUsesDashUAndNeedsBothFields() {
        let cases: [(String?, String?, String?)] = [("user", "pass", "-u 'user:pass'"), ("user", "", "-u 'user:'"), ("", "", "-u ':'"), ("user", nil, nil), (nil, "pass", nil)]
        for (username, password, expected) in cases {
            let request = APIRequest(name: "a", url: "https://h")
            request.authenticationType = .basic
            request.authBasicUsername = username
            request.authBasicPassword = password
            XCTAssertEqual(parts(request).dropFirst(2).first, expected, "\(String(describing: username)):\(String(describing: password))")
        }
    }

    func testOnlyTheSelectedAuthTypesCredentialsAreUsed() {
        let request = APIRequest(name: "a", url: "https://h")
        request.authBearerToken = "token"
        request.authBasicUsername = "user"
        request.authBasicPassword = "pass"
        let expected: [AuthenticationType: [String]] = [
            .none: [], .oauth2: [], .bearer: ["-H 'Authorization: Bearer token'"], .basic: ["-u 'user:pass'"]
        ]
        for type in AuthenticationType.allCases {
            request.authenticationType = type
            XCTAssertEqual(Array(parts(request).dropFirst(2)), expected[type], type.rawValue)
        }
    }

    func testUnicodeInURLHeadersAndBodyPassesThrough() {
        let request = post("{\"name\":\"Zoë 💅\"}")
        request.url = "https://例え.jp/パス"
        request.headers = [KeyValuePair(key: "X-Name", value: "Zoë")]
        let lines = parts(request)
        XCTAssertEqual(lines[2], "'https://例え.jp/%E3%83%91%E3%82%B9'", "The path as the app sends it; the host is left for curl to convert")
        XCTAssertEqual(lines[3], "-H 'X-Name: Zoë'")
        XCTAssertEqual(lines[4], "-d '{\"name\":\"Zoë 💅\"}'")
    }

    func testGeneratingDoesNotChangeTheRequest() {
        let request = post("it's")
        request.headers = [KeyValuePair(key: "A", value: "1")]
        request.queryParams = [KeyValuePair(key: "q", value: "a b")]
        let before = (request.url, request.headers, request.queryParams, request.bodyContent)
        _ = CURLGenerator().generate(from: request)
        XCTAssertEqual(request.url, before.0)
        XCTAssertEqual(request.headers, before.1)
        XCTAssertEqual(request.queryParams, before.2)
        XCTAssertEqual(request.bodyContent, before.3)
    }
}

/// curl itself accepts the generated URL: it fails to connect (exit 7) rather than refusing the URL (exit 3) or its globbing.
final class CURLGeneratorCurlParsesTests: XCTestCase {
    func testCurlAcceptsURLsWithSpacesBracesBracketsAndEscapes() throws {
        let curl = URL(fileURLWithPath: "/usr/bin/curl")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: curl.path), "curl is not installed")
        for path in ["/a?q=%2F b", "/{{id}}", "/users?filter[a]=1", "/a b c", "/100%"] {
            let request = APIRequest(name: "c", url: "http://127.0.0.1:1" + path)
            let command = CURLGenerator().generate(from: request)
            let url = try XCTUnwrap(command.components(separatedBy: " ").first { $0.hasPrefix("'http") }?.trimmingCharacters(in: CharacterSet(charactersIn: "'")))
            let process = Process()
            process.executableURL = curl
            process.arguments = ["-sS", "--max-time", "2", "-o", "/dev/null", url]
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 7, "\(path) → \(url)")
        }
    }
}
