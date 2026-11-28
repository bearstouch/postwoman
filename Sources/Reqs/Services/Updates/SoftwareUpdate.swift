import Foundation
import Observation

/// A packaged build's Sparkle feed. Builds without one (`swift run`, `scripts/run-app.sh`) have no updater and never
/// contact the network.
struct UpdateFeed: Equatable, Sendable {
    static let betaChannel = "beta"
    let url: URL
    let publicKey: String

    /// Needs an HTTPS `SUFeedURL` (plain HTTP only on loopback, for local testing) and an `SUPublicEDKey` that is not blank.
    init?(info: [String: Any]) {
        guard let raw = info["SUFeedURL"] as? String, let url = URL(string: raw), let host = url.host, !host.isEmpty,
            let key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
        else { return nil }
        guard url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(host)) else { return nil }
        self.url = url
        publicKey = key
    }
}

/// Update choices Sparkle doesn't store itself. Automatic checks live in Sparkle's own defaults, off until turned on.
struct UpdatePreferences {
    static let includeBetasKey = "ReqsIncludeBetaUpdates"
    private let defaults: UserDefaults
    private let version: String

    init(defaults: UserDefaults = .standard, version: String = AppVersion.current) {
        self.defaults = defaults
        self.version = version
    }

    /// Unset means "follow the running build": a pre-release keeps receiving pre-releases.
    var includeBetas: Bool {
        get { defaults.object(forKey: Self.includeBetasKey) as? Bool ?? AppVersion.isPrerelease(version) }
        nonmutating set { defaults.set(newValue, forKey: Self.includeBetasKey) }
    }

    /// Items without a channel are stable and always allowed; `beta` items need the opt-in.
    var allowedChannels: Set<String> { includeBetas ? [UpdateFeed.betaChannel] : [] }
}

/// The app's updater (Sparkle in packaged builds); views and tests never see the engine.
@MainActor protocol SoftwareUpdater: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var includesBetas: Bool { get set }
    var lastUpdateCheckDate: Date? { get }
    /// Called when the values above change outside a setter, such as a check starting or finishing.
    var onChange: (() -> Void)? { get set }
    func checkForUpdates()
}

/// What Settings → Updates and the Check for Updates… menu item show.
@MainActor @Observable final class UpdateSettingsModel {
    private(set) var canCheck = false
    private(set) var automaticChecks = false
    private(set) var includeBetas = false
    private(set) var lastCheck: Date?
    let version: String
    @ObservationIgnored private let updater: SoftwareUpdater

    init(updater: SoftwareUpdater, version: String = AppVersion.current) {
        self.updater = updater
        self.version = version
        updater.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    func refresh() {
        canCheck = updater.canCheckForUpdates
        automaticChecks = updater.automaticallyChecksForUpdates
        includeBetas = updater.includesBetas
        lastCheck = updater.lastUpdateCheckDate
    }

    func setAutomaticChecks(_ enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
        refresh()
    }

    func setIncludeBetas(_ enabled: Bool) {
        updater.includesBetas = enabled
        refresh()
    }

    func checkNow() {
        guard updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
        refresh()
    }
}
