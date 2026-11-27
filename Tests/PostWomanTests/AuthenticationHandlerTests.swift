import XCTest

@testable import PostWoman

final class AuthenticationHandlerTests: XCTestCase {
    private func authorization(_ type: AuthenticationType, token: String? = nil, username: String? = nil, password: String? = nil) -> String? {
        var request = URLRequest(url: URL(string: "https://example.com")!)
        AuthenticationHandler().apply(authenticationType: type, bearerToken: token, basicUsername: username, basicPassword: password, to: &request)
        return request.value(forHTTPHeaderField: "Authorization")
    }

    func testBearerTokenSetsAuthorizationHeader() {
        XCTAssertEqual(authorization(.bearer, token: "abc"), "Bearer abc")
    }

    func testEmptyBearerTokenLeavesRequestUnchanged() {
        XCTAssertNil(authorization(.bearer, token: ""))
    }

    func testBasicAuthEncodesCredentials() {
        XCTAssertEqual(authorization(.basic, username: "user", password: "pass"), "Basic dXNlcjpwYXNz")
    }

    func testNoneLeavesRequestUnchanged() {
        XCTAssertNil(authorization(.none, token: "abc"))
    }

    func testBasicAuthEncodesUTF8ColonsAndEmptyParts() {
        let cases: [(String, String, String)] = [
            ("ü", "ñ", "Basic w7w6w7E="), ("user", "", "Basic dXNlcjo="), ("a", "b:c", "Basic YTpiOmM="), ("", "", "Basic Og=="),
            ("José", "p@ss wörd 💅", "Basic Sm9zw6k6cEBzcyB3w7ZyZCDwn5KF")
        ]
        for (username, password, expected) in cases {
            XCTAssertEqual(authorization(.basic, username: username, password: password), expected, "\(username):\(password)")
        }
    }

    func testBasicAuthNeedsBothUsernameAndPassword() {
        XCTAssertNil(authorization(.basic, username: "user", password: nil))
        XCTAssertNil(authorization(.basic, username: nil, password: "pass"))
        XCTAssertNil(authorization(.basic, token: "abc"), "A bearer token is not used for Basic")
    }

    func testBearerTokenIsSentExactlyAsTyped() {
        for token in ["eyJhbGciOiJIUzI1NiJ9.e30.sig", "with space", "ünïcode"] {
            XCTAssertEqual(authorization(.bearer, token: token), "Bearer \(token)", token)
        }
        XCTAssertNil(authorization(.bearer, token: nil))
        XCTAssertNil(authorization(.bearer, username: "user", password: "pass"), "Basic credentials are not used for Bearer")
    }

    func testOAuth2IsNotAppliedYet() {
        XCTAssertNil(authorization(.oauth2, token: "abc", username: "user", password: "pass"))
    }

    func testAppliedAuthReplacesAnExistingAuthorizationHeader() {
        for (type, expected) in [(AuthenticationType.bearer, "Bearer new"), (.basic, "Basic dXNlcjpwYXNz")] {
            var request = URLRequest(url: URL(string: "https://example.com")!)
            request.setValue("Token old", forHTTPHeaderField: "Authorization")
            AuthenticationHandler().apply(authenticationType: type, bearerToken: "new", basicUsername: "user", basicPassword: "pass", to: &request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), expected, type.rawValue)
        }
    }

    func testMissingCredentialsKeepAnExistingAuthorizationHeaderAndOtherFields() {
        for type in AuthenticationType.allCases {
            var request = URLRequest(url: URL(string: "https://example.com/a?b=1")!)
            request.httpMethod = "PUT"
            request.setValue("Token kept", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            AuthenticationHandler().apply(authenticationType: type, bearerToken: "", basicUsername: nil, basicPassword: nil, to: &request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token kept", type.rawValue)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json", type.rawValue)
            XCTAssertEqual(request.httpMethod, "PUT", type.rawValue)
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/a?b=1", type.rawValue)
        }
    }
}
