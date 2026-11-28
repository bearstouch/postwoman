import Foundation
import XCTest

@testable import Reqs

/// A stand-in for Sparkle that records what the settings model asks of it.
@MainActor
private final class RecordingUpdater: SoftwareUpdater {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = false
    var includesBetas = false
    var lastUpdateCheckDate: Date?
    var onChange: (() -> Void)?
    private(set) var checks = 0

    func checkForUpdates() { checks += 1 }
}

final class UpdateSettingsTests: XCTestCase {
    private let key = Data(repeating: 7, count: 32).base64EncodedString()

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "UpdateSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    // MARK: Feed

    func testHTTPSFeedKeepsPathPortAndQuery() throws {
        let raw = "https://updates.example.com:8443/reqs/appcast.xml?channel=all"
        let feed = try XCTUnwrap(UpdateFeed(info: ["SUFeedURL": raw, "SUPublicEDKey": key]))
        XCTAssertEqual(feed.url.absoluteString, raw)
        XCTAssertEqual(feed.publicKey, key)
    }

    func testPlainHTTPIsAllowedOnlyForExactLoopbackHosts() {
        XCTAssertNotNil(UpdateFeed(info: ["SUFeedURL": "http://localhost:8000/appcast.xml", "SUPublicEDKey": key]))
        XCTAssertNotNil(UpdateFeed(info: ["SUFeedURL": "http://127.0.0.1/appcast.xml", "SUPublicEDKey": key]))
        for raw in ["http://localhost.example.com/appcast.xml", "http://127.0.0.1.nip.io/appcast.xml", "http://10.0.0.1/appcast.xml", "http://evil.com/?h=localhost"] {
            XCTAssertNil(UpdateFeed(info: ["SUFeedURL": raw, "SUPublicEDKey": key]), raw)
        }
    }

    func testFeedWithoutAHostOrWithAnotherSchemeIsRefused() {
        for raw in ["https:///appcast.xml", "https://", "appcast.xml", "ftp://example.com/appcast.xml", "", "not a url"] {
            XCTAssertNil(UpdateFeed(info: ["SUFeedURL": raw, "SUPublicEDKey": key]), raw)
        }
    }

