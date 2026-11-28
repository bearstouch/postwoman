import XCTest

@testable import Reqs

final class HoppscotchImportTests: XCTestCase {
    private func read(_ text: String, fileName: String = "hoppscotch.json") throws -> ImportedFile {
        try CollectionImport.read(Data(text.utf8), fileName: fileName)
    }

    private let collections = #"""
        [{
          "v": 2, "name": "Users",
          "auth": {"authType": "bearer", "authActive": true, "token": "<<token>>"},
          "headers": [{"key": "X-Team", "value": "core", "active": true}],
          "requests": [
            {"v": "6", "name": "List", "method": "GET", "endpoint": "<<baseUrl>>/users?limit=10",
             "params": [{"key": "sort", "value": "name", "active": false}],
             "headers": [{"key": "Accept", "value": "application/json", "active": true}],
             "auth": {"authType": "inherit", "authActive": true}, "body": {"contentType": null, "body": null},
             "preRequestScript": "", "testScript": "pw.test('x')",
             "requestVariables": [{"key": "limit", "value": "10", "active": true}]},
            {"v": "6", "name": "Create", "method": "POST", "endpoint": "<<baseUrl>>/users/<<id>>",
             "params": [], "headers": [{"key": "X-Team", "value": "own", "active": true}],
             "auth": {"authType": "basic", "authActive": true, "username": "ada", "password": "<<pw>>"},
             "body": {"contentType": "application/json", "body": "{\"name\": \"<<name>>\"}"},
             "requestVariables": [{"key": "id", "value": "7", "active": true}]}
          ],
          "folders": [{
            "v": 2, "name": "Admin", "auth": {"authType": "api-key", "authActive": true, "key": "X-Admin", "value": "k", "addTo": "HEADERS"}, "headers": [],
            "folders": [],
            "requests": [
              {"name": "Form", "method": "PUT", "endpoint": "https://h/form", "params": [], "headers": [],
               "auth": {"authType": "inherit", "authActive": true},
               "body": {"contentType": "multipart/form-data", "body": [
                 {"key": "a", "value": "1", "active": true, "isFile": false}, {"key": "f", "value": [], "active": true, "isFile": true}]}},
              {"name": "Encoded", "method": "POST", "endpoint": "https://h/enc", "params": [], "headers": [],
               "auth": {"authType": "none", "authActive": true},
               "body": {"contentType": "application/x-www-form-urlencoded", "body": "a: 1\n#b: 2\nc: <<x>>"}},
              {"name": "Page", "method": "POST", "endpoint": "https://h/html", "params": [], "headers": [],
               "auth": {"authType": "bearer", "authActive": false, "token": "x"},
               "body": {"contentType": "text/html", "body": "<p>hi</p>"}}
            ]
          }]
        }]
        """#

    func testCollectionsFoldersAndVariableSyntax() throws {
        let file = try read(collections)
        XCTAssertEqual(file.format, .hoppscotchCollection)
        let folder = try XCTUnwrap(file.collections.first)
        XCTAssertEqual(folder.name, "Users")
        XCTAssertEqual(folder.requests.map(\.name), ["List", "Create", "Admin / Form", "Admin / Encoded", "Admin / Page"])
        let list = folder.requests[0]
        XCTAssertEqual(list.url, "{{baseUrl}}/users")
        XCTAssertEqual(list.queryParams.map(\.key), ["limit", "sort"])
        XCTAssertEqual(list.queryParams.map(\.isEnabled), [true, false])
        XCTAssertEqual(folder.requests[1].url, "{{baseUrl}}/users/7", "request variables are written in")
        XCTAssertEqual(folder.requests[1].bodyContent, #"{"name": "{{name}}"}"#)
    }

    func testAuthenticationAndHeadersAreInherited() throws {
        let requests = try XCTUnwrap(try read(collections).collections.first?.requests)
        XCTAssertEqual(requests[0].authenticationType, .bearer)
        XCTAssertEqual(requests[0].authBearerToken, "{{token}}")
        XCTAssertEqual(requests[0].headers.map(\.key), ["X-Team", "Accept"])
        XCTAssertEqual(requests[1].headers.map(\.value), ["own"], "the request's own header wins over the collection's")
        XCTAssertEqual(requests[1].authenticationType, .basic)
        XCTAssertEqual(requests[1].authBasicPassword, "{{pw}}")
        XCTAssertEqual(requests[2].headers.first { $0.key == "X-Admin" }?.value, "k", "the folder's API key")
        XCTAssertEqual(requests[3].authenticationType, .none)
        XCTAssertEqual(requests[4].authenticationType, .none, "inactive authentication is none")
    }

    func testBodies() throws {
        let requests = try XCTUnwrap(try read(collections).collections.first?.requests)
        XCTAssertEqual(requests[2].bodyType, .formData)
        XCTAssertEqual(FormBody.pairs(from: requests[2].bodyContent).map(\.key), ["a"])
        XCTAssertEqual(requests[3].bodyType, .urlEncoded)
        XCTAssertEqual(FormBody.pairs(from: requests[3].bodyContent).map(\.key), ["a", "c"])
        XCTAssertEqual(FormBody.pairs(from: requests[3].bodyContent).last?.value, "{{x}}")
        XCTAssertEqual(requests[4].bodyType, .text)
        XCTAssertEqual(requests[4].headers.first { $0.key == "Content-Type" }?.value, "text/html")
    }

    func testNotes() throws {
        let notes = try read(collections).notes
        XCTAssertTrue(notes.contains(ImportSupport.scriptsNote))
        XCTAssertTrue(notes.contains(ImportSupport.fileFieldsNote))
    }

    func testEnvironmentsOldAndNewShapes() throws {
        let file = try read(
            #"""
            [{"name": "Local", "variables": [{"key": "baseUrl", "value": "http://localhost"}]},
             {"v": 1, "id": "x", "name": "Prod", "variables": [
               {"key": "baseUrl", "initialValue": "https://prod", "currentValue": "https://mine", "secret": false},
               {"key": "token", "initialValue": "", "currentValue": "", "secret": true}]}]
            """#)
        XCTAssertTrue(file.collections.isEmpty)
        XCTAssertEqual(file.environments.map(\.name), ["Local", "Prod"])
        XCTAssertEqual(file.environments[1].variables.map(\.value), ["https://prod", ""])
        XCTAssertEqual(file.environments[1].variables.map(\.isSecret), [false, true])
        XCTAssertTrue(file.notes.contains { $0.contains("secret values") })
        XCTAssertNotEqual(file.environments[0].color, file.environments[1].color)
    }

    func testKeyValueLines() {
        XCTAssertEqual(HoppscotchImporter.keyValueLines("a: 1\n # b: 2\nurl: http://x").map(\.key), ["a", "b", "url"])
        XCTAssertEqual(HoppscotchImporter.keyValueLines("a: 1\n # b: 2\nurl: http://x").map(\.isEnabled), [true, false, true])
        XCTAssertEqual(HoppscotchImporter.keyValueLines("url: http://x").first?.value, "http://x")
    }
}
