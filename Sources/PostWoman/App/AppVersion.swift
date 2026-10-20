import Foundation

/// The app version. `release` must match `release/manifest.json` (checked by `AppVersionTests`).
enum AppVersion {
    static let release = "0.9.1"

    /// The packaged bundle's version, or `release` when running unbundled (`swift run`).
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? release
    }
}
