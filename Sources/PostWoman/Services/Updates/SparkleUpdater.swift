import Foundation
import Sparkle

/// Sparkle behind `SoftwareUpdater`, as in Trellis. Created only for bundles with a feed and key; Info.plist turns
/// automatic checks and system profiling off, so nothing reaches the network until the user checks or opts in.
/// PostWoman is sandboxed, so Sparkle installs through its Installer XPC service (`SUEnableInstallerLauncherService`).
@MainActor final class SparkleUpdater: NSObject, SoftwareUpdater, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []
    private let preferences = UpdatePreferences()
    var onChange: (() -> Void)?

    init?(bundle: Bundle = .main) {
        guard UpdateFeed(info: bundle.infoDictionary ?? [:]) != nil else { return nil }
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        let updater = controller.updater
        // Only `canCheckForUpdates` is KVO-compliant; the last check date is refreshed when an update cycle finishes.
        observations = [
            updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
                Task { @MainActor in self?.onChange?() }
            }
        ]
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    var includesBetas: Bool {
        get { preferences.includeBetas }
        set { preferences.includeBetas = newValue }
    }
    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }
    func checkForUpdates() { controller.checkForUpdates(nil) }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        Task { @MainActor [weak self] in self?.onChange?() }
    }
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> { UpdatePreferences().allowedChannels }
}
