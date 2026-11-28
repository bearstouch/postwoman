import Foundation

/// The app version. `release` must match `release/manifest.json` (checked by `AppVersionTests`).
enum AppVersion {
    static let release = "0.11.0"

    /// The packaged bundle's version, or `release` when running unbundled (`swift run`).
    static var current: String { bundled ?? release }

    /// A packaged build's full version. `CFBundleShortVersionString` must be numeric (`1.0.0`), so packaging also writes
    /// the whole version, pre-release label included, to `ReqsVersion`. Nil for SwiftPM builds.
    static var bundled: String? {
        let info = Bundle.main.infoDictionary
        return info?["ReqsVersion"] as? String ?? info?["CFBundleShortVersionString"] as? String
    }

    /// `X.Y.Z-alpha|beta|rc.N` builds are pre-releases; they follow the beta update channel by default.
    static func isPrerelease(_ version: String) -> Bool { version.contains("-") }
}
