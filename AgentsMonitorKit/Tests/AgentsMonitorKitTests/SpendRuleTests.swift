import XCTest
@testable import AgentsMonitorKit

private func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

final class SpendRuleTests: XCTestCase {
    private let now = utc("2026-11-03T10:00:00Z")

    private func snapshot(balance: Double? = 42.17) throws -> OpenRouterSnapshot {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "openrouter_keys", withExtension: "json", subdirectory: "Fixtures"))
        let keys = try OpenRouterClient.decodeKeyList(try Data(contentsOf: url), now: now)
        return OpenRouterSnapshot(keys: keys, balance: balance.map { OpenRouterBalance(totalCredits: $0 + 10, totalUsage: 10) },
                                  fetchedAt: now)
    }

    private func names(_ id: String) -> String { id.prefix(1) == "a" ? "prod-agent" : id }
    private func eval(_ engine: inout AlertEngine, _ rules: [SpendRule], _ snap: OpenRouterSnapshot,
                      at date: Date? = nil, spent: Double = 0) -> [Alert] {
        engine.evaluateSpendRules(rules, snapshot: snap, displayName: names, spent: { _, _ in spent }, now: date ?? now)
    }
    private var prodId: String { "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90" }

    func testAllKeysDailyFiresOncePerWindow() throws {
        var engine = AlertEngine()
        let rule = SpendRule(kind: .spend, scope: .allKeys, window: .utcDay, threshold: 3)
        let snap = try snapshot()
        let first = eval(&engine, [rule], snap)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].title, "OpenRouter — all keys")
        XCTAssertEqual(first[0].body, "$3.60 spent today (UTC) · over $3.00")
        XCTAssertEqual(first[0].accountId, OpenRouter.alertAccountId)
        XCTAssertTrue(first[0].key.hasPrefix("or|"))
        XCTAssertTrue(eval(&engine, [rule], snap).isEmpty)
        XCTAssertEqual(eval(&engine, [rule], snap, at: now.addingTimeInterval(86400)).count, 1)
    }

    func testEachKey() throws {
        var engine = AlertEngine()
        let out = eval(&engine, [SpendRule(kind: .spend, scope: .eachKey, window: .utcDay, threshold: 3)], try snapshot())
        XCTAssertEqual(out.map(\.title), ["OpenRouter — prod-agent"])
    }

    func testRollingRearms() throws {
        var engine = AlertEngine()
        let rule = SpendRule(kind: .spend, scope: .key(prodId), window: .lastHour, threshold: 1)
        let snap = try snapshot()
        XCTAssertEqual(eval(&engine, [rule], snap, spent: 1.5).count, 1)
        XCTAssertTrue(eval(&engine, [rule], snap, spent: 0.5).isEmpty)
        XCTAssertEqual(engine.memory["or|\(rule.id.uuidString)|\(prodId)"]?.level, AlertLevel.none)
        XCTAssertEqual(eval(&engine, [rule], snap, spent: 1.5).count, 1)
    }

    func testCapRemaining() throws {
        var engine = AlertEngine()
        let pct = SpendRule(kind: .capRemaining, scope: .eachKey, unit: .percent, threshold: 50)
        let out = eval(&engine, [pct], try snapshot())
        XCTAssertEqual(out.count, 1)   // prod-agent only: ci-runner 100% left, research uncapped
        XCTAssertEqual(out[0].body, "40% left · below 50%")
        XCTAssertEqual(out[0].title, "OpenRouter — prod-agent cap")
        var engine2 = AlertEngine()
        let usd = SpendRule(kind: .capRemaining, scope: .key(prodId), unit: .usd, threshold: 10)
        XCTAssertEqual(eval(&engine2, [usd], try snapshot()).first?.body, "$8.00 of $20.00 left · below $10.00")
    }

    func testBalance() throws {
        var engine = AlertEngine()
        let rule = SpendRule(kind: .balance, threshold: 50)
        XCTAssertEqual(eval(&engine, [rule], try snapshot(balance: 42.17)).first?.body, "$42.17 left · below $50.00")
        XCTAssertTrue(eval(&engine, [rule], try snapshot(balance: 60)).isEmpty)
        XCTAssertEqual(eval(&engine, [rule], try snapshot(balance: 42)).count, 1)
        XCTAssertTrue(eval(&engine, [rule], try snapshot(balance: nil)).isEmpty)
    }

    func testDisabledAndLevel() throws {
        var engine = AlertEngine()
        var rule = SpendRule(kind: .spend, scope: .allKeys, window: .utcDay, threshold: 3, level: .critical)
        rule.enabled = false
        XCTAssertTrue(eval(&engine, [rule], try snapshot()).isEmpty)
        XCTAssertTrue(engine.memory.isEmpty)
        rule.enabled = true
        XCTAssertEqual(eval(&engine, [rule], try snapshot()).first?.level, .critical)
    }

    func testMemoryPersists() throws {
        var engine = AlertEngine()
        let rule = SpendRule(kind: .spend, scope: .allKeys, window: .utcDay, threshold: 3)
        XCTAssertEqual(eval(&engine, [rule], try snapshot()).count, 1)
        let data = try XCTUnwrap(engine.memorySnapshot)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("or|"))
        var fresh = AlertEngine()
        fresh.restoreMemory(from: data)
        XCTAssertTrue(eval(&fresh, [rule], try snapshot()).isEmpty)
    }

    func testSummaries() {
        let n: (String) -> String = { _ in "prod-agent" }
        XCTAssertEqual(SpendRule(kind: .spend, scope: .allKeys, window: .utcWeek, threshold: 20).summary(names: n),
                       "All keys · over $20.00 this week (UTC)")
        XCTAssertEqual(SpendRule(kind: .spend, scope: .eachKey, window: .lastHour, threshold: 5).summary(names: n),
                       "Each key · over $5.00 in the last hour")
        XCTAssertEqual(SpendRule(kind: .capRemaining, scope: .key("x"), unit: .percent, threshold: 10).summary(names: n),
                       "prod-agent · cap below 10% left")
        XCTAssertEqual(SpendRule(kind: .balance, threshold: 10).summary(names: n), "Balance below $10.00")
    }

    func testRuleLenientDecodeAndRoundTrip() throws {
        let r = try JSONDecoder().decode(SpendRule.self, from: Data("{}".utf8))
        XCTAssertEqual(r.kind, .spend)
        let rule = SpendRule(kind: .spend, scope: .key("abc"), window: .utcMonth, threshold: 7)
        XCTAssertEqual(try JSONDecoder().decode(SpendRule.self, from: JSONEncoder().encode(rule)), rule)
        XCTAssertEqual(Ntfy.flow(forAlertKey: "or|x|all"), "openrouter-spend")
    }
}
