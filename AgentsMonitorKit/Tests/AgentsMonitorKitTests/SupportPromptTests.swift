import XCTest
@testable import AgentsMonitorKit

final class SupportPromptTests: XCTestCase {
    private let day = SupportPromptState.day
    private let install = Date(timeIntervalSince1970: 1_794_528_000)  // 2026-11-13 (UTC)

    private func mayAsk(_ s: SupportPromptState, day d: Double, checks: Int = 2500, version: String = "1.10.0") -> Bool {
        s.mayAsk(now: install.addingTimeInterval(d * day), installDate: install, usageChecks: checks, appVersion: version)
    }

    func testFirstAskNeedsSevenDaysAndMoreThan2000Checks() {
        let s = SupportPromptState()
        XCTAssertFalse(mayAsk(s, day: 6.9))
        XCTAssertFalse(mayAsk(s, day: 60, checks: 2000), "never at 2000 or fewer, however long installed")
        XCTAssertTrue(mayAsk(s, day: 7, checks: 2001))
    }

    func testSnoozeHidesFourteenDays() {
        var s = SupportPromptState()
        s.record(.snooze, now: install.addingTimeInterval(10 * day), appVersion: "1.10.0")
        XCTAssertFalse(mayAsk(s, day: 23.9))
        XCTAssertTrue(mayAsk(s, day: 24))
    }

    func testSupportQuietFor180Days() {
        var s = SupportPromptState()
        s.record(.support, now: install.addingTimeInterval(10 * day), appVersion: "1.10.0")
        XCTAssertFalse(mayAsk(s, day: 189))
        XCTAssertTrue(mayAsk(s, day: 190))
    }

    func testNeverLastsUntilNextMajorAndNinetyDays() {
        var s = SupportPromptState()
        s.record(.never, now: install.addingTimeInterval(10 * day), appVersion: "1.10.0")
        XCTAssertFalse(mayAsk(s, day: 300, version: "1.11.0"), "a feature release must not undo 'never'")
        XCTAssertFalse(mayAsk(s, day: 50, version: "2.0.0"), "a major release within 90 days must not undo it")
        XCTAssertTrue(mayAsk(s, day: 100, version: "2.0.0"))
    }

    func testAtMostThreeAsksPerRolling365Days() {
        var s = SupportPromptState()
        for d in [10.0, 40, 70] { s.recordShown(install.addingTimeInterval(d * day)) }
        XCTAssertFalse(mayAsk(s, day: 300))
        XCTAssertTrue(mayAsk(s, day: 376), "the first ask has rolled out of the window")
    }

    func testOldOrPartialStateDecodes() throws {
        XCTAssertEqual(try JSONDecoder().decode(SupportPromptState.self, from: Data("{}".utf8)), SupportPromptState())
        let snoozed = try JSONDecoder().decode(SupportPromptState.self, from: Data(#"{"snoozedUntil":0}"#.utf8))
        XCTAssertEqual(snoozed.snoozedUntil, Date(timeIntervalSinceReferenceDate: 0), "known keys survive missing ones")
        XCTAssertEqual(snoozed.shownAt, [])
    }

    /// ~96 checks a day (5-min polls, 8 h awake), a release every 4 days (every 3rd a feature release,
    /// 2.0.0 at day 240), user snoozes twice then says never → 3 asks in year 1, the first on day 20.
    func testYearOnePacing() {
        var s = SupportPromptState()
        var version = [1, 10, 0], releases = 0, checks = 0
        var asks: [Int] = []
        for d in 0..<365 {
            if d > 0, d % 4 == 0 {
                releases += 1
                if d >= 240, version[0] == 1 { version = [2, 0, 0] }
                else if releases % 3 == 0 { version = [version[0], version[1] + 1, 0] }
                else { version[2] += 1 }
            }
            checks += 96
            let now = install.addingTimeInterval(Double(d) * day)
            let v = version.map(String.init).joined(separator: ".")
            guard s.mayAsk(now: now, installDate: install, usageChecks: checks, appVersion: v) else { continue }
            s.recordShown(now)
            s.record(asks.count < 2 ? .snooze : .never, now: now, appVersion: v)
            asks.append(d)
        }
        XCTAssertEqual(asks, [20, 34, 48])
    }

    @MainActor
    func testCalmOnlyWithFreshNumbersUnderTheWarningThreshold() {
        let store = AppStore()
        XCTAssertFalse(store.isCalm, "no accounts: nothing was looked at")
        let account = Account(name: "a", kind: .remote)
        store.accounts = [account]
        func snapshot(_ percent: Int, _ severity: Severity = .normal) -> UsageSnapshot {
            UsageSnapshot(limits: [LimitInfo(kind: "session", group: nil, percent: percent, severity: severity,
                                             resetsAt: nil, modelDisplayName: nil, isActive: true)], spend: nil)
        }
        store.states[account.id] = .ok(snapshot(79))
        XCTAssertTrue(store.isCalm)
        store.states[account.id] = .ok(snapshot(80))
        XCTAssertFalse(store.isCalm, "at the warning threshold")
        store.states[account.id] = .ok(snapshot(40, .warning))
        XCTAssertFalse(store.isCalm, "graded warning by the server")
        store.states[account.id] = .stale(snapshot(10), error: "x")
        XCTAssertFalse(store.isCalm, "an error line is not a calm look")
    }

    @MainActor
    func testOpenRouterErrorsAreNotCalm() {
        let store = AppStore()
        let account = Account(name: "a", kind: .remote)
        store.accounts = [account]
        store.states[account.id] = .ok(UsageSnapshot(limits: [], spend: nil))
        let key = OpenRouterKeyUsage(id: "k", label: "l")
        store.openRouterState = .ok(OpenRouterSnapshot(keys: [key]))
        XCTAssertTrue(store.isCalm)
        store.openRouterState = .ok(OpenRouterSnapshot(keys: [key], managementError: "x"))
        XCTAssertFalse(store.isCalm, "management key failed")
        store.openRouterState = .ok(OpenRouterSnapshot(keys: [OpenRouterKeyUsage(id: "k", label: "l", error: "x")]))
        XCTAssertFalse(store.isCalm, "a pasted key failed")
        store.openRouterState = .stale(OpenRouterSnapshot(keys: [key]), error: "x")
        XCTAssertFalse(store.isCalm)
        store.openRouterState = .failed("x")
        XCTAssertFalse(store.isCalm)
    }
}
