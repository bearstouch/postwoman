import XCTest

@testable import PostWoman

final class AppVersionTests: XCTestCase {
    func testReleaseVersionMatchesManifest() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("release/manifest.json"))) as? [String: Any]
        XCTAssertEqual(manifest?["version"] as? String, AppVersion.release, "Bump AppVersion.release with release/manifest.json")
    }
}
