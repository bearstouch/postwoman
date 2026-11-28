import XCTest

@testable import Reqs

/// Sends through a real URLSession to a listener on a loopback port: what URLSession itself refuses or changes never
/// reaches a `URLProtocol` stub.
@MainActor
final class HTTPClientLiveServerTests: XCTestCase {
    private var listener: MCPListener!
    private var port: UInt16 = 0

    override func setUp() async throws {
        listener = MCPListener { request in
            let echoed = JSONValue.object([
                "method": .string(request.method), "headers": .object(request.headers.mapValues(JSONValue.string)),
                "body": .string(String(decoding: request.body, as: UTF8.self))
            ])
            return .json(200, echoed.data)
        }
        port = try listener.start(address: "127.0.0.1", port: 0)
    }

    override func tearDown() async throws {
        listener.stop()
        listener = nil
    }

    private func echo(_ request: APIRequest) async throws -> JSONValue {
        let response = try await HTTPClient(session: URLSession(configuration: .ephemeral)).execute(request: RequestSnapshot(request))
        XCTAssertEqual(response.statusCode, 200)
        return try JSONDecoder().decode(JSONValue.self, from: Data((response.body ?? "").utf8))
    }

    /// URLSession fails a GET that has a body before sending it ("resource exceeds maximum size").
    func testAGetWithABodyTypedForAnotherMethodIsStillSent() async throws {
        let request = APIRequest(name: "g", url: "http://127.0.0.1:\(port)/items", method: .get)
        request.bodyType = .json
        request.bodyContent = #"{"a":1}"#
        let received = try await echo(request)
        XCTAssertEqual(received["method"], .string("GET"))
        XCTAssertEqual(received["body"], .string(""), "The body stays on the request and isn't sent")
        XCTAssertNil(received["headers"]?["content-type"] ?? received["headers"]?["Content-Type"])
    }

    func testOtherMethodsSendTheirBody() async throws {
        for method in HTTPMethod.allCases where method.sendsBody {
            let request = APIRequest(name: "b", url: "http://127.0.0.1:\(port)/items", method: method)
            request.bodyType = .json
            request.bodyContent = #"{"a":1}"#
            let received = try await echo(request)
            XCTAssertEqual(received["method"], .string(method.rawValue))
            XCTAssertEqual(received["body"], .string(#"{"a":1}"#), method.rawValue)
        }
    }
}
