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
}
