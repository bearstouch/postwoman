import Foundation
import XCTest

@testable import Reqs
@testable import ReqsCLI

private let bytes = Data([0x00, 0xFF, 0x0D, 0x0A, 0x41, 0x0A, 0x00, 0x80])

private func upload(name: String = "photo.png", url: String) -> APIRequest {
    let request = APIRequest(name: "Upload", url: url, method: .post)
    request.bodyType = .file
    request.bodyFile = bytes
    request.bodyFileName = name
    request.bodyFileSize = bytes.count
    return request
}

/// Runs `executable` with `arguments` in `directory`, feeding `input`; returns stdout, or nil when it failed.
private func runProcess(_ executable: String, _ arguments: [String], in directory: URL, input: Data = Data()) throws -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let stdin = Pipe(), stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = Pipe()
    try process.run()
    stdin.fileHandleForWriting.write(input)
    try stdin.fileHandleForWriting.close()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? data : nil
}

/// A directory holding the file the generated code reads, removed afterwards.
private func directory(with name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FileBodyCode-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try bytes.write(to: directory.appendingPathComponent(name))
    return directory
}

@MainActor
final class FileBodyGeneratedCodeTests: XCTestCase {
    func testCURLUploadsTheFileWithItsContentType() throws {
        let listener = MCPListener { request in
            .json(200, Data(#"{"type":"\#(request.header("content-type") ?? "")","body":"\#(request.body.base64EncodedString())"}"#.utf8))
        }
        let port = try listener.start(address: "127.0.0.1", port: 0)
        defer { listener.stop() }
        let folder = try directory(with: "photo.png")
        defer { try? FileManager.default.removeItem(at: folder) }

        let command = CURLGenerator().generate(from: upload(url: "http://127.0.0.1:\(port)/u"))
        XCTAssertTrue(command.contains("--data-binary @'photo.png'"), command)
        let output = try XCTUnwrap(try runProcess("/bin/sh", ["-c", command + " -s"], in: folder), command)
        let echoed = try XCTUnwrap(try JSONSerialization.jsonObject(with: output) as? [String: String])
        XCTAssertEqual(echoed["type"], "image/png")
        XCTAssertEqual(echoed["body"], bytes.base64EncodedString(), "curl sent the file byte for byte")
    }

    func testCURLKeepsTheRequestsContentTypeAndReadsADashNameAsAFile() {
        let request = upload(name: "-", url: "https://h/u")
        request.headers = [KeyValuePair(key: "Content-Type", value: "application/vnd.custom")]
        let command = CURLGenerator().generate(from: request)
        XCTAssertTrue(command.contains("--data-binary @'./-'"), command)
        XCTAssertFalse(command.contains("application/octet-stream"), command)
        XCTAssertTrue(command.contains("-H 'Content-Type: application/vnd.custom'"), command)
    }

    func testPythonReadsTheFileAndSendsItsBytes() throws {
        let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let python else { throw XCTSkip("python3 not found") }
        let folder = try directory(with: "photo.png")
        defer { try? FileManager.default.removeItem(at: folder) }
        let stub = """
            import json, sys, types, builtins
            captured = {}
            def call(method):
                def f(url, **kw):
                    captured.update({k: (v.hex() if isinstance(v, bytes) else v) for k, v in kw.items()}, method=method)
                    return types.SimpleNamespace(status_code=200, headers={}, text="")
                return f
            sys.modules["requests"] = types.SimpleNamespace(**{m: call(m) for m in ["get", "post", "put", "patch", "delete", "head", "options"]})
            builtins.print = lambda *a, **k: None
            exec(compile(sys.stdin.read(), "generated.py", "exec"))
            sys.stdout.write(json.dumps(captured))
            """
        let code = PythonGenerator().generate(from: upload(url: "https://h/u"))
        let output = try XCTUnwrap(try runProcess(python, ["-I", "-W", "error", "-c", stub], in: folder, input: Data(code.utf8)), code)
        let captured = try XCTUnwrap(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        XCTAssertEqual(captured["data"] as? String, bytes.map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual((captured["headers"] as? [String: String])?["Content-Type"], "image/png")
        XCTAssertEqual(captured["method"] as? String, "post")
    }

    func testSwiftReadsTheFileAndSendsItsBytes() throws {
        let folder = try directory(with: "photo.png")
        defer { try? FileManager.default.removeItem(at: folder) }
        // Answers the generated request offline: prints the body (base64) and Content-Type, and exits.
        let harness = #"""
            import Foundation
            final class Capture: URLProtocol {
                override class func canInit(with request: URLRequest) -> Bool { true }
                override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
                override func startLoading() {
                    var body = request.httpBody ?? Data()
                    if body.isEmpty, let stream = request.httpBodyStream {
                        stream.open()
                        var buffer = [UInt8](repeating: 0, count: 4096)
                        while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 { body.append(buffer, count: count) }
                    }
                    print(body.base64EncodedString() + " " + (request.value(forHTTPHeaderField: "Content-Type") ?? ""))
                    exit(0)
                }
                override func stopLoading() {}
            }
            URLProtocol.registerClass(Capture.self)

            """#
        let code = SwiftGenerator().generate(from: upload(url: "https://h/u"))
        XCTAssertTrue(code.contains(#"request.httpBody = FileManager.default.contents(atPath: "photo.png")"#), code)
        let source = folder.appendingPathComponent("main.swift")
        try (harness + code).write(to: source, atomically: true, encoding: .utf8)
        let binary = folder.appendingPathComponent("generated").path
        guard try runProcess("/usr/bin/xcrun", ["swiftc", "-swift-version", "5", "-o", binary, source.path], in: folder) != nil else { return XCTFail("Doesn't compile:\n\(code)") }
        let output = String(decoding: try XCTUnwrap(try runProcess(binary, [], in: folder)), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(output, bytes.base64EncodedString() + " image/png")
    }

    func testCodeReadsTheFileByNameEvenWhenOnlyTheNameIsLeft() {
        let request = upload(url: "https://h/u")
        request.bodyFile = nil
        request.bodyFileSize = nil
        XCTAssertTrue(CURLGenerator().generate(from: request).contains("--data-binary @'photo.png'"))
        XCTAssertTrue(PythonGenerator().generate(from: request).contains(#"with open("photo.png", "rb") as file:"#))
        XCTAssertTrue(SwiftGenerator().generate(from: request).contains(#"FileManager.default.contents(atPath: "photo.png")"#))
        request.bodyFileName = nil
        XCTAssertFalse(CURLGenerator().generate(from: request).contains("--data-binary"), "No file and no name: nothing to read")
        XCTAssertFalse(PythonGenerator().generate(from: request).contains("open("))
        XCTAssertFalse(SwiftGenerator().generate(from: request).contains("httpBody"))
        request.bodyFileName = "photo.png"
        request.method = .get
        XCTAssertFalse(CURLGenerator().generate(from: request).contains("--data-binary"), "GET sends no body")
    }
}

// MARK: - CLI

final class FileBodyCLITests: XCTestCase {
    private let input = CLIInput(
        readFile: { path in
            switch path {
            case "/tmp/photo.png": return bytes
            case "/tmp/big.bin": return Data(count: CLICommands.maximumUploadBytes + 1)
            default: throw CocoaError(.fileNoSuchFile)
            }
        }, readStdin: { Data() },
        fileSize: { path in
            switch path {
            case "/tmp/photo.png": return bytes.count
            case "/tmp/huge.iso": return 4_000_000_000
            case "/dev/zero": return -1
            default: return nil
            }
        })

    private func built(_ words: [String], nest: Bool = false) throws -> [String: ReqsCLI.JSONValue] {
        guard case .run(_, let arguments, _, _) = try CLIArguments.parse(words, input: input) else { throw CLIFailure.arguments("not a run") }
        return arguments.merged(nestFields: nest)
    }

    private func message(_ words: [String]) -> String? {
        do {
            _ = try CLIArguments.parse(words, input: input)
            return nil
        } catch { return error.message }
    }

    func testUploadSendsTheFileNamedByItsLastPathComponent() throws {
        let expected = ReqsCLI.JSONValue.object(["name": .string("photo.png"), "base64": .string(bytes.base64EncodedString())])
        XCTAssertEqual(try built(["request", "create", "--upload", "/tmp/photo.png"])["bodyFile"], expected)
        XCTAssertEqual(try built(["request", "update", "--id", "R", "--upload", "/tmp/photo.png"])["bodyFile"], expected)
        XCTAssertEqual(try built(["request", "execute", "--url", "https://h", "--upload", "/tmp/photo.png"], nest: true)["request"]?["bodyFile"], expected)
        XCTAssertEqual(try built(["request", "create", "--body-type", "file"])["bodyType"], .string("file"))
    }

    func testUploadRefusesAMissingOrTooLargeFile() {
        XCTAssertEqual(message(["request", "create", "--upload", "/tmp/nope"]), "Can't read /tmp/nope.")
        XCTAssertEqual(
            message(["request", "create", "--upload", "/tmp/big.bin"]),
            "/tmp/big.bin is \(CLICommands.maximumUploadBytes + 1) bytes; --upload sends at most \(CLICommands.maximumUploadBytes). Choose larger files in the app.")
    }

    func testUploadChecksTheSizeBeforeReading() {
        // /tmp/huge.iso and /dev/zero can't be read (readFile throws): refusing them proves the size was checked first.
        XCTAssertEqual(
            message(["request", "create", "--upload", "/tmp/huge.iso"]),
            "/tmp/huge.iso is 4000000000 bytes; --upload sends at most \(CLICommands.maximumUploadBytes). Choose larger files in the app.")
        XCTAssertEqual(message(["request", "create", "--upload", "/dev/zero"]), "/dev/zero isn't a regular file.")
    }

    func testTheLiveEnvironmentToldTheSizeOfAFileAndADevice() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("FileBodyCLI-\(UUID().uuidString)").path
        try bytes.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertEqual(CLIEnvironment.live.fileSize(path), bytes.count)
        XCTAssertEqual(CLIEnvironment.live.fileSize("/dev/zero"), -1)
        XCTAssertEqual(CLIEnvironment.live.fileSize(FileManager.default.temporaryDirectory.path), -1, "A folder isn't a file")
        XCTAssertNil(CLIEnvironment.live.fileSize(path + ".missing"))
        let link = path + ".link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        defer { try? FileManager.default.removeItem(atPath: link) }
        XCTAssertEqual(CLIEnvironment.live.fileSize(link), bytes.count, "A symlink to a file is that file")
    }

    func testHistoryCommandsTakeNoUpload() {
        for verb in ["create", "update"] {
            let command = CLICommands.command("history", verb)
            XCTAssertNotNil(command)
            XCTAssertFalse(command?.flags.contains { $0.name == "upload" } ?? true, verb)
        }
    }

    func testTheCLIUploadLimitIsTheAppsAgentFileLimit() {
        XCTAssertEqual(CLICommands.maximumUploadBytes, MCPTools.maximumBodyFileBytes)
        XCTAssertEqual(CLICommands.bodyTypes, MCPTools.bodyTypes)
    }
}

private extension ReqsCLI.JSONValue {
    subscript(key: String) -> ReqsCLI.JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }
}
