import XCTest

@testable import Reqs

final class PostmanImportTests: XCTestCase {
    private func read(_ text: String, fileName: String = "file.json") throws -> ImportedFile {
        try CollectionImport.read(Data(text.utf8), fileName: fileName)
    }

    private let collection = #"""
        {
          "info": {"name": "Shop", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},
          "auth": {"type": "bearer", "bearer": [{"key": "token", "value": "{{token}}", "type": "string"}]},
          "variable": [{"key": "baseUrl", "value": "https://shop.example.com"}, {"key": "token", "value": "abc", "type": "secret"}],
          "item": [
            {"name": "Products", "item": [
              {"name": "List", "request": {
                "method": "GET",
                "header": [{"key": "Accept", "value": "application/json"}, {"key": "X-Off", "value": "1", "disabled": true}],
                "url": {"raw": "{{baseUrl}}/products?page=1&size=20", "host": ["{{baseUrl}}"], "path": ["products"],
                        "query": [{"key": "page", "value": "1"}, {"key": "size", "value": "20", "disabled": true}]}
              }},
              {"name": "Get", "request": {"method": "GET", "url": {"raw": "{{baseUrl}}/products/:id", "variable": [{"key": "id", "value": "42"}]}}},
              {"name": "Open", "request": {"method": "GET", "auth": {"type": "noauth"}, "url": "{{baseUrl}}/health"}}
            ]},
            {"name": "Create", "event": [{"listen": "test", "script": {"exec": ["pm.test('ok')"]}}], "request": {
              "method": "POST",
              "auth": {"type": "basic", "basic": [{"key": "username", "value": "ada"}, {"key": "password", "value": "pw"}]},
              "body": {"mode": "raw", "raw": "{\"name\": \"{{$guid}}\"}", "options": {"raw": {"language": "json"}}},
              "url": "{{baseUrl}}/products"
            }},
            {"name": "Login", "request": {"method": "POST", "body": {"mode": "urlencoded", "urlencoded": [
              {"key": "user", "value": "a b"}, {"key": "off", "value": "x", "disabled": true}]}, "url": "{{baseUrl}}/login"}},
            {"name": "Upload", "request": {"method": "PUT", "body": {"mode": "formdata", "formdata": [
              {"key": "title", "value": "Hi", "type": "text"}, {"key": "file", "src": "/tmp/a.png", "type": "file"}]}, "url": "{{baseUrl}}/upload"}},
            {"name": "Query", "request": {"method": "POST", "body": {"mode": "graphql", "graphql": {"query": "{ me { id } }", "variables": "{\"a\": 1}"}}, "url": "{{baseUrl}}/graphql"}}
          ]
        }
        """#

    func testFoldersFlattenIntoRequestNamesInOrder() throws {
        let file = try read(collection)
        XCTAssertEqual(file.format, .postmanCollection)
        let folder = try XCTUnwrap(file.collections.first)
        XCTAssertEqual(folder.name, "Shop")
        XCTAssertEqual(folder.requests.map(\.name), ["Products / List", "Products / Get", "Products / Open", "Create", "Login", "Upload", "Query"])
    }

    func testURLQueryAndHeadersKeepTheirEnabledState() throws {
        let list = try XCTUnwrap(try read(collection).collections.first?.requests.first)
        XCTAssertEqual(list.url, "{{baseUrl}}/products")
        XCTAssertEqual(list.queryParams.map(\.key), ["page", "size"])
        XCTAssertEqual(list.queryParams.map(\.isEnabled), [true, false])
        XCTAssertEqual(list.headers.map(\.key), ["Accept", "X-Off"])
        XCTAssertEqual(list.headers.map(\.isEnabled), [true, false])
    }

    func testPathVariablesTakeTheirValues() throws {
        XCTAssertEqual(try read(collection).collections.first?.requests[1].url, "{{baseUrl}}/products/42")
        XCTAssertEqual(PostmanImporter.replacingPathVariable("id", with: "{{id}}", in: "https://h/:id/x/:idx"), "https://h/{{id}}/x/:idx")
    }

    func testAuthenticationIsInheritedUnlessTheRequestSetsItsOwn() throws {
        let requests = try XCTUnwrap(try read(collection).collections.first?.requests)
        XCTAssertEqual(requests[0].authenticationType, .bearer)
        XCTAssertEqual(requests[0].authBearerToken, "{{token}}")
        XCTAssertEqual(requests[2].authenticationType, .none, "noauth turns inheritance off")
        XCTAssertEqual(requests[3].authenticationType, .basic)
        XCTAssertEqual(requests[3].authBasicUsername, "ada")
        XCTAssertEqual(requests[3].authBasicPassword, "pw")
    }

    func testBodiesOfEachMode() throws {
        let requests = try XCTUnwrap(try read(collection).collections.first?.requests)
        XCTAssertEqual(requests[3].bodyType, .json)
        XCTAssertEqual(requests[3].bodyContent, #"{"name": "{{$guid}}"}"#)
        XCTAssertEqual(requests[4].bodyType, .urlEncoded)
        XCTAssertEqual(FormBody.pairs(from: requests[4].bodyContent).map(\.key), ["user"], "disabled fields are left out")
        XCTAssertEqual(FormBody.pairs(from: requests[4].bodyContent).first?.value, "a b")
        XCTAssertEqual(requests[5].bodyType, .formData)
        XCTAssertEqual(FormBody.pairs(from: requests[5].bodyContent).map(\.key), ["title"], "file fields are left out")
        XCTAssertEqual(requests[6].bodyType, .json)
        let graphQL = try JSONDecoder().decode(JSONValue.self, from: Data(requests[6].bodyContent.utf8))
        XCTAssertEqual(graphQL["query"], .string("{ me { id } }"))
        XCTAssertEqual(graphQL["variables"]?["a"], .number(1))
    }

    func testCollectionVariablesBecomeDefaultWithSecretsMarked() throws {
        let environment = try XCTUnwrap(try read(collection).collections.first?.environments?.first)
        XCTAssertTrue(environment.isDefault)
        XCTAssertEqual(environment.variables.map(\.key), ["baseUrl", "token"])
        XCTAssertEqual(environment.variables.map(\.isSecret), [false, true])
    }

    func testNotesSayWhatWasLeftOut() throws {
        let notes = try read(collection).notes
        XCTAssertTrue(notes.contains(ImportSupport.scriptsNote))
        XCTAssertTrue(notes.contains(ImportSupport.fileFieldsNote))
        XCTAssertTrue(notes.contains { $0.contains("dynamic variables") })
        XCTAssertTrue(notes.contains { $0.contains("GraphQL") })
    }

    func testVersion20AuthAndAPIKeyFromAFolder() throws {
        let file = try read(
            #"""
            {"info": {"name": "Old", "schema": "https://schema.getpostman.com/json/collection/v2.0.0/collection.json"},
             "item": [
               {"name": "F", "auth": {"type": "apikey", "apikey": {"key": "X-Key", "value": "k", "in": "header"}}, "item": [
                 {"name": "A", "request": {"method": "GET", "url": "https://h/a?x=1"}}]},
               {"name": "B", "request": {"method": "GET", "auth": {"type": "bearer", "bearer": {"token": "t"}}, "url": "https://h/b"}},
               {"name": "C", "request": {"method": "GET", "auth": {"type": "digest"}, "url": "https://h/c"}},
               {"name": "D", "request": {"method": "GET", "auth": {"type": "oauth2", "oauth2": [{"key": "accessToken", "value": ""}]}, "url": "https://h/d"}}
             ]}
            """#)
        let requests = try XCTUnwrap(file.collections.first?.requests)
        XCTAssertEqual(requests[0].headers.map(\.key), ["X-Key"])
        XCTAssertEqual(requests[0].queryParams.map(\.key), ["x"])
        XCTAssertEqual(requests[1].authBearerToken, "t")
        XCTAssertEqual(requests[2].authenticationType, .none)
        XCTAssertEqual(requests[3].authBearerToken, "{{accessToken}}")
        XCTAssertTrue(file.notes.contains { $0.hasPrefix("Digest authentication") })
        XCTAssertTrue(file.notes.contains(ImportSupport.oauthNote))
    }

    func testUnsupportedMethodsAreImportedAsGETWithANote() throws {
        let file = try read(#"{"info": {"name": "M"}, "item": [{"name": "T", "request": {"method": "TRACE", "url": "https://h"}}]}"#)
        XCTAssertEqual(file.collections.first?.requests.first?.method, .get)
        XCTAssertTrue(file.notes.contains { $0.contains("TRACE") })
    }

    func testEnvironmentFileComesWithoutACollection() throws {
        let file = try read(
            #"""
            {"id": "1", "name": "Staging", "_postman_variable_scope": "environment", "values": [
              {"key": "baseUrl", "value": "https://staging", "enabled": true},
              {"key": "key", "value": "s3cret", "type": "secret", "enabled": true},
              {"key": "old", "value": "x", "enabled": false}]}
            """#)
        XCTAssertTrue(file.collections.isEmpty)
        let environment = try XCTUnwrap(file.environments.first)
        XCTAssertEqual(environment.name, "Staging")
        XCTAssertFalse(environment.isDefault)
        XCTAssertEqual(environment.variables.map(\.key), ["baseUrl", "key", "old"])
        XCTAssertEqual(environment.variables.map(\.isSecret), [false, true, false])
        XCTAssertEqual(environment.variables.map(\.isEnabled), [true, true, false])
    }

    func testVersion1CollectionsAreRefusedWithWhatToDo() {
        XCTAssertThrowsError(try read(#"{"id": "1", "name": "Old", "order": [], "requests": []}"#, fileName: "old.json")) { error in
            XCTAssertTrue(error.localizedDescription.contains("v2.1"))
        }
    }
}
