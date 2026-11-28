import Foundation
import SwiftData
import XCTest

@testable import PostWoman

private func roundTrip<T: Codable>(_ value: T) throws -> T { try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value)) }

@MainActor
final class ModelBehaviorTests: XCTestCase {
    func testHTTPMethodRawValuesAreStableAndOrdered() throws {
        XCTAssertEqual(HTTPMethod.allCases.map(\.rawValue), ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"], "Raw values are stored and exported; the order is the menu order")
        for method in HTTPMethod.allCases {
            XCTAssertEqual(method.id, method.rawValue, method.rawValue)
            XCTAssertEqual(try roundTrip(method), method, method.rawValue)
            XCTAssertEqual(String(decoding: try JSONEncoder().encode(method), as: UTF8.self), "\"\(method.rawValue)\"", method.rawValue)
        }
        XCTAssertNil(HTTPMethod(rawValue: "get"), "Raw values are case-sensitive")
        XCTAssertThrowsError(try JSONDecoder().decode(HTTPMethod.self, from: Data(#""TRACE""#.utf8)))
    }

    func testOnlyHeadLeavesTheBodyOut() {
        XCTAssertEqual(HTTPMethod.allCases.filter { !$0.sendsBody }, [.head])
        let request = APIRequest(name: "h", url: "https://h", method: .head)
        request.bodyType = .json
        request.bodyContent = #"{"a":1}"#
        XCTAssertFalse(request.sendsBody)
        for method in [HTTPMethod.post, .patch, .options, .get] {
            request.method = method
            XCTAssertTrue(request.sendsBody, method.rawValue)
        }
        request.method = .patch
        request.bodyContent = ""
        XCTAssertFalse(request.sendsBody, "Empty content is no body for any method")
    }

    func testContentTypeRawValuesAndMimeTypes() throws {
        let table: [(ContentType, String, String?)] = [
            (.none, "None", nil), (.json, "JSON", "application/json"), (.formData, "Form Data", "multipart/form-data"),
            (.urlEncoded, "URL Encoded", "application/x-www-form-urlencoded"), (.xml, "XML", "application/xml"), (.text, "Plain Text", "text/plain")
        ]
        XCTAssertEqual(ContentType.allCases, table.map(\.0))
        for (type, raw, mime) in table {
            XCTAssertEqual(type.rawValue, raw, raw)
            XCTAssertEqual(type.id, raw, raw)
            XCTAssertEqual(type.mimeType, mime, raw)
            XCTAssertEqual(try roundTrip(type), type, raw)
        }
    }

    func testAuthenticationTypeRawValuesAreStable() throws {
        XCTAssertEqual(AuthenticationType.allCases.map(\.rawValue), ["None", "Bearer Token", "Basic Auth", "OAuth 2.0"])
        for type in AuthenticationType.allCases {
            XCTAssertEqual(type.id, type.rawValue, type.rawValue)
            XCTAssertEqual(try roundTrip(type), type, type.rawValue)
        }
    }

    func testOAuthConfigDefaultsToEmptyFieldsAndRoundTrips() throws {
        let empty = OAuthConfig()
        XCTAssertEqual([empty.authorizationURL, empty.tokenURL, empty.clientID, empty.clientSecret, empty.scope, empty.redirectURI], ["", "", "", "", "", ""])
        var config = OAuthConfig()
        config.clientID = "id"
        config.scope = "read write"
        XCTAssertEqual(try roundTrip(config), config)
        XCTAssertNotEqual(config, empty)
    }

    func testKeyValuePairDefaultsAndIdentity() throws {
        let pair = KeyValuePair()
        XCTAssertEqual(pair.key, "")
        XCTAssertEqual(pair.value, "")
        XCTAssertTrue(pair.isEnabled)
        let a = KeyValuePair(key: "Accept", value: "*/*")
        let b = KeyValuePair(key: "Accept", value: "*/*")
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a, b, "Rows with the same text are still different rows")
        XCTAssertEqual(Set([a, b, a]).count, 2)
    }

    func testKeyValuePairRoundTripsEverythingIncludingItsID() throws {
        for pair in [KeyValuePair(key: "X-Ünï", value: "a\n\"b\" 💅", isEnabled: false), KeyValuePair(key: "", value: "", isEnabled: true)] {
            let decoded = try roundTrip(pair)
            XCTAssertEqual(decoded, pair, pair.key)
            XCTAssertEqual(decoded.id, pair.id, pair.key)
            XCTAssertEqual(decoded.isEnabled, pair.isEnabled, pair.key)
        }
    }

    func testNewAPIRequestHasEmptyDefaults() {
        let before = Date()
        let request = APIRequest(name: "New Request")
        XCTAssertEqual(request.name, "New Request")
        XCTAssertEqual(request.url, "")
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.sortOrder, 0)
        XCTAssertEqual(request.headers, [])
        XCTAssertEqual(request.queryParams, [])
        XCTAssertEqual(request.bodyType, ContentType.none)
        XCTAssertEqual(request.bodyContent, "")
        XCTAssertEqual(request.authenticationType, AuthenticationType.none)
        XCTAssertNil(request.authBearerToken)
        XCTAssertNil(request.authBasicUsername)
        XCTAssertNil(request.authBasicPassword)
        XCTAssertNil(request.authOAuthConfig)
        XCTAssertNil(request.folder)
        XCTAssertGreaterThanOrEqual(request.createdAt, before)
        XCTAssertEqual(request.updatedAt.timeIntervalSince(request.createdAt), 0, accuracy: 1)
        XCTAssertNotEqual(APIRequest(name: "a").id, APIRequest(name: "a").id)
    }

    func testAPIRequestPersistsEveryFieldThroughSwiftData() throws {
        let container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let folder = Folder(name: "Users")
        container.mainContext.insert(folder)
        let request = APIRequest(name: "Create", url: "https://api.example.com/users?x=1", method: .delete, folder: folder)
        request.headers = [KeyValuePair(key: "Accept", value: "application/json"), KeyValuePair(key: "Off", value: "1", isEnabled: false)]
        request.queryParams = [KeyValuePair(key: "q", value: "é 💅")]
        request.bodyType = .urlEncoded
        request.bodyContent = "a=1&b=2"
        request.authenticationType = .basic
        request.authBasicUsername = "user"
        request.authBasicPassword = "pass"
        var oauth = OAuthConfig()
        oauth.clientID = "client"
        request.authOAuthConfig = oauth
        container.mainContext.insert(request)
        try container.mainContext.save()

        let context = ModelContext(container)
        let id = request.id
        let fetched = try XCTUnwrap(try context.fetch(FetchDescriptor<APIRequest>(predicate: #Predicate { $0.id == id })).first)
        XCTAssertEqual(fetched.name, "Create")
        XCTAssertEqual(fetched.url, "https://api.example.com/users?x=1")
        XCTAssertEqual(fetched.method, .delete)
        XCTAssertEqual(fetched.headers, request.headers, "Order, ids and enabled flags survive")
        XCTAssertEqual(fetched.queryParams, request.queryParams)
        XCTAssertEqual(fetched.bodyType, .urlEncoded)
        XCTAssertEqual(fetched.bodyContent, "a=1&b=2")
        XCTAssertEqual(fetched.authenticationType, .basic)
        XCTAssertEqual(fetched.authBasicUsername, "user")
        XCTAssertEqual(fetched.authBasicPassword, "pass")
        XCTAssertEqual(fetched.authOAuthConfig, oauth)
        XCTAssertEqual(fetched.folder?.name, "Users")
    }
}
