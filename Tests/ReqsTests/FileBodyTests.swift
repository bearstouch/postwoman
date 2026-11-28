import Foundation
import SwiftData
import XCTest

@testable import Reqs

/// Bytes no text encoding would keep as they are: NUL, invalid UTF-8, CR LF.
private let binary = Data([0x00, 0xFF, 0xFE, 0x0D, 0x0A, 0x89, 0x50, 0x4E, 0x47, 0x00])

private func fileRequest(_ data: Data? = binary, name: String? = "photo.png", method: HTTPMethod = .post, url: String = "https://api.example.com/upload") -> APIRequest {
    let request = APIRequest(name: "Upload", url: url, method: method)
    request.bodyType = .file
    request.bodyFile = data
    request.bodyFileName = name
    request.bodyFileSize = data?.count
    return request
}

/// A fresh directory for files a test writes, removed afterwards.
private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FileBodyTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// A target server that answers with what it received: method, Content-Type and the body as base64.
private func echoServer() throws -> (MCPListener, UInt16) {
    let listener = MCPListener { request in
        let echoed = Reqs.JSONValue.object([
            "method": .string(request.method), "contentType": .from(request.header("content-type")), "body": .string(request.body.base64EncodedString())
        ])
        return .json(200, echoed.data)
    }
    return (listener, try listener.start(address: "127.0.0.1", port: 0))
}

private func echoed(_ text: String?) throws -> (method: String, contentType: String?, body: Data) {
    let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(XCTUnwrap(text).utf8)) as? [String: Any])
    return (object["method"] as? String ?? "", object["contentType"] as? String, try XCTUnwrap(Data(base64Encoded: object["body"] as? String ?? "")))
}

// MARK: - Model, snapshot, History, export

@MainActor
final class FileBodyTests: XCTestCase {
    private func store() throws -> ModelContainer {
        try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    func testTheContentTypeComesFromTheFileNameElseOctetStream() {
        XCTAssertEqual(FileBody.mimeType(forFileName: "photo.png"), "image/png")
        XCTAssertEqual(FileBody.mimeType(forFileName: "Report.PDF"), "application/pdf")
        XCTAssertEqual(FileBody.mimeType(forFileName: "data.json"), "application/json")
        for name in [nil, "", "README", "archive.notarealextension"] {
            XCTAssertEqual(FileBody.mimeType(forFileName: name), "application/octet-stream", name ?? "nil")
        }
    }

    func testGeneratedCodeReadsTheFileByItsNameOnly() {
        XCTAssertEqual(FileBody.codePath(forFileName: "photo.png"), "photo.png")
        XCTAssertEqual(FileBody.codePath(forFileName: "../../etc/passwd"), "passwd", "An agent's name can't point code elsewhere")
        XCTAssertEqual(FileBody.codePath(forFileName: "-"), "./-", "curl reads @- as standard input")
        XCTAssertEqual(FileBody.codePath(forFileName: "-rf"), "./-rf")
        for name in [nil, "", "/", ".", ".."] { XCTAssertEqual(FileBody.codePath(forFileName: name), "file", name ?? "nil") }
    }

    func testReadingAFileKeepsItsBytesAndName() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("photo.png")
        try binary.write(to: url)
        let file = try FileBody.read(url)
        XCTAssertEqual(file.name, "photo.png")
        XCTAssertEqual(file.data, binary)
        let empty = directory.appendingPathComponent("empty.bin")
        try Data().write(to: empty)
        XCTAssertEqual(try FileBody.read(empty).data, Data(), "An empty file is a file")
    }

