import AppKit
import XCTest

@testable import Reqs

/// The repository root, from this file's path.
private let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func repositoryFile(_ path: String) throws -> Data { try Data(contentsOf: repositoryRoot.appendingPathComponent(path)) }

private func manifest() throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: repositoryFile("release/manifest.json")) as? [String: Any])
}

final class AppVersionSchemeTests: XCTestCase {
    /// `scripts/package-release.sh` accepts `X.Y.Z` or `X.Y.Z-alpha|beta|rc.N` with N < 30, so pre-release build numbers stay ordered.
    func testReleaseVersionIsOneThePackagingScriptAccepts() throws {
        let pattern = try NSRegularExpression(pattern: #"^(\d+)\.(\d+)\.(\d+)(?:-(alpha|beta|rc)\.([1-9]\d?))?$"#)
        let version = AppVersion.release
        let match = try XCTUnwrap(pattern.firstMatch(in: version, range: NSRange(version.startIndex..., in: version)), version)
        let label = match.range(at: 5)
        if label.location != NSNotFound {
            XCTAssertLessThan(Int((version as NSString).substring(with: label)) ?? 99, 30)
        }
        XCTAssertEqual(AppVersion.isPrerelease(version), match.range(at: 4).location != NSNotFound)
    }

    func testChangelogHasASectionForTheRelease() throws {
        let changelog = try XCTUnwrap(String(data: repositoryFile("CHANGELOG.md"), encoding: .utf8))
        XCTAssertTrue(changelog.contains("\n## [\(AppVersion.release)]"), "CHANGELOG.md becomes the release notes")
    }

    func testBundleIdentifierIsTheOneThatOwnsUsersData() throws {
        XCTAssertEqual(try manifest()["bundleIdentifier"] as? String, "com.bearstouch.reqs", "changing it orphans the sandbox container")
    }

    func testMinimumMacOSMatchesThePackage() throws {
        let minimum = try XCTUnwrap(manifest()["minimumMacOS"] as? String)
        let major = try XCTUnwrap(minimum.split(separator: ".").first)
        let package = try XCTUnwrap(String(data: repositoryFile("Package.swift"), encoding: .utf8))
        XCTAssertTrue(package.contains(".macOS(.v\(major))"), "Package.swift platform vs manifest \(minimum)")
    }

    func testReleaseIsUniversal() throws {
        XCTAssertEqual(Set(try XCTUnwrap(manifest()["architectures"] as? [String])), ["arm64", "x86_64"])
    }

    func testSparklePublicKeyIsAnEd25519Key() throws {
        let key = try XCTUnwrap(manifest()["sparklePublicKey"] as? String)
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32)
        XCTAssertNotNil(UpdateFeed(info: ["SUFeedURL": "https://raw.githubusercontent.com/bearstouch/reqs/appcast/appcast.xml", "SUPublicEDKey": key]))
    }

    func testSparkleDependencyMatchesTheResolvedPackage() throws {
        let dependencies = try XCTUnwrap(manifest()["dependencies"] as? [[String: Any]])
        let sparkle = try XCTUnwrap(dependencies.first { $0["name"] as? String == "Sparkle" })
        let resolved = try XCTUnwrap(JSONSerialization.jsonObject(with: repositoryFile("Package.resolved")) as? [String: Any])
        let pins = try XCTUnwrap(resolved["pins"] as? [[String: Any]])
        let pin = try XCTUnwrap(pins.first { ($0["identity"] as? String) == "sparkle" })
        let state = try XCTUnwrap(pin["state"] as? [String: Any])
        XCTAssertEqual(sparkle["version"] as? String, state["version"] as? String)
        XCTAssertEqual(sparkle["revision"] as? String, state["revision"] as? String)
        let license = try XCTUnwrap(sparkle["licenseFile"] as? String)
        XCTAssertFalse(try repositoryFile(license).isEmpty, "\(license) ships in the app")
    }

    func testEntitlementsSandboxTheAppAndAllowSparklesInstaller() throws {
        let path = try XCTUnwrap(manifest()["entitlements"] as? String)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: repositoryFile(path), format: nil) as? [String: Any])
        XCTAssertEqual(plist["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(plist["com.apple.security.network.client"] as? Bool, true)
        XCTAssertEqual(plist["com.apple.security.network.server"] as? Bool, true, "the Remote Agent listens")
        let bundleID = try XCTUnwrap(manifest()["bundleIdentifier"] as? String)
        let machLookup = plist["com.apple.security.temporary-exception.mach-lookup.global-name"] as? [String]
        XCTAssertEqual(Set(machLookup ?? []), ["\(bundleID)-spks", "\(bundleID)-spki"])
    }
}

final class AboutPanelCreditsTests: XCTestCase {
    func testCreditsAreCenteredInTheSystemFont() throws {
        let credits = AboutPanel.credits()
        let full = NSRange(location: 0, length: credits.length)
        var range = NSRange()
        let style = try XCTUnwrap(credits.attribute(.paragraphStyle, at: 0, longestEffectiveRange: &range, in: full) as? NSParagraphStyle)
        XCTAssertEqual(style.alignment, .center)
        XCTAssertEqual(range, full)
        let font = try XCTUnwrap(credits.attribute(.font, at: 0, longestEffectiveRange: &range, in: full) as? NSFont)
        XCTAssertEqual(font.pointSize, 12)
        XCTAssertEqual(range, full)
    }

    func testOnlyTheLicenseAndOwnerAreLinked() {
        let credits = AboutPanel.credits()
        let text = credits.string as NSString
        var linked: [String] = []
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, range, _ in
            if value != nil { linked.append(text.substring(with: range)) }
        }
        XCTAssertEqual(linked, ["MIT License", "bearstouch"])
    }

    func testCreditLinksAreHTTPSOnGitHub() {
        for url in [AboutPanel.licenseURL, AboutPanel.ownerURL] {
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "github.com")
        }
        XCTAssertTrue(AboutPanel.licenseURL.path.hasSuffix("/LICENSE"))
    }

    func testCreditsNameTheLicenseThatShipsWithTheCode() throws {
        let license = try XCTUnwrap(String(data: repositoryFile("LICENSE"), encoding: .utf8))
        XCTAssertTrue(license.contains("MIT License"))
        XCTAssertTrue(AboutPanel.credits().string.contains("MIT License"))
    }
}
