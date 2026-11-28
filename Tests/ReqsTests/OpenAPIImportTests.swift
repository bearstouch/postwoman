import XCTest

@testable import Reqs

final class OpenAPIImportTests: XCTestCase {
    private func read(_ text: String, fileName: String = "openapi.yaml") throws -> ImportedFile {
        try CollectionImport.read(Data(text.utf8), fileName: fileName)
    }

    private let petstore = """
        openapi: 3.0.3
        info:
          title: Petstore
          version: 1.0.0
        servers:
          - url: https://{region}.pets.example.com/v1/
            description: Production
            variables:
              region:
                default: eu
          - url: http://localhost:8080
        tags:
          - name: pets
          - name: store
        security:
          - bearerAuth: []
        paths:
          /pets/{petId}:
            parameters:
              - name: petId
                in: path
                required: true
                schema:
                  type: integer
                  example: 7
            get:
              tags: [pets]
              summary: Get a pet
              parameters:
                - name: fields
                  in: query
                  schema: {type: string, default: all}
                - name: X-Trace
                  in: header
                  required: true
                  example: abc
                - name: Accept
                  in: header
                  schema: {type: string}
            delete:
              tags: [pets]
              operationId: deletePet
              security: []
          /pets:
            post:
              tags: [pets]
              requestBody:
                content:
                  application/json:
                    schema:
                      $ref: '#/components/schemas/Pet'
          /orders:
            post:
              tags: [store]
              summary: Order
              security:
                - apiKey: []
              requestBody:
                $ref: '#/components/requestBodies/Order'
          /login:
            post:
              summary: Log in
              security:
                - basic: []
              requestBody:
                content:
                  application/x-www-form-urlencoded:
                    schema:
                      type: object
                      properties:
                        user: {type: string, example: ada}
                        avatar: {type: string, format: binary}
        components:
          securitySchemes:
            bearerAuth: {type: http, scheme: bearer}
            apiKey: {type: apiKey, in: header, name: X-API-Key}
            basic: {type: http, scheme: basic}
          requestBodies:
            Order:
              content:
                application/json:
                  example: {"petId": 7, "quantity": 2}
          schemas:
            Pet:
              type: object
              required: [name]
              properties:
                id: {type: integer, readOnly: true}
                name: {type: string, example: Rex}
                tags:
                  type: array
                  items: {type: string}
                born: {type: string, format: date}
                owner:
                  $ref: '#/components/schemas/Owner'
            Owner:
              type: object
              properties:
                name: {type: string}
                pets:
                  type: array
                  items:
                    $ref: '#/components/schemas/Pet'
        """

    func testOperationsGroupedByTagWithBaseURL() throws {
        let file = try read(petstore)
        XCTAssertEqual(file.format, .openAPI)
        let folder = try XCTUnwrap(file.collections.first)
        XCTAssertEqual(folder.name, "Petstore")
        XCTAssertEqual(folder.requests.map(\.name), ["pets / POST /pets", "pets / Get a pet", "pets / deletePet", "store / Order", "Log in"])
        XCTAssertEqual(folder.requests[1].url, "{{baseUrl}}/pets/{{petId}}")
        XCTAssertEqual(folder.requests.map(\.method), [.post, .get, .delete, .post, .post])
    }

    func testServersBecomeDefaultAndOtherEnvironments() throws {
        let environments = try XCTUnwrap(try read(petstore).collections.first?.environments)
        XCTAssertEqual(environments.map(\.name), ["Default", "http://localhost:8080"])
        let defaults = environments[0].variables
        XCTAssertEqual(defaults.first { $0.key == "baseUrl" }?.value, "https://eu.pets.example.com/v1")
        XCTAssertEqual(defaults.first { $0.key == "petId" }?.value, "7")
        XCTAssertEqual(defaults.first { $0.key == "bearerToken" }?.isSecret, true)
        XCTAssertEqual(environments[1].variables.first?.value, "http://localhost:8080")
    }

    func testParametersTakeExamplesAndAreEnabledWhenRequired() throws {
        let get = try XCTUnwrap(try read(petstore).collections.first?.requests[1])
        XCTAssertEqual(get.queryParams.map(\.key), ["fields"])
        XCTAssertEqual(get.queryParams.first?.value, "all")
        XCTAssertEqual(get.queryParams.first?.isEnabled, false)
        XCTAssertEqual(get.headers.map(\.key), ["X-Trace"], "Accept is not a parameter in OpenAPI")
        XCTAssertEqual(get.headers.first?.isEnabled, true)
    }

