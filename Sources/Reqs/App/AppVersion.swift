import Foundation

/// The app version. `release` must match `release/manifest.json` (checked by `AppVersionTests`).
enum AppVersion {
    static let release = "0.11.0"

    /// The packaged bundle's version, or `release` when running unbundled (`swift run`).
    static var current: String { bundled ?? release }

    /// A packaged build's full version. `CFBundleShortVersionString` must be numeric (`1.0.0`), so packaging also writes
    /// the whole version, pre-release label included, to `ReqsVersion`. Nil for SwiftPM builds.
    static var bundled: String? { version(in: Bundle.main.infoDictionary) }

    /// The full version in an Info.plist: `ReqsVersion`, else `PostWomanVersion` (builds from before the rename), else the numeric one.
    static func version(in info: [String: Any]?) -> String? {
        info?["ReqsVersion"] as? String ?? info?["PostWomanVersion"] as? String ?? info?["CFBundleShortVersionString"] as? String
    }

    /// `X.Y.Z-alpha|beta|rc.N` builds are pre-releases; they follow the beta update channel by default.
    static func isPrerelease(_ version: String) -> Bool { version.contains("-") }
}
