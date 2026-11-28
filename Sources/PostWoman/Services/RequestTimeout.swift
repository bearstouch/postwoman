import Foundation

/// How long a request waits for the server before it fails, chosen in Settings → General.
enum RequestTimeout {
    /// The UserDefaults key of the timeout, in seconds.
    static let key = "defaultTimeout"
    static let defaultSeconds: TimeInterval = 30
    /// The CLI waits a little longer than the upper bound for `request_execute` (`MCPClient.post`).
    static let range: ClosedRange<TimeInterval> = 1...600

    /// The saved timeout kept within `range`, or `defaultSeconds` when none was chosen or it isn't a usable number.
    static func seconds(in defaults: UserDefaults = .standard) -> TimeInterval {
        guard let value = (defaults.object(forKey: key) as? NSNumber)?.doubleValue, value.isFinite, value > 0 else { return defaultSeconds }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