    func testAFileOverTheLimitAFolderOrAMissingFileIsRefused() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Sparse: refused from its size, without reading 25 MB.
        let big = directory.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(FileBody.maximumSize + 1))
        try handle.close()
        XCTAssertThrowsError(try FileBody.read(big)) { error in
            XCTAssertEqual(error as? FileBody.Failure, .tooLarge("big.bin", FileBody.maximumSize + 1))
            XCTAssertTrue(error.localizedDescription.contains("at most"), error.localizedDescription)
        }
        XCTAssertThrowsError(try FileBody.read(directory)) { XCTAssertEqual($0 as? FileBody.Failure, .notAFile(directory.lastPathComponent)) }
        XCTAssertThrowsError(try FileBody.read(directory.appendingPathComponent("gone.txt"))) { XCTAssertEqual($0 as? FileBody.Failure, .unreadable("gone.txt")) }
    }

    func testAFileBodyIsSentOnlyWithItsBytesAndABodyMethod() {
        XCTAssertTrue(fileRequest().sendsBody)
        XCTAssertTrue(fileRequest(Data()).sendsBody, "An empty file is sent (empty)")
        XCTAssertFalse(fileRequest(nil).sendsBody)
        XCTAssertTrue(fileRequest(nil).lacksBodyFile)
        XCTAssertFalse(fileRequest(nil, method: .get).lacksBodyFile, "GET sends no body, so nothing is missing")
        XCTAssertFalse(fileRequest(method: .get).sendsBody)
        XCTAssertFalse(fileRequest().lacksBodyFile)
        let leftover = fileRequest(nil)
        leftover.bodyContent = "text from another body type"
        XCTAssertFalse(leftover.sendsBody, "Text kept from another body type isn't a file")
        XCTAssertEqual(fileRequest().bodyMIMEType, "image/png")
        let json = APIRequest(name: "j", method: .post)
        json.bodyType = .json
        XCTAssertEqual(json.bodyMIMEType, "application/json")
    }

    func testResolvingVariablesLeavesTheFileAsItIs() {
        let request = fileRequest(Data("{{token}}".utf8), name: "{{token}}.txt")
        request.bodyContent = "{{missing}}"
        let resolver = VariableResolver(defaults: [Variable(key: "token", value: "abc")], selected: nil)
        let resolved = RequestSnapshot(request).resolved(with: resolver)
        XCTAssertEqual(resolved.bodyFile, Data("{{token}}".utf8), "A file's bytes are sent as they are")
        XCTAssertEqual(resolved.bodyFileName, "{{token}}.txt")
        XCTAssertEqual(RequestSnapshot(request).missingVariables(with: resolver), [], "Text left from another body type isn't sent, so it can't be missing")
    }

    func testHistoryKeepsTheFileNameAndSizeButNeverItsBytes() throws {
        let container = try store()
        let request = fileRequest()
        container.mainContext.insert(request)
        let entry = RequestHistory(request: request)
        XCTAssertNil(entry.requestBody)
        XCTAssertEqual(entry.bodyType, .file)
        XCTAssertEqual(entry.requestBodyFileName, "photo.png")
        XCTAssertEqual(entry.requestBodyFileSize, binary.count)
        XCTAssertEqual(HistoryDetailView.fileSummary(of: entry), "photo.png · \(FileBody.formattedSize(binary.count)) · image/png")

        let restored = entry.makeRequest()
        XCTAssertEqual(restored.bodyType, .file)
        XCTAssertEqual(restored.bodyFileName, "photo.png")
        XCTAssertNil(restored.bodyFile, "History has no bytes to restore")
        XCTAssertTrue(restored.lacksBodyFile)

        let unsent = RequestHistory(request: fileRequest(method: .get))
        XCTAssertEqual(unsent.bodyType, ContentType.none, "A GET sends no file, so none is recorded")
        XCTAssertNil(unsent.requestBodyFileName)
        XCTAssertNil(HistoryDetailView.fileSummary(of: unsent))
    }

    func testHistoryShowsTheContentTypeTheRequestSent() {
        let request = fileRequest()
        request.headers = [KeyValuePair(key: "content-type", value: "application/vnd.custom")]
        XCTAssertEqual(HistoryDetailView.fileSummary(of: RequestHistory(request: request)), "photo.png · \(FileBody.formattedSize(binary.count)) · application/vnd.custom")
    }

    func testDuplicatingARequestCopiesItsFile() throws {
        let container = try store()
        let folder = Folder(name: "F")
        container.mainContext.insert(folder)
        let request = fileRequest()
        request.folder = folder
        container.mainContext.insert(request)
        let copy = SidebarActions.duplicate(request, in: folder, context: container.mainContext)
        XCTAssertEqual(copy.bodyFile, binary)
        XCTAssertEqual(copy.bodyFileName, "photo.png")
        XCTAssertEqual(copy.bodyType, .file)
    }

    func testAnExportKeepsTheFileNameButNeverTheFile() throws {
        let container = try store()
        let folder = Folder(name: "Uploads")
        container.mainContext.insert(folder)
        let request = fileRequest()
        request.folder = folder
        container.mainContext.insert(request)
        let leftover = fileRequest()
        leftover.bodyType = .json
        leftover.bodyContent = "{}"
        leftover.folder = folder
        container.mainContext.insert(leftover)
        let data = try ExportImportService.exportFolder(folder)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(binary.base64EncodedString()), "No file bytes in an export")
        let imported = ExportImportService.insert(try ExportImportService.decodeFolder(from: data), context: container.mainContext, sortOrder: 1)
        let copies = imported.requests ?? []
        let file = try XCTUnwrap(copies.first { $0.bodyType == .file })
        XCTAssertEqual(file.bodyFileName, "photo.png")
        XCTAssertNil(file.bodyFile)
        XCTAssertNil(file.bodyFileSize)
        XCTAssertTrue(file.lacksBodyFile, "The file is chosen again after an import")
        let json = try XCTUnwrap(copies.first { $0.bodyType == .json })
        XCTAssertNil(json.bodyFileName, "A file kept behind another body type isn't exported, not even its name")
        XCTAssertNil(json.bodyFile)
    }

    func testAttachingAFileSetsItsBytesNameAndSizeTogether() {
        let request = APIRequest(name: "r", method: .post)
        request.attachFile(binary, name: "photo.png")
        XCTAssertEqual(request.bodyFile, binary)
        XCTAssertEqual(request.bodyFileName, "photo.png")
        XCTAssertEqual(request.bodyFileSize, binary.count)
        request.attachFile(nil, name: "ignored")
        XCTAssertNil(request.bodyFile)
        XCTAssertNil(request.bodyFileName)
        XCTAssertNil(request.bodyFileSize)
    }

    func testTheFileSurvivesSavingAndReopeningAStoreOnDisk() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.store")
        let big = Data((0..<300_000).map { UInt8($0 % 251) })  // Large enough for external storage to keep it beside the store.
        var id: UUID?
        do {
            let container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(url: url))
            let request = fileRequest(big)
            id = request.id
            container.mainContext.insert(request)
            try container.mainContext.save()
        }
        let reopened = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(url: url))
        let request = try XCTUnwrap(try reopened.mainContext.fetch(FetchDescriptor<APIRequest>()).first { $0.id == id })
        XCTAssertEqual(request.bodyFile, big)
        XCTAssertEqual(request.bodyFileName, "photo.png")
        XCTAssertEqual(request.bodyFileSize, big.count)
        XCTAssertEqual(request.bodyType, .file)
    }

    // MARK: Other apps' binary bodies

    func testPostmanAndInsomniaBinaryBodiesBecomeFileBodiesWithoutTheirFiles() throws {
        let postman = #"""
            {"info": {"name": "P", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},
             "item": [{"name": "Upload", "request": {"method": "POST", "url": "https://h/upload", "body": {"mode": "file", "file": {"src": "/Users/ada/Pictures/cat.png"}}}}]}
            """#
        let file = try CollectionImport.read(Data(postman.utf8), fileName: "p.json")
        let request = try XCTUnwrap(file.collections.first?.requests.first)
        XCTAssertEqual(request.bodyType, .file)
        XCTAssertEqual(request.bodyFileName, "cat.png")
        XCTAssertTrue(file.notes.contains(ImportSupport.binaryBodyNote))

        let insomnia = #"""
            {"_type": "export", "__export_format": 4, "resources": [
              {"_id": "wrk_1", "_type": "workspace", "name": "I"},
              {"_id": "req_1", "_type": "request", "parentId": "wrk_1", "name": "Upload", "method": "PUT", "url": "https://h/u",
               "body": {"mimeType": "application/octet-stream", "fileName": "C:\\Users\\ada\\data.bin"}}]}
            """#
        let imported = try CollectionImport.read(Data(insomnia.utf8), fileName: "i.json")
        let insomniaRequest = try XCTUnwrap(imported.collections.first?.requests.first)
        XCTAssertEqual(insomniaRequest.bodyType, .file)
        XCTAssertEqual(insomniaRequest.bodyFileName, "data.bin", "A Windows path's file name")
        XCTAssertTrue(imported.notes.contains(ImportSupport.binaryBodyNote))
    }

    func testABinaryBodyWithoutAPathHasNoFileName() {
        XCTAssertNil(ImportSupport.fileName(fromPath: nil))
        XCTAssertNil(ImportSupport.fileName(fromPath: ""))
        XCTAssertNil(ImportSupport.fileName(fromPath: "/"))
        XCTAssertEqual(ImportSupport.fileName(fromPath: "a/b/c.txt"), "c.txt")
    }
}

// MARK: - Sending: the app, MCP tools

@MainActor
final class FileBodySendingTests: XCTestCase {
    private var target: MCPListener!
    private var port: UInt16 = 0
    private var container: ModelContainer!

    override func setUp() async throws {
        (target, port) = try echoServer()
        container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() async throws {
        target.stop()
        container = nil
    }

    private var client: HTTPClient { HTTPClient(session: URLSession(configuration: .ephemeral)) }
    private var url: String { "http://127.0.0.1:\(port)/upload" }

    func testTheFileIsSentByteForByteWithTheTypeItsNameGives() async throws {
        let response = try await client.execute(request: RequestSnapshot(fileRequest(url: url)))
        let sent = try echoed(response.body)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.body, binary)
        XCTAssertEqual(sent.contentType, "image/png")
    }

    func testTheRequestsOwnContentTypeWins() async throws {
        let request = fileRequest(url: url)
        request.headers = [KeyValuePair(key: "Content-Type", value: "application/vnd.custom")]
        let sent = try echoed(try await client.execute(request: RequestSnapshot(request)).body)
        XCTAssertEqual(sent.contentType, "application/vnd.custom")
        XCTAssertEqual(sent.body, binary)
    }

    func testAnUnknownFileTypeIsSentAsOctetStream() async throws {
        let sent = try echoed(try await client.execute(request: RequestSnapshot(fileRequest(Data("raw".utf8), name: "blob", method: .put, url: url))).body)
        XCTAssertEqual(sent.method, "PUT")
        XCTAssertEqual(sent.contentType, "application/octet-stream")
        XCTAssertEqual(sent.body, Data("raw".utf8))
    }

    func testAFileBodyWithoutItsFileFailsInsteadOfSendingNothing() async throws {
        do {
            _ = try await client.execute(request: RequestSnapshot(fileRequest(nil, name: "photo.png", url: url)))
            XCTFail("Sent without its file")
        } catch {
            XCTAssertEqual(error.localizedDescription, "“photo.png” isn't attached: Reqs has only its name (History and imports keep no file). Choose the file again in the Body tab.")
        }
        do {
            _ = try await client.execute(request: RequestSnapshot(fileRequest(nil, name: nil, url: url)))
            XCTFail("Sent without a file")
        } catch {
            XCTAssertEqual(error.localizedDescription, "No file to send. Choose one in the Body tab, or pick another body type.")
        }
        let get = try await client.execute(request: RequestSnapshot(fileRequest(nil, method: .get, url: url)))
        XCTAssertEqual(try echoed(get.body).body, Data(), "A GET sends no body, so it doesn't need the file")
    }

    // MARK: MCP

    private func call(_ name: String, _ arguments: [String: Reqs.JSONValue]) async throws -> Reqs.JSONValue {
        switch await MCPToolHandler(container: container).call(name, arguments) {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    private func failure(_ name: String, _ arguments: [String: Reqs.JSONValue]) async -> MCPToolError? {
        if case .failure(let error) = await MCPToolHandler(container: container).call(name, arguments) { return error }
        return nil
    }

    private let upload: Reqs.JSONValue = .object(["name": .string("photo.png"), "base64": .string(binary.base64EncodedString())])

    func testAnAgentAttachesAFileAndReadsItsDetailsButNeverItsBytes() async throws {
        let created = try await call("request_create", ["url": .string(url), "method": .string("POST"), "bodyFile": upload])
        let id = try XCTUnwrap(UUID(uuidString: created["id"]?.stringValue ?? ""))
        let request = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<APIRequest>()).first { $0.id == id })
        XCTAssertEqual(request.bodyType, .file, "bodyFile sets the type")
        XCTAssertEqual(request.bodyFile, binary)
        XCTAssertEqual(request.bodyFileName, "photo.png")
        XCTAssertEqual(request.bodyFileSize, binary.count)
        XCTAssertEqual(
            created["bodyFile"],
            .object(["name": .string("photo.png"), "attached": .bool(true), "size": .number(Double(binary.count)), "contentType": .string("image/png")]))
        XCTAssertEqual(created["bodyType"], .string("file"))
        XCTAssertFalse(created.text.contains(binary.base64EncodedString()), "Reads never return the bytes")

        let typed = try await call("request_update", ["id": .string(id.uuidString), "bodyFile": upload, "bodyType": .string("json")])
        XCTAssertEqual(typed["bodyType"], .string("json"), "An explicit bodyType wins")

        let plain = try await call("request_create", ["url": .string(url)])
        XCTAssertEqual(plain["bodyFile"], .null)
    }

    func testAnAgentsFileNameKeepsOnlyItsLastComponent() async throws {
        let created = try await call("request_create", ["url": .string(url), "bodyFile": .object(["name": .string("../../secret/key.pem"), "base64": .string("AA==")])])
        XCTAssertEqual(created["bodyFile"]?["name"], .string("key.pem"))
        for name in ["/", "..", "a/."] {
            let refused = await failure("request_create", ["url": .string(url), "bodyFile": .object(["name": .string(name), "base64": .string("AA==")])])
            XCTAssertEqual(refused?.code, "INVALID_PARAMS", name)
        }
    }

    func testABadFileIsRefusedAndChangesNothing() async throws {
        let created = try await call("request_create", ["url": .string(url), "bodyFile": upload])
        let id = created["id"] ?? .null
        let notBase64 = await failure("request_update", ["id": id, "bodyFile": .object(["name": .string("a.txt"), "base64": .string("not base64!")])])
        XCTAssertEqual(notBase64?.code, "INVALID_PARAMS")
        let tooBig = Data(count: MCPTools.maximumBodyFileBytes + 1).base64EncodedString()
        let large = await failure("request_update", ["id": id, "bodyFile": .object(["name": .string("a.bin"), "base64": .string(tooBig)])])
        XCTAssertEqual(large?.code, "INVALID_PARAMS")
        XCTAssertTrue(large?.message.contains("Choose larger files in the app") == true, large?.message ?? "")
        let noName = await failure("request_update", ["id": id, "bodyFile": .object(["base64": .string("AA==")])])
        XCTAssertEqual(noName?.code, "INVALID_PARAMS")
        let after = try await call("request_get", ["id": id])
        XCTAssertEqual(after["bodyFile"]?["name"], .string("photo.png"), "The saved file is kept")
        XCTAssertEqual(after["bodyFile"]?["size"], .number(Double(binary.count)))
    }

    func testRequestExecuteSendsTheFileAndHistoryKeepsOnlyItsName() async throws {
        let result = try await call("request_execute", ["request": .object(["url": .string(url), "method": .string("POST"), "bodyFile": upload])])
        let sent = try echoed(result["response"]?["body"]?.stringValue)
        XCTAssertEqual(sent.body, binary)
        XCTAssertEqual(sent.contentType, "image/png")

        let entry = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<RequestHistory>()).first)
        XCTAssertNil(entry.requestBody)
        XCTAssertEqual(entry.requestBodyFileName, "photo.png")
        let read = try await call("history_get", ["id": .string(entry.id.uuidString)])
        XCTAssertEqual(read["request"]?["bodyFile"], .object(["name": .string("photo.png"), "size": .number(Double(binary.count))]))
        XCTAssertFalse(try XCTUnwrap(read["request"]).text.contains(binary.base64EncodedString()), "The recorded request has no bytes (the echoed response does)")
    }

    func testHistoryToolsTakeNoFileBytes() async throws {
        XCTAssertNil(MCPTools.historyRequestFields["bodyFile"])
        let refused = await failure("history_create", ["url": .string(url), "bodyFile": upload])
        XCTAssertEqual(refused?.code, "INVALID_PARAMS")
        let entry = try await call("history_create", ["url": .string(url), "bodyType": .string("file"), "body": .string("hidden text")])
        XCTAssertEqual(entry["request"]?["body"], .null, "A File entry keeps no body text")
    }

    func testTheLargestAgentFileFitsInOneMCPCall() {
        let base64 = (MCPTools.maximumBodyFileBytes + 2) / 3 * 4
        XCTAssertLessThan(base64 + 16_384, MCPHTTPRequestParser.maximumBody, "Room for the base64 and the rest of the call")
    }
}

private extension Reqs.JSONValue {
    var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }
}