    func testFeedValuesMustBeStrings() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/appcast.xml"))
        XCTAssertNil(UpdateFeed(info: ["SUFeedURL": url, "SUPublicEDKey": key]))
        XCTAssertNil(UpdateFeed(info: ["SUFeedURL": url.absoluteString, "SUPublicEDKey": Data(repeating: 7, count: 32)]))
        XCTAssertNil(UpdateFeed(info: ["SUFeedURL": url.absoluteString, "SUPublicEDKey": ""]))
    }

    func testPublicKeyIsTrimmedOfSpaces() {
        XCTAssertEqual(UpdateFeed(info: ["SUFeedURL": "https://example.com/a.xml", "SUPublicEDKey": "  \(key)\t"])?.publicKey, key)
    }

    func testPublicKeyOfOnlyNewlinesIsRefused() {
        for blank in ["\n", "\r\n", " \n\t ", "\u{2028}"] {
            XCTAssertNil(UpdateFeed(info: ["SUFeedURL": "https://example.com/a.xml", "SUPublicEDKey": blank]), blank.debugDescription)
        }
    }

    func testPublicKeyIsTrimmedOfNewlines() {
        XCTAssertEqual(UpdateFeed(info: ["SUFeedURL": "https://example.com/a.xml", "SUPublicEDKey": "\n  \(key)\r\n"])?.publicKey, key)
    }

    func testFeedsWithTheSameValuesAreEqual() {
        let info: [String: Any] = ["SUFeedURL": "https://example.com/a.xml", "SUPublicEDKey": key]
        XCTAssertEqual(UpdateFeed(info: info), UpdateFeed(info: info))
        XCTAssertNotEqual(UpdateFeed(info: info), UpdateFeed(info: ["SUFeedURL": "https://example.com/b.xml", "SUPublicEDKey": key]))
    }

    // MARK: Preferences

    func testPrereleaseLabelsFollowTheBetaChannel() {
        for version in ["1.0.0-alpha.1", "1.0.0-beta.3", "2.1.0-rc.12"] { XCTAssertTrue(AppVersion.isPrerelease(version), version) }
        for version in ["1.0.0", "0.11.0", "10.20.30"] { XCTAssertFalse(AppVersion.isPrerelease(version), version) }
        XCTAssertEqual(UpdateFeed.betaChannel, "beta")
    }

    func testBetaChoiceIsSavedUnderItsKeyAndSharedAcrossInstances() throws {
        try withDefaults { defaults in
            XCTAssertNil(defaults.object(forKey: UpdatePreferences.includeBetasKey), "nothing is saved until chosen")
            UpdatePreferences(defaults: defaults, version: "1.0.0").includeBetas = true
            XCTAssertEqual(defaults.object(forKey: "ReqsIncludeBetaUpdates") as? Bool, true)
            XCTAssertTrue(UpdatePreferences(defaults: defaults, version: "2.0.0").includeBetas)
        }
    }

    func testAStableChoiceOnABetaBuildIsRemembered() throws {
        try withDefaults { defaults in
            let beta = UpdatePreferences(defaults: defaults, version: "1.0.0-rc.1")
            XCTAssertEqual(beta.allowedChannels, ["beta"])
            beta.includeBetas = false
            XCTAssertEqual(UpdatePreferences(defaults: defaults, version: "1.0.0-rc.2").allowedChannels, [])
        }
    }

    func testAStoredValueThatIsNotABoolFollowsTheBuild() throws {
        try withDefaults { defaults in
            defaults.set("yes", forKey: UpdatePreferences.includeBetasKey)
            XCTAssertFalse(UpdatePreferences(defaults: defaults, version: "1.0.0").includeBetas)
            XCTAssertTrue(UpdatePreferences(defaults: defaults, version: "1.0.0-beta.1").includeBetas)
        }
    }

    // MARK: Settings model

    @MainActor
    func testModelStartsFromTheUpdatersState() {
        let updater = RecordingUpdater()
        let checked = Date(timeIntervalSince1970: 1_700_000_000)
        updater.automaticallyChecksForUpdates = true
        updater.includesBetas = true
        updater.lastUpdateCheckDate = checked
        updater.canCheckForUpdates = false
        let model = UpdateSettingsModel(updater: updater, version: "0.11.0")
        XCTAssertTrue(model.automaticChecks)
        XCTAssertTrue(model.includeBetas)
        XCTAssertEqual(model.lastCheck, checked)
        XCTAssertFalse(model.canCheck)
        XCTAssertNotNil(updater.onChange, "the model listens for Sparkle's own changes")
    }

    @MainActor
    func testRefreshPicksUpChangesMadeOutsideTheModel() {
        let updater = RecordingUpdater()
        let model = UpdateSettingsModel(updater: updater)
        updater.automaticallyChecksForUpdates = true
        updater.includesBetas = true
        XCTAssertFalse(model.automaticChecks, "nothing changes until a refresh or onChange")
        model.refresh()
        XCTAssertTrue(model.automaticChecks)
        XCTAssertTrue(model.includeBetas)
    }

    @MainActor
    func testTurningSettingsOffWritesThrough() {
        let updater = RecordingUpdater()
        updater.automaticallyChecksForUpdates = true
        updater.includesBetas = true
        let model = UpdateSettingsModel(updater: updater)
        model.setAutomaticChecks(false)
        model.setIncludeBetas(false)
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
        XCTAssertFalse(updater.includesBetas)
        XCTAssertFalse(model.automaticChecks)
        XCTAssertFalse(model.includeBetas)
        XCTAssertEqual(updater.checks, 0)
    }

    @MainActor
    func testCheckNowDoesNothingWhileTheUpdaterIsBusy() {
        let updater = RecordingUpdater()
        updater.canCheckForUpdates = false
        let model = UpdateSettingsModel(updater: updater)
        model.checkNow()
        XCTAssertEqual(updater.checks, 0)
        updater.canCheckForUpdates = true
        model.checkNow()
        XCTAssertEqual(updater.checks, 1, "the model asks the updater, not its own cached state")
    }

    @MainActor
    func testAFinishedCheckUpdatesTheLastCheckDate() {
        let updater = RecordingUpdater()
        let model = UpdateSettingsModel(updater: updater)
        XCTAssertNil(model.lastCheck)
        let finished = Date(timeIntervalSince1970: 1_800_000_000)
        updater.lastUpdateCheckDate = finished
        updater.onChange?()
        XCTAssertEqual(model.lastCheck, finished)
    }

    @MainActor
    func testTheUpdaterDoesNotKeepTheModelAlive() {
        let updater = RecordingUpdater()
        weak var released: UpdateSettingsModel?
        do {
            let model = UpdateSettingsModel(updater: updater)
            released = model
        }
        XCTAssertNil(released)
        updater.onChange?()  // a late Sparkle callback after the settings went away
    }
}
