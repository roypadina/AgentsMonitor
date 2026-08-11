import XCTest
import Foundation
@testable import ClaudeMonitorKit

private func loadFixtureData(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// Well before both fixtures' `resets_at` timestamps (2026-08-10/12), so nothing gets nulled.
private let fixtureFetchedAt = ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z")!

// MARK: - 1. Parsing

final class ParsingTests: XCTestCase {
    func testFixtureWithSpend() throws {
        let data = try loadFixtureData("usage_with_spend")
        let snapshot = try UsageSnapshot.decode(data, fetchedAt: fixtureFetchedAt)

        XCTAssertEqual(snapshot.limits.count, 3)
        XCTAssertEqual(snapshot.limits[0].kind, "session")
        XCTAssertEqual(snapshot.limits[0].percent, 18)
        XCTAssertEqual(snapshot.limits[0].severity, .normal)
        XCTAssertEqual(snapshot.limits[1].kind, "weekly_all")
        XCTAssertEqual(snapshot.limits[1].percent, 81)
        XCTAssertEqual(snapshot.limits[1].severity, .warning)
        XCTAssertEqual(snapshot.limits[2].kind, "weekly_scoped")
        XCTAssertEqual(snapshot.limits[2].percent, 95)
        XCTAssertEqual(snapshot.limits[2].severity, .critical)
        XCTAssertEqual(snapshot.limits[2].modelDisplayName, "Fable")
        XCTAssertNotNil(snapshot.limits[2].resetsAt)

        XCTAssertEqual(snapshot.worstPercent, 95)
        XCTAssertEqual(snapshot.worstSeverity, .critical)

        XCTAssertEqual(snapshot.spend?.usedFormatted, "$728.60")
        XCTAssertEqual(snapshot.spend?.limitFormatted, "$800.00")
    }

    func testFixtureTeamNoSpend() throws {
        let data = try loadFixtureData("usage_team_no_spend")
        let snapshot = try UsageSnapshot.decode(data, fetchedAt: fixtureFetchedAt)

        XCTAssertEqual(snapshot.limits.count, 3)
        XCTAssertEqual(snapshot.worstPercent, 13)

        XCTAssertNil(snapshot.spend?.limitMinor)
        XCTAssertEqual(snapshot.spend?.isAlertable, false)
    }
}

// MARK: - 2. Tolerant decoding

final class TolerantDecodingTests: XCTestCase {
    func testFallbackWindowsWhenLimitsArrayRemoved() throws {
        let data = try loadFixtureData("usage_with_spend")
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict.removeValue(forKey: "limits")
        let strippedData = try JSONSerialization.data(withJSONObject: dict)

        let snapshot = try UsageSnapshot.decode(strippedData, fetchedAt: fixtureFetchedAt)

        XCTAssertFalse(snapshot.limits.isEmpty)
        XCTAssertTrue(snapshot.limits.contains { $0.kind == "five_hour" })
    }

    func testUtilizationClampsTo100() throws {
        let json: [String: Any] = ["five_hour": ["utilization": 150, "resets_at": NSNull()]]
        let data = try JSONSerialization.data(withJSONObject: json)

        let snapshot = try UsageSnapshot.decode(data)

        XCTAssertEqual(snapshot.limits.first?.percent, 100)
    }

    func testWindowWithPastResetsAtIsNulled() throws {
        let json: [String: Any] = ["five_hour": ["utilization": 10, "resets_at": "2000-01-01T00:00:00.000000+00:00"]]
        let data = try JSONSerialization.data(withJSONObject: json)

        let snapshot = try UsageSnapshot.decode(data)   // fetchedAt defaults to now, well after 2000

        XCTAssertNil(snapshot.limits.first?.resetsAt)
    }
}

// MARK: - 3. Derivation

final class DerivationTests: XCTestCase {
    func testDefaultClaudeDirUsesUnsuffixedService() {
        XCTAssertEqual(
            KeychainService.serviceName(forConfigDir: "/Users/roypadina/.claude", home: "/Users/roypadina"),
            "Claude Code-credentials")
    }

    func testVerifiedHashedDir() {
        // Verified live 2026-08-10: sha256("/Users/roypadina/.claude-work2")[0..8] == "e5af6df1".
        XCTAssertEqual(
            KeychainService.serviceName(forConfigDir: "/Users/roypadina/.claude-work2", home: "/Users/roypadina"),
            "Claude Code-credentials-e5af6df1")
    }

    func testTrailingSlashNormalizationOnHashedDir() {
        XCTAssertEqual(
            KeychainService.serviceName(forConfigDir: "/Users/roypadina/.claude-work2/", home: "/Users/roypadina"),
            "Claude Code-credentials-e5af6df1")
    }

    func testTrailingSlashNormalizationOnDefaultDir() {
        XCTAssertEqual(
            KeychainService.serviceName(forConfigDir: "/Users/roypadina/.claude/", home: "/Users/roypadina"),
            "Claude Code-credentials")
    }
}

// MARK: - 4. AlertEngine

final class AlertEngineTests: XCTestCase {
    private func account() -> Account {
        Account(name: "Test Account", kind: .local(configDirPath: "/tmp/does-not-matter"))
    }

    private func snapshot(percent: Int, severity: Severity, resetsAt: Date?) -> AccountState {
        let limit = LimitInfo(kind: "session", group: "session", percent: percent, severity: severity,
                               resetsAt: resetsAt, modelDisplayName: nil, isActive: true)
        return .ok(UsageSnapshot(limits: [limit], spend: nil))
    }

    func testLimitTransitionSequence() {
        var engine = AlertEngine()   // default thresholds: warning 80, critical 95
        let acct = account()
        let windowA = Date(timeIntervalSince1970: 1_000_000)
        let windowB = Date(timeIntervalSince1970: 2_000_000)

        XCTAssertEqual(engine.evaluate(account: acct, state: snapshot(percent: 10, severity: .normal, resetsAt: windowA)).count, 0, "normal -> no alert")
        XCTAssertEqual(engine.evaluate(account: acct, state: snapshot(percent: 85, severity: .normal, resetsAt: windowA)).count, 1, "rise to warning")
        XCTAssertEqual(engine.evaluate(account: acct, state: snapshot(percent: 85, severity: .normal, resetsAt: windowA)).count, 0, "repeat")
        XCTAssertEqual(engine.evaluate(account: acct, state: snapshot(percent: 97, severity: .normal, resetsAt: windowA)).count, 1, "rise to critical")
        XCTAssertEqual(engine.evaluate(account: acct, state: snapshot(percent: 10, severity: .normal, resetsAt: windowA)).count, 0, "drop re-arms, no fire on the drop itself")
        XCTAssertEqual(engine.evaluate(account: acct, state: snapshot(percent: 85, severity: .normal, resetsAt: windowA)).count, 1, "rise again after re-arm")
        XCTAssertEqual(engine.evaluate(account: acct, state: snapshot(percent: 85, severity: .normal, resetsAt: windowB)).count, 1, "window roll at same level")
    }

    /// Regression: the server recomputes `resets_at` per request (±1s jitter). Exact Date
    /// equality treated every poll as a window roll — 351 phone pushes in 12h.
    func testWindowJitterDoesNotReAlert() {
        var engine = AlertEngine()
        let acct = account()
        let base = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(engine.evaluate(account: acct, state: snapshot(percent: 85, severity: .warning, resetsAt: base)).count, 1, "first crossing fires")
        for jitter in [0.4, -0.9, 1.1, -1.8, 60.0] {
            XCTAssertEqual(engine.evaluate(account: acct, state: snapshot(percent: 85, severity: .warning, resetsAt: base.addingTimeInterval(jitter))).count, 0,
                           "jitter \(jitter)s must not re-alert")
        }
        // Drift can't accumulate: first-seen window date is kept while the window is unchanged.
        var walked = base
        for _ in 0..<200 {
            walked = walked.addingTimeInterval(1.0)   // +200s total, far past tolerance
            _ = engine.evaluate(account: acct, state: snapshot(percent: 85, severity: .warning, resetsAt: base.addingTimeInterval(60)))
        }
        XCTAssertEqual(engine.evaluate(account: acct, state: snapshot(percent: 85, severity: .warning, resetsAt: base.addingTimeInterval(60))).count, 0)

        // A REAL roll (7 days later) at the same level fires exactly once.
        let rolled = base.addingTimeInterval(7 * 24 * 3600)
        XCTAssertEqual(engine.evaluate(account: acct, state: snapshot(percent: 85, severity: .warning, resetsAt: rolled)).count, 1, "true window roll fires")
        XCTAssertEqual(engine.evaluate(account: acct, state: snapshot(percent: 85, severity: .warning, resetsAt: rolled.addingTimeInterval(0.5))).count, 0)
    }

    func testMemoryPersistsAcrossRelaunch() {
        var engine = AlertEngine()
        let acct = account()
        let window = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(engine.evaluate(account: acct, state: snapshot(percent: 97, severity: .critical, resetsAt: window)).count, 1)

        // "Relaunch": new engine restored from the snapshot must stay silent on the same state.
        var reborn = AlertEngine()
        reborn.restoreMemory(from: engine.memorySnapshot!)
        XCTAssertEqual(reborn.evaluate(account: acct, state: snapshot(percent: 97, severity: .critical, resetsAt: window.addingTimeInterval(1))).count, 0,
                       "restored memory suppresses the relaunch burst")
        // But a fresh engine with NO memory would have fired — proving the restore did the work.
        var fresh = AlertEngine()
        XCTAssertEqual(fresh.evaluate(account: acct, state: snapshot(percent: 97, severity: .critical, resetsAt: window)).count, 1)
    }

    func testAuthAlertDebouncesOneStrikeFiresOnSecond() {
        var engine = AlertEngine()
        let acct = account()

        // Single 401 poll = probably token rotation — no alert. Second consecutive = real.
        XCTAssertEqual(engine.evaluate(account: acct, state: .needsReauth).count, 0, "first strike debounced")
        XCTAssertEqual(engine.evaluate(account: acct, state: .needsReauth).count, 1, "second strike fires")
        XCTAssertEqual(engine.evaluate(account: acct, state: .needsReauth).count, 0, "then de-duped")
        _ = engine.evaluate(account: acct, state: snapshot(percent: 10, severity: .normal, resetsAt: Date()))
        XCTAssertEqual(engine.evaluate(account: acct, state: .needsReauth).count, 0, "recovery resets strikes — first strike silent again")
        XCTAssertEqual(engine.evaluate(account: acct, state: .needsReauth).count, 1, "re-fires on second strike after recovery")
    }

    func testNeedsCredentialsRepasteFiresOnceUnderAuthKey() {
        var engine = AlertEngine()
        let acct = account()

        XCTAssertEqual(engine.evaluate(account: acct, state: .needsCredentialsRepaste).count, 0, "first strike debounced")
        let second = engine.evaluate(account: acct, state: .needsCredentialsRepaste)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.key, "auth")
        XCTAssertEqual(engine.evaluate(account: acct, state: .needsCredentialsRepaste).count, 0, "then de-duped")
    }

    func testApiCriticalOverridesLowPercentThreshold() {
        var engine = AlertEngine()
        let acct = account()

        let alerts = engine.evaluate(account: acct, state: snapshot(percent: 10, severity: .critical, resetsAt: Date()))

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.level, .critical)
    }

    func testSpendWithNilLimitNeverAlerts() {
        var engine = AlertEngine()
        let acct = account()
        let spend = SpendInfo(usedMinor: 100, limitMinor: nil, exponent: 2, currency: "USD",
                               percent: 0, severity: .normal, enabled: true)
        let snap = UsageSnapshot(limits: [], spend: spend)

        XCTAssertEqual(engine.evaluate(account: acct, state: .ok(snap)).count, 0)
    }
}

