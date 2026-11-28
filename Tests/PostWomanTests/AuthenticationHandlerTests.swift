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
        XCTAssertNil(authorization(.basic, username: nil, password: nil))
        XCTAssertNil(authorization(.basic, token: "abc"), "A bearer token is not used for Basic")
    }

    func testBasicAuthWithOnlyAUsernameSendsAnEmptyPassword() {
        // The password field was never touched (nil), as with an API key used as the username.
        XCTAssertEqual(authorization(.basic, username: "user", password: nil), "Basic dXNlcjo=")
        XCTAssertEqual(authorization(.basic, username: "user", password: nil), authorization(.basic, username: "user", password: ""), "Untouched is the same as emptied")
        XCTAssertEqual(authorization(.basic, username: nil, password: "pass"), "Basic OnBhc3M=")
    }

    func testGeneratedCodeSendsTheSameBasicCredentialsWhenThePasswordWasNeverTyped() {
        let request = APIRequest(name: "k", url: "https://h")
        request.authenticationType = .basic
        request.authBasicUsername = "sk_test_123"
        XCTAssertTrue(CURLGenerator().generate(from: request).contains("-u 'sk_test_123:'"))
        XCTAssertTrue(PythonGenerator().generate(from: request).contains(#"auth = ("sk_test_123", "")"#))
        XCTAssertTrue(SwiftGenerator().generate(from: request).contains(#"let credentials = "sk_test_123:""#))
        request.authBasicUsername = nil
        for code in [CURLGenerator().generate(from: request), PythonGenerator().generate(from: request), SwiftGenerator().generate(from: request)] {
            XCTAssertFalse(code.contains("-u ") || code.contains("auth") || code.contains("credentials"), code)
        }
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
