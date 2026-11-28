import XCTest

@testable import Reqs
import ReqsCLI

final class AppVersionTests: XCTestCase {
    func testReleaseVersionMatchesManifest() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("release/manifest.json"))) as? [String: Any]
        XCTAssertEqual(manifest?["version"] as? String, AppVersion.release, "Bump AppVersion.release with release/manifest.json")
        XCTAssertEqual(CLI.version, AppVersion.release, "Bump CLI.version with AppVersion.release")
    }

    func testTheFullVersionIsReadFromTheBundleWithTheKeyFromBeforeTheRenameAsAFallback() {
        XCTAssertEqual(AppVersion.version(in: ["ReqsVersion": "1.0.0-beta.2", "PostWomanVersion": "0.9.0", "CFBundleShortVersionString": "1.0.0"]), "1.0.0-beta.2")
        XCTAssertEqual(AppVersion.version(in: ["PostWomanVersion": "0.11.0-rc.1", "CFBundleShortVersionString": "0.11.0"]), "0.11.0-rc.1")
        XCTAssertEqual(AppVersion.version(in: ["CFBundleShortVersionString": "0.11.0"]), "0.11.0")
        XCTAssertNil(AppVersion.version(in: [:]))
        XCTAssertNil(AppVersion.version(in: nil))
    }
}