    func testSecuritySchemesBecomeAuthenticationWithVariables() throws {
        let requests = try XCTUnwrap(try read(petstore).collections.first?.requests)
        XCTAssertEqual(requests[1].authenticationType, .bearer)
        XCTAssertEqual(requests[1].authBearerToken, "{{bearerToken}}")
        XCTAssertEqual(requests[2].authenticationType, .none, "security: [] turns it off")
        XCTAssertEqual(requests[3].headers.first { $0.key == "X-API-Key" }?.value, "{{apiKey}}")
        XCTAssertEqual(requests[4].authenticationType, .basic)
        XCTAssertEqual(requests[4].authBasicUsername, "{{username}}")
    }

    func testBodiesComeFromExamplesOrSchemas() throws {
        let requests = try XCTUnwrap(try read(petstore).collections.first?.requests)
        XCTAssertEqual(requests[0].bodyType, .json)
        let pet = try JSONDecoder().decode(JSONValue.self, from: Data(requests[0].bodyContent.utf8))
        XCTAssertEqual(pet["name"], .string("Rex"))
        XCTAssertNil(pet["id"], "read-only properties are left out")
        XCTAssertEqual(pet["tags"], .array([.string("string")]))
        XCTAssertEqual(pet["born"], .string("2026-01-01"))
        XCTAssertNotNil(pet["owner"]?["pets"], "a schema that refers back to itself stops instead of looping")
        let order = try JSONDecoder().decode(JSONValue.self, from: Data(requests[3].bodyContent.utf8))
        XCTAssertEqual(order["quantity"], .number(2))
        XCTAssertEqual(requests[4].bodyType, .urlEncoded)
        XCTAssertEqual(FormBody.pairs(from: requests[4].bodyContent).map(\.key), ["user"])
    }

    func testSwagger2JSON() throws {
        let file = try read(
            #"""
            {"swagger": "2.0", "info": {"title": "Legacy"}, "host": "api.example.com", "basePath": "/v2", "schemes": ["https"],
             "securityDefinitions": {"key": {"type": "apiKey", "in": "query", "name": "api_key"}},
             "paths": {
               "/users": {"post": {"summary": "Create", "security": [{"key": []}], "parameters": [
                 {"in": "body", "name": "body", "schema": {"$ref": "#/definitions/User"}}]}},
               "/upload": {"post": {"summary": "Upload", "consumes": ["multipart/form-data"], "parameters": [
                 {"in": "formData", "name": "title", "type": "string", "default": "x"},
                 {"in": "formData", "name": "file", "type": "file"}]}}
             },
             "definitions": {"User": {"type": "object", "properties": {"name": {"type": "string"}, "age": {"type": "integer"}}}}}
            """#, fileName: "swagger.json")
        XCTAssertEqual(file.format, .swagger)
        let folder = try XCTUnwrap(file.collections.first)
        XCTAssertEqual(folder.environments?.first?.variables.first { $0.key == "baseUrl" }?.value, "https://api.example.com/v2")
        XCTAssertEqual(folder.requests.map(\.name), ["Upload", "Create"])
        let create = folder.requests[1]
        XCTAssertEqual(create.bodyType, .json)
        let user = try JSONDecoder().decode(JSONValue.self, from: Data(create.bodyContent.utf8))
        XCTAssertEqual(user, .object(["name": .string("string"), "age": .number(0)]))
        XCTAssertEqual(create.queryParams.first { $0.key == "api_key" }?.value, "{{key}}")
        XCTAssertEqual(folder.requests[0].bodyType, .formData)
        XCTAssertEqual(FormBody.pairs(from: folder.requests[0].bodyContent).map(\.key), ["title"])
        XCTAssertTrue(file.notes.contains(ImportSupport.fileFieldsNote))
    }

    func testExternalReferencesAreNotedAndSkipped() throws {
        let file = try read(
            """
            openapi: 3.1.0
            info: {title: Ext}
            paths:
              /a:
                post:
                  requestBody:
                    $ref: 'other.yaml#/components/requestBodies/A'
            """)
        XCTAssertEqual(file.collections.first?.requests.first?.bodyType, ContentType.none)
        XCTAssertTrue(file.notes.contains { $0.contains("other files") })
    }

    func testNoServerAsksForBaseURL() throws {
        let file = try read("openapi: 3.0.0\ninfo:\n  title: Bare\npaths:\n  /x:\n    get: {}\n")
        XCTAssertEqual(file.collections.first?.requests.first?.name, "GET /x")
        XCTAssertTrue(file.notes.contains { $0.contains("baseUrl") })
    }
}
