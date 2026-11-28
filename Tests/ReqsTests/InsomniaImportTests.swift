import XCTest

@testable import Reqs

final class InsomniaImportTests: XCTestCase {
    private func read(_ text: String, fileName: String = "insomnia.json") throws -> ImportedFile {
        try CollectionImport.read(Data(text.utf8), fileName: fileName)
    }

    private let version4 = #"""
        {"_type": "export", "__export_format": 4, "resources": [
          {"_id": "wrk_1", "_type": "workspace", "name": "Billing", "scope": "collection"},
          {"_id": "env_base", "_type": "environment", "parentId": "wrk_1", "name": "Base Environment", "data": {"baseUrl": "https://b.example.com", "api": {"key": "k1"}}},
          {"_id": "env_prod", "_type": "environment", "parentId": "env_base", "name": "Production", "data": {"baseUrl": "https://prod"}, "metaSortKey": 2},
          {"_id": "env_dev", "_type": "environment", "parentId": "env_base", "name": "Dev", "data": {"baseUrl": "http://dev"}, "metaSortKey": 1},
          {"_id": "fld_1", "_type": "request_group", "parentId": "wrk_1", "name": "Invoices", "metaSortKey": -10,
           "authentication": {"type": "bearer", "token": "{{ _.api.key }}"}, "environment": {"page": "1"}},
          {"_id": "req_2", "_type": "request", "parentId": "fld_1", "name": "Create", "method": "POST", "metaSortKey": 2,
           "url": "{{ _.baseUrl }}/invoices", "body": {"mimeType": "application/json", "text": "{\"id\": \"{% uuid 'v4' %}\"}"},
           "headers": [{"name": "Content-Type", "value": "application/json"}], "parameters": [], "authentication": {}},
          {"_id": "req_1", "_type": "request", "parentId": "fld_1", "name": "List", "method": "GET", "metaSortKey": 1,
           "url": "{{ baseUrl }}/invoices?status=open", "parameters": [{"name": "page", "value": "{{ _.page }}", "disabled": true}],
           "headers": [], "authentication": {}},
          {"_id": "req_3", "_type": "request", "parentId": "wrk_1", "name": "Login", "method": "POST", "metaSortKey": 5,
           "url": "https://b/login", "body": {"mimeType": "application/x-www-form-urlencoded", "params": [{"name": "u", "value": "ada"}, {"name": "x", "value": "1", "disabled": true}]},
           "headers": [], "authentication": {"type": "basic", "username": "ada", "password": "pw"}},
          {"_id": "req_4", "_type": "request", "parentId": "wrk_1", "name": "Custom", "method": "GET", "metaSortKey": 6,
           "url": "https://b/c", "headers": [], "authentication": {"type": "bearer", "token": "t", "prefix": "Token"}},
          {"_id": "ws_1", "_type": "websocket_request", "parentId": "wrk_1", "name": "Socket", "metaSortKey": 7}
        ]}
        """#

    func testVersion4WorkspaceBecomesACollectionInSortOrder() throws {
        let file = try read(version4)
        let folder = try XCTUnwrap(file.collections.first)
        XCTAssertEqual(folder.name, "Billing")
        XCTAssertEqual(folder.requests.map(\.name), ["Invoices / List", "Invoices / Create", "Login", "Custom"])
        XCTAssertEqual(folder.requests[0].url, "{{baseUrl}}/invoices")
        XCTAssertEqual(folder.requests[0].queryParams.map(\.key), ["status", "page"])
        XCTAssertEqual(folder.requests[0].queryParams.map(\.isEnabled), [true, false])
        XCTAssertEqual(folder.requests[0].queryParams.last?.value, "{{page}}")
    }

    func testVersion4EnvironmentsAndFolderAuthentication() throws {
        let folder = try XCTUnwrap(try read(version4).collections.first)
        let environments = try XCTUnwrap(folder.environments)
        XCTAssertEqual(environments.map(\.name), ["Default", "Dev", "Production"])
        XCTAssertEqual(environments[0].variables.map(\.key), ["api.key", "baseUrl", "page"])
        XCTAssertEqual(folder.requests[0].authenticationType, .bearer)
        XCTAssertEqual(folder.requests[0].authBearerToken, "{{api.key}}")
        XCTAssertEqual(folder.requests[2].authenticationType, .basic)
        XCTAssertEqual(FormBody.pairs(from: folder.requests[2].bodyContent).map(\.key), ["u"])
        XCTAssertEqual(folder.requests[3].authenticationType, .none)
        XCTAssertEqual(folder.requests[3].headers.first { $0.key == "Authorization" }?.value, "Token t")
    }

    func testVersion4Notes() throws {
        let notes = try read(version4).notes
        XCTAssertTrue(notes.contains { $0.contains("template tags") })
        XCTAssertTrue(notes.contains { $0.contains("WebSocket") })
    }

    func testVersion5YAMLCollection() throws {
        let yaml = """
            type: collection.insomnia.rest/5.0
            name: Weather
            meta:
              id: wrk_1
            collection:
              - name: Forecast
                meta:
                  sortKey: -1
                children:
                  - url: "{{ _.baseUrl }}/forecast"
                    name: Daily
                    method: GET
                    parameters:
                      - name: days
                        value: "3"
                    headers:
                      - name: Accept
                        value: application/json
              - url: "{{ _.baseUrl }}/alerts"
                name: Alerts
                method: POST
                meta:
                  sortKey: 5
                body:
                  mimeType: application/json
                  text: |-
                    {"level": "high"}
                authentication:
                  type: apikey
                  key: X-Key
                  value: "{{ _.key }}"
                  addTo: queryParams
            environments:
              name: Base Environment
              data:
                baseUrl: https://weather.example.com
                key: abc
              subEnvironments:
                - name: Local
                  data:
                    baseUrl: http://localhost:3000
            """
        let file = try read(yaml, fileName: "weather.yaml")
        XCTAssertEqual(file.format, .insomniaCollection)
        let folder = try XCTUnwrap(file.collections.first)
        XCTAssertEqual(folder.name, "Weather")
        XCTAssertEqual(folder.requests.map(\.name), ["Forecast / Daily", "Alerts"])
        XCTAssertEqual(folder.requests[0].url, "{{baseUrl}}/forecast")
        XCTAssertEqual(folder.requests[0].queryParams.first?.value, "3")
        XCTAssertEqual(folder.requests[1].bodyType, .json)
        XCTAssertEqual(folder.requests[1].bodyContent, #"{"level": "high"}"#)
        XCTAssertEqual(folder.requests[1].queryParams.first?.key, "X-Key")
        XCTAssertEqual(folder.requests[1].queryParams.first?.value, "{{key}}")
        XCTAssertEqual(folder.environments?.map(\.name), ["Default", "Local"])
        XCTAssertEqual(folder.environments?.first?.variables.map(\.key), ["baseUrl", "key"])
    }

    func testTemplateSyntax() {
        XCTAssertEqual(InsomniaImporter.variables(in: "{{ _.a }}/{{b}}/{{ _.c.d }}"), "{{a}}/{{b}}/{{c.d}}")
        XCTAssertEqual(InsomniaImporter.variables(in: "{% now %}"), "{% now %}")
    }
}
