import AppKit
import SwiftUI
import XCTest

@testable import PostWoman

@MainActor
private final class FakeUpdater: SoftwareUpdater {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = false
    var includesBetas = false
    var lastUpdateCheckDate: Date?
    var onChange: (() -> Void)?
    var checks = 0
    func checkForUpdates() {
        checks += 1
        canCheckForUpdates = false
    }
}

final class SoftwareUpdateTests: XCTestCase {
    private let key = Data(repeating: 1, count: 32).base64EncodedString()

    func testFeedNeedsHTTPSURLAndPublicKey() {
        let url = "https://raw.githubusercontent.com/bearstouch/postwoman/appcast/appcast.xml"
        XCTAssertEqual(UpdateFeed(info: ["SUFeedURL": url, "SUPublicEDKey": key])?.url.absoluteString, url)
        XCTAssertNil(UpdateFeed(info: [:]), "SwiftPM and development builds have no updater")
        XCTAssertNil(UpdateFeed(info: ["SUFeedURL": url]), "A feed without a key could never verify an update")
        XCTAssertNil(UpdateFeed(info: ["SUFeedURL": url, "SUPublicEDKey": "  "]))
        XCTAssertNil(UpdateFeed(info: ["SUFeedURL": "http://example.com/appcast.xml", "SUPublicEDKey": key]), "Plain HTTP is loopback-only")
        XCTAssertNil(UpdateFeed(info: ["SUFeedURL": "file:///tmp/appcast.xml", "SUPublicEDKey": key]))
        XCTAssertNotNil(UpdateFeed(info: ["SUFeedURL": "http://127.0.0.1:8000/appcast.xml", "SUPublicEDKey": key]), "Local end-to-end testing")
    }

    @MainActor
    func testUnbundledRunsHaveNoUpdater() {
        XCTAssertNil(SparkleUpdater(), "The test runner's bundle has no feed, so nothing contacts the network")
    }

    func testBetaChannelFollowsTheBuildUntilChosen() throws {
        let suite = "postwoman-updates-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(AppVersion.isPrerelease("1.0.0-beta.2"))
        XCTAssertFalse(AppVersion.isPrerelease("1.0.0"))
        let stable = UpdatePreferences(defaults: defaults, version: "1.0.0")
        XCTAssertFalse(stable.includeBetas)
        XCTAssertEqual(stable.allowedChannels, [], "Stable builds see only channel-less items")
        let beta = UpdatePreferences(defaults: defaults, version: "1.1.0-beta.1")
        XCTAssertTrue(beta.includeBetas, "A pre-release keeps receiving pre-releases by default")
        XCTAssertEqual(beta.allowedChannels, [UpdateFeed.betaChannel])
        beta.includeBetas = false
        XCTAssertFalse(UpdatePreferences(defaults: defaults, version: "1.1.0-beta.1").includeBetas, "An explicit choice wins over the default")
        stable.includeBetas = true
        XCTAssertEqual(UpdatePreferences(defaults: defaults, version: "1.0.0").allowedChannels, ["beta"])
    }

    @MainActor
    func testSettingsDriveTheUpdater() {
        let updater = FakeUpdater()
        let model = UpdateSettingsModel(updater: updater, version: "1.0.0-beta.2")
        XCTAssertEqual(model.version, "1.0.0-beta.2")
        XCTAssertFalse(model.automaticChecks, "Automatic checks start off")
        XCTAssertNil(model.lastCheck)
        model.setAutomaticChecks(true)
        XCTAssertTrue(updater.automaticallyChecksForUpdates)
        XCTAssertTrue(model.automaticChecks)
        model.setIncludeBetas(true)
        XCTAssertTrue(updater.includesBetas)
        XCTAssertTrue(model.includeBetas)
        XCTAssertEqual(updater.checks, 0, "Changing settings never checks by itself")
    }

    @MainActor
    func testCheckNowRunsOnceWhileACheckIsInProgress() {
        let updater = FakeUpdater()
        let model = UpdateSettingsModel(updater: updater)
        model.checkNow()
        XCTAssertEqual(updater.checks, 1)
        XCTAssertFalse(model.canCheck, "Check Now is disabled while Sparkle is busy")
        model.checkNow()
        XCTAssertEqual(updater.checks, 1)
        let finished = Date(timeIntervalSince1970: 1_800_000_000)
        updater.canCheckForUpdates = true
        updater.lastUpdateCheckDate = finished
        updater.onChange?()
        XCTAssertTrue(model.canCheck)
        XCTAssertEqual(model.lastCheck, finished)
    }

    @MainActor
    func testUpdatesPaneRenders() {
        _ = NSApplication.shared
        let pane = NSHostingView(rootView: UpdateSettingsView(updates: UpdateSettingsModel(updater: FakeUpdater())))
        pane.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        pane.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(pane.fittingSize.height, 0)
    }
}
