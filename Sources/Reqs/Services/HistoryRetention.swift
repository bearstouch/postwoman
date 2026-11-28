import Foundation
import SwiftData

/// Keeps History to the most recent entries, up to the limit chosen in Settings → General.
@MainActor
enum HistoryRetention {
    /// The UserDefaults key of the limit.
    static let limitKey = "historyLimit"
    static let defaultLimit = 300
    static let limitRange = 1...100_000

    /// The saved limit, or `defaultLimit` when none was chosen.
    static func limit(in defaults: UserDefaults = .standard) -> Int {
        let value = defaults.object(forKey: limitKey) as? Int ?? defaultLimit
        return min(max(value, limitRange.lowerBound), limitRange.upperBound)
    }

    /// Deletes the oldest entries beyond `limit`. Returns how many were deleted.
    @discardableResult
    static func trim(_ context: ModelContext, limit: Int = HistoryRetention.limit()) -> Int {
        // Not `fetchOffset`: SwiftData ignores it for entries inserted but not yet saved.
        var descriptor = FetchDescriptor<RequestHistory>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.propertiesToFetch = [\.timestamp]
        guard let entries = try? context.fetch(descriptor), entries.count > limit else { return 0 }
        let excess = Array(entries.dropFirst(max(limit, 0)))
        delete(excess, in: context)
        return excess.count
    }

    /// Deletes every entry. Returns how many were deleted.
    @discardableResult
    static func clear(_ context: ModelContext) -> Int {
        guard let entries = try? context.fetch(FetchDescriptor<RequestHistory>()), !entries.isEmpty else { return 0 }
        delete(entries, in: context)
        return entries.count
    }

    private static func delete(_ entries: [RequestHistory], in context: ModelContext) {
        // Views drop selections of models about to go (see ContentView).
        NotificationCenter.default.post(name: .remoteAgentWillDelete, object: nil, userInfo: ["ids": Set(entries.map(\.id))])
        for entry in entries { context.delete(entry) }
        try? context.save()
    }
}