// MARK: - 5. Credentials

final class CredentialsTests: XCTestCase {
    func testExpiresAtAcceptsBothMillisecondsAndSeconds() {
        let seconds = Date().timeIntervalSince1970 + 3600
        let milliseconds = seconds * 1000

        XCTAssertEqual(CredentialStore.expiresAtSeconds(rawExpiresAt: milliseconds), seconds, accuracy: 0.001)
        XCTAssertEqual(CredentialStore.expiresAtSeconds(rawExpiresAt: seconds), seconds, accuracy: 0.001)
    }

    func testMergeCredentialsPreservesUnknownKeysAndWritesMillisecondExpiry() throws {
        let original: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": "old-access",
                "refreshToken": "old-refresh",
                "expiresAt": 1_000,
                "subscriptionType": "max",
                "scopes": ["user:inference"],
            ] as [String: Any],
        ]
        let originalData = try JSONSerialization.data(withJSONObject: original)
        let refreshed = CredentialStore.RefreshResponse(access_token: "new-access", refresh_token: "new-refresh",
                                                          expires_in: 3600, token_type: "Bearer")
        let now = Date()

        let mergedData = try XCTUnwrap(CredentialStore.mergeCredentials(cliJSON: originalData, refreshed: refreshed, now: now))

        XCTAssertFalse(String(data: mergedData, encoding: .utf8)?.contains("\n") ?? true, "emits no newline")

        let mergedRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: mergedData) as? [String: Any])
        let oauth = try XCTUnwrap(mergedRoot["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["accessToken"] as? String, "new-access")
        XCTAssertEqual(oauth["refreshToken"] as? String, "new-refresh")
        XCTAssertEqual(oauth["subscriptionType"] as? String, "max", "preserves unknown claudeAiOauth keys")
        XCTAssertEqual(oauth["scopes"] as? [String], ["user:inference"], "preserves unknown claudeAiOauth keys")

        let expectedExpiresAtMs = Int64(now.timeIntervalSince1970 * 1000) + Int64(3600 * 1000)
        XCTAssertEqual((oauth["expiresAt"] as? NSNumber)?.int64Value, expectedExpiresAtMs)
    }

    func testBackoffLadderWalksAndResetsOnSuccess() {
        var ladder = BackoffLadder()

        XCTAssertEqual(ladder.advance(), 3 * 60)
        XCTAssertEqual(ladder.advance(), 6 * 60)
        XCTAssertEqual(ladder.advance(), 12 * 60)
        XCTAssertEqual(ladder.advance(), 15 * 60)
        XCTAssertEqual(ladder.advance(), 15 * 60, "holds at the top rung")

        ladder.reset()
        XCTAssertEqual(ladder.advance(), 3 * 60, "any 2xx resets to rung 0")
    }
}
