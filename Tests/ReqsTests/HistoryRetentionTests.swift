import SwiftData
import XCTest

@testable import Reqs

@MainActor
final class HistoryRetentionTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() async throws {
        container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() async throws {
        container = nil
    }

    private func insertEntries(_ count: Int) {
        let start = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<count {
            let entry = RequestHistory(url: "https://example.com/\(index)", method: .get)
            entry.timestamp = start.addingTimeInterval(Double(index))
            container.mainContext.insert(entry)
        }
    }

    private func urls() throws -> [String] {
        try container.mainContext.fetch(FetchDescriptor<RequestHistory>(sortBy: [SortDescriptor(\.timestamp)])).map(\.url)
    }

    func testTrimKeepsTheMostRecentEntries() throws {
        insertEntries(5)
        XCTAssertEqual(HistoryRetention.trim(container.mainContext, limit: 3), 2)
        XCTAssertEqual(try urls(), ["https://example.com/2", "https://example.com/3", "https://example.com/4"])
    }

    func testTrimUnderTheLimitDeletesNothing() throws {
        insertEntries(2)
        XCTAssertEqual(HistoryRetention.trim(container.mainContext, limit: 3), 0)
        XCTAssertEqual(try urls().count, 2)
    }

    func testClearDeletesEverything() throws {
        insertEntries(4)
        XCTAssertEqual(HistoryRetention.clear(container.mainContext), 4)
        XCTAssertEqual(try urls(), [])
    }

    func testLimitDefaultsTo300AndIsClamped() throws {
        let suite = "HistoryRetentionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(HistoryRetention.limit(in: defaults), 300)
        defaults.set(0, forKey: HistoryRetention.limitKey)
        XCTAssertEqual(HistoryRetention.limit(in: defaults), 1)
        defaults.set(50, forKey: HistoryRetention.limitKey)
        XCTAssertEqual(HistoryRetention.limit(in: defaults), 50)
        defaults.removePersistentDomain(forName: "HistoryRetentionTests")
    }
}
