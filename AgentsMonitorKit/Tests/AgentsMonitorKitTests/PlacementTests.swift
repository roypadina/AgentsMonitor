import XCTest
@testable import AgentsMonitorKit

final class PlacementTests: XCTestCase {
    private func decode(_ json: String) throws -> Account {
        try JSONDecoder().decode(Account.self, from: Data(json.utf8))
    }

    private let base = #""id":"11111111-1111-1111-1111-111111111111","name":"a","kind":{"remote":{}}"#

    func testLegacyDecode() throws {
        XCTAssertEqual(try decode("{\(base),\"showInMenuBar\":false}").placement, .popover)
        XCTAssertEqual(try decode("{\(base),\"showInMenuBar\":true}").placement, .menuBar)
        XCTAssertEqual(try decode("{\(base)}").placement, .menuBar)
        XCTAssertEqual(try decode("{\(base),\"placement\":\"hidden\",\"showInMenuBar\":true}").placement, .hidden)
    }

    func testEncodeWritesPlacementAndLegacyKey() throws {
        var account = try decode("{\(base)}")
        account.placement = .more
        let json = String(decoding: try JSONEncoder().encode(account), as: UTF8.self)
        XCTAssertTrue(json.contains("\"placement\":\"more\""))
        XCTAssertTrue(json.contains("\"showInMenuBar\":false"), "older versions read this key")
        XCTAssertEqual(try decode(json).placement, .more)
    }

    @MainActor func testProviderOpenRouter() {
        XCTAssertEqual(Provider.allCases.count, 3)
        XCTAssertTrue(AppStore.profileDirs(for: .openrouter).isEmpty)
    }

    private func limit(_ kind: String, _ percent: Int, model: String? = nil) -> LimitInfo {
        LimitInfo(kind: kind, group: nil, percent: percent, severity: .normal,
                  resetsAt: nil, modelDisplayName: model, isActive: true)
    }

    func testCompactLimitsAndTags() {
        let snap = UsageSnapshot(limits: [
            limit("code_review", 5), limit("weekly_scoped", 10, model: "Opus"),
            limit("weekly_scoped", 49, model: "Fable"), limit("weekly_all", 12), limit("session", 52),
        ], spend: nil)
        let picked = snap.compactLimits
        XCTAssertEqual(picked.map(\.kind), ["session", "weekly_all", "weekly_scoped"])
        XCTAssertEqual(picked.map(\.shortTag), ["5h", "7d", "F"])
        let codex = UsageSnapshot(limits: [limit("session", 1), limit("weekly_all", 2), limit("code_review", 3)], spend: nil)
        XCTAssertEqual(codex.compactLimits.map(\.shortTag), ["5h", "7d", "CR"])
        XCTAssertEqual(limit("foo_bar", 1).shortTag, "FB")
    }

    func testAttentionLimit() {
        let thresholds = AlertThresholds(warning: 80, critical: 95)
        let none: (LimitInfo) -> Date? = { _ in nil }
        let calm = UsageSnapshot(limits: [limit("session", 52), limit("weekly_all", 12)], spend: nil)
        XCTAssertNil(calm.attentionLimit(thresholds: thresholds, projectedFull: none))

        // Server grade alone, and the user's thresholds alone, both count.
        let graded = LimitInfo(kind: "session", group: nil, percent: 60, severity: .warning,
                               resetsAt: nil, modelDisplayName: nil, isActive: true)
        XCTAssertEqual(UsageSnapshot(limits: [graded], spend: nil)
            .attentionLimit(thresholds: thresholds, projectedFull: none)?.severity, .warning)
        let local = UsageSnapshot(limits: [limit("session", 10), limit("weekly_all", 85)], spend: nil)
        XCTAssertEqual(local.attentionLimit(thresholds: thresholds, projectedFull: none)?.limit.kind, "weekly_all")

        // Blocked beats a higher severity elsewhere; critical beats warning.
        let mixed = UsageSnapshot(limits: [limit("session", 98), limit("weekly_all", 100), limit("weekly_scoped", 85, model: "Fable")], spend: nil)
        XCTAssertEqual(mixed.attentionLimit(thresholds: thresholds, projectedFull: none)?.limit.kind, "weekly_all")
        let noBlock = UsageSnapshot(limits: [limit("session", 85), limit("weekly_all", 96)], spend: nil)
        XCTAssertEqual(noBlock.attentionLimit(thresholds: thresholds, projectedFull: none)?.limit.kind, "weekly_all")

        // Pace alone puts a calm limit on line 2, carrying the projection.
        let full = Date(timeIntervalSince1970: 1_000_000)
        let paced = calm.attentionLimit(thresholds: thresholds) { $0.kind == "session" ? full : nil }
        XCTAssertEqual(paced?.limit.kind, "session")
        XCTAssertEqual(paced?.severity, .normal)
        XCTAssertEqual(paced?.full, full)
    }

    func testShortCountdown() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(shortCountdown(to: now, now: now), "0m")
        XCTAssertEqual(shortCountdown(to: now.addingTimeInterval(59), now: now), "0m")
        XCTAssertEqual(shortCountdown(to: now.addingTimeInterval(3 * 3600 + 5 * 60), now: now), "3h 5m")
    }
}
