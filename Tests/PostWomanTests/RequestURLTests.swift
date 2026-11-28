import Foundation
import XCTest

@testable import PostWoman

final class RequestURLTests: XCTestCase {
    func testWhitespaceAroundTheURLIsDropped() {
        // A pasted URL often ends with a space or a newline: it was sent as %20, or refused as an invalid URL.
        XCTAssertEqual(RequestURL.encoded(" https://x.com/a b \n"), "https://x.com/a%20b")
        XCTAssertEqual(RequestURL.encoded("https://example.com "), "https://example.com")
        XCTAssertEqual(RequestURL.encoded("\thttps://example.com/users"), "https://example.com/users")
        XCTAssertEqual(RequestURL.encoded("  example.com/x  "), "example.com/x", "Also without a scheme")
        XCTAssertEqual(RequestURL.encoded("https://x.com/a%20"), "https://x.com/a%20", "An encoded space at the end is part of the URL")
    }

    func testOnlyCharactersAURLCantHoldAreEncoded() {
        let cases: [(String, String)] = [
            ("https://x.test/a?q=%2F b", "https://x.test/a?q=%2F%20b"), ("https://x.test/a%20b c", "https://x.test/a%20b%20c"),
            ("https://x.test/users?filter[a]=1", "https://x.test/users?filter%5Ba%5D=1"), ("https://x.test/{{id}}", "https://x.test/%7B%7Bid%7D%7D"),
            ("https://x.test/caf\u{E9}?q=\u{1F600}", "https://x.test/caf%C3%A9?q=%F0%9F%98%80"), ("https://x.test/a\"<>\\^`|", "https://x.test/a%22%3C%3E%5C%5E%60%7C"),
            ("https://x.test/100%", "https://x.test/100%25"), ("https://x.test/a?p=50%off", "https://x.test/a?p=50%25off"), ("https://x.test/%zz%4", "https://x.test/%25zz%254")
        ]
        for (typed, encoded) in cases { XCTAssertEqual(RequestURL.encoded(typed), encoded, typed) }
    }

    func testValidURLsAreKeptAsWritten() {
        for url in [
            "https://x.test", "https://x.test/", "https://x.test/a/b?c=d&e=f+g#frag", "https://x.test/a%2Fb?q=%2F", "http://[::1]:8080/x?y=1", "https://user:pw@x.test/~me/(a);b,c*!$'",
            "https://x.test/a?b=c:d@e/f?g#h?i", "https://x.test/?", "https://x.test/?a=1&"
        ] {
            XCTAssertEqual(RequestURL.encoded(url), url, url)
        }
    }

    func testTheSchemeAndHostAreLeftAlone() {
        XCTAssertEqual(RequestURL.encoded("https://b\u{FC}cher.example/b\u{FC}cher"), "https://b\u{FC}cher.example/b%C3%BCcher", "An international host name is the system's to convert")
        XCTAssertEqual(RequestURL.encoded("http://[fe80::1%25en0]:80/a b"), "http://[fe80::1%25en0]:80/a%20b", "An IPv6 host keeps its brackets and zone")
        XCTAssertEqual(RequestURL.encoded("https://x.test?q=a b"), "https://x.test?q=a%20b", "A query right after the host")
        XCTAssertEqual(RequestURL.encoded("https://x.test#a b"), "https://x.test#a%20b")
    }

    func testTextWithoutASchemeIsUnchanged() {
        for text in ["", "x.test/a b", "{{base}}/users", "localhost:8080/a b"] { XCTAssertEqual(RequestURL.encoded(text), text, text) }
    }

    func testEncodingTwiceChangesNothing() {
        for url in ["https://x.test/a?q=%2F b", "https://x.test/{{id}}/[x]", "https://x.test/100%", "https://x.test/caf\u{E9}"] {
            let once = RequestURL.encoded(url)
            XCTAssertEqual(RequestURL.encoded(once), once, url)
        }
    }

    func testFoundationParsesTheResultWithoutEncodingItAgain() throws {
        for url in ["https://x.test/a?q=%2F b", "https://x.test/a%20b c", "https://x.test/users?filter[a]=1&t={{t}}", "https://x.test/100%"] {
            let encoded = RequestURL.encoded(url)
            XCTAssertEqual(try XCTUnwrap(URLComponents(string: encoded)?.url?.absoluteString, url), encoded, url)
        }
    }
}
