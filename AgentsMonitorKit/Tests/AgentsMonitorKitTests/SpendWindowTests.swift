import XCTest
@testable import AgentsMonitorKit

private func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

final class SpendWindowTests: XCTestCase {
    func testStarts() {
        let now = utc("2026-11-03T10:00:00Z")   // Tuesday
        XCTAssertEqual(SpendWindow.utcDay.start(now: now), utc("2026-11-03T00:00:00Z"))
        XCTAssertEqual(SpendWindow.utcWeek.start(now: now), utc("2026-11-02T00:00:00Z"))
        XCTAssertEqual(SpendWindow.utcMonth.start(now: now), utc("2026-11-01T00:00:00Z"))
        XCTAssertEqual(SpendWindow.lastHour.start(now: now), utc("2026-11-03T09:00:00Z"))
        XCTAssertEqual(SpendWindow.last24h.start(now: now), utc("2026-11-02T10:00:00Z"))
        XCTAssertEqual(SpendWindow.utcWeek.start(now: utc("2026-11-08T23:59:00Z")), utc("2026-11-02T00:00:00Z"))   // Sunday
    }

    func testCalendarSpendFromKey() {
        let key = OpenRouterKeyUsage(id: "k", label: "l", usageDaily: 1, usageWeekly: 2, usageMonthly: 3)
        XCTAssertEqual(key.spend(in: .utcDay), 1)
        XCTAssertEqual(key.spend(in: .utcWeek), 2)
        XCTAssertEqual(key.spend(in: .utcMonth), 3)
        XCTAssertNil(key.spend(in: .lastHour))
    }

    private func s(_ t: Double, _ u: Double) -> OpenRouterSample { .init(t: t, id: "k", u: u) }

    func testSpentMath() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let exact = try XCTUnwrap(openRouterSpent(samples: [s(500, 1), s(1000, 2), s(1500, 3)], since: since, nowUsage: 5))
        XCTAssertEqual(exact.usd, 3, accuracy: 1e-9); XCTAssertFalse(exact.partial)
        let earlier = try XCTUnwrap(openRouterSpent(samples: [s(900, 2), s(1500, 3)], since: since, nowUsage: 5))
        XCTAssertEqual(earlier.usd, 3, accuracy: 1e-9); XCTAssertFalse(earlier.partial)
        let partial = try XCTUnwrap(openRouterSpent(samples: [s(1200, 2), s(1500, 3)], since: since, nowUsage: 5))
        XCTAssertEqual(partial.usd, 3, accuracy: 1e-9); XCTAssertTrue(partial.partial)
        XCTAssertNil(openRouterSpent(samples: [], since: since, nowUsage: 5))
        let reset = try XCTUnwrap(openRouterSpent(samples: [s(900, 10)], since: since, nowUsage: 5))
        XCTAssertEqual(reset.usd, 0); XCTAssertFalse(reset.partial)
    }

    func testHistoryRoundTripAndPrune() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let h = OpenRouterHistory(url: url)
        h.append([s(100, 1), s(200, 2), s(300, 3)])
        XCTAssertEqual(h.load(since: Date(timeIntervalSince1970: 0)).map(\.u), [1, 2, 3])
        XCTAssertEqual(h.load(since: Date(timeIntervalSince1970: 200)).map(\.u), [2, 3])
        let before = try Data(contentsOf: url)
        h.prune(before: Date(timeIntervalSince1970: 50))
        XCTAssertEqual(try Data(contentsOf: url), before)   // nothing older: untouched
        h.prune(before: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(h.load(since: Date(timeIntervalSince1970: 0)).map(\.u), [2, 3])
    }
}
