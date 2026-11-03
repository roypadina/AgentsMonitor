import XCTest
@testable import AgentsMonitorKit

@MainActor
final class OpenRouterStoreTests: XCTestCase {
    private func limits(_ session: Int, _ week: Int) -> UsageSnapshot {
        UsageSnapshot(limits: [
            LimitInfo(kind: "session", group: nil, percent: session, severity: .normal, resetsAt: nil,
                      modelDisplayName: nil, isActive: true),
            LimitInfo(kind: "weekly_all", group: nil, percent: week, severity: .normal, resetsAt: nil,
                      modelDisplayName: nil, isActive: true),
        ], spend: nil)
    }

    /// Accounts "claude"… with the given (session, week); keys and usages in config order.
    private func store(accounts: [(String, Int, Int)], keys: [OpenRouterKeyConfig],
                       usages: [OpenRouterKeyUsage], balance: OpenRouterBalance? = nil) -> AppStore {
        let store = AppStore()
        store.accounts = accounts.map { Account(name: $0.0, kind: .local(configDirPath: "/tmp/\($0.0)")) }
        for (account, values) in zip(store.accounts, accounts) {
            store.states[account.id] = .ok(limits(values.1, values.2))
        }
        store.openRouterKeys = keys
        store.setOpenRouterStateForTesting(.ok(OpenRouterSnapshot(keys: usages, balance: balance)))
        return store
    }

    private let capped = OpenRouterKeyUsage(id: "hash-a", label: "sk-or-v1-aaa...111", limit: 20, limitRemaining: 8,
                                            usage: 50, usageDaily: 3.2)
    private let plain = OpenRouterKeyUsage(id: "hash-b", label: "sk-or-v1-bbb...222", usage: 9, usageDaily: 0.41)

    // MARK: Menu bar

    func testMenuBarTextOrderWithTwoAccountsTwoKeysAndBalance() {
        let s = store(accounts: [("claude", 52, 10), ("claude2", 12, 5)],
                      keys: [OpenRouterKeyConfig(id: "hash-a", source: .managed, nickname: "prod-agent", placement: .menuBar),
                             OpenRouterKeyConfig(id: "hash-b", source: .managed, nickname: "research", placement: .menuBar)],
                      usages: [capped, plain], balance: OpenRouterBalance(totalCredits: 50, totalUsage: 8))
        s.settings.openRouter.balancePlacement = .menuBar
        XCTAssertEqual(s.menuBarText, "c 52% · c2 12% · o1 60% · o2 $0.41 · $42")
    }

    func testOneAccountAndOneKeyKeepTags() {
        let s = store(accounts: [("claude", 52, 10)],
                      keys: [OpenRouterKeyConfig(id: "hash-a", source: .managed, nickname: "agent1", placement: .menuBar)],
                      usages: [capped])
        XCTAssertEqual(s.menuBarText, "c 52% · o1 60%")
    }

    func testSingleKeyDropsItsTag() {
        let s = store(accounts: [],
                      keys: [OpenRouterKeyConfig(id: "hash-a", source: .managed, nickname: "agent1", placement: .menuBar)],
                      usages: [capped])
        XCTAssertEqual(s.menuBarText, "60%")
    }

    func testKeySegments() {
        let s = store(accounts: [],
                      keys: [OpenRouterKeyConfig(id: "hash-a", source: .managed, placement: .menuBar),
                             OpenRouterKeyConfig(id: "hash-b", source: .managed, placement: .menuBar),
                             OpenRouterKeyConfig(id: "hash-c", source: .managed, placement: .popover)],
                      usages: [capped, OpenRouterKeyUsage(id: "hash-b", label: "x", usageDaily: 3.2),
                               OpenRouterKeyUsage(id: "hash-c", label: "y", usageDaily: 1)])
        let segments = s.menuBarSegments
        XCTAssertEqual(segments.map(\.id), ["hash-a", "hash-b"], "popover keys yield no segment")
        XCTAssertEqual(segments[0].dotPercent, capped.capPercent)
        XCTAssertTrue(segments[0].showDot)
        XCTAssertFalse(segments[1].showDot, "no cap and no rule: no line, no dot")
        XCTAssertEqual(segments[1].text, "$3.20")
    }

    func testNothingConfiguredLeavesMenuBarAsBefore() async {
        let s = store(accounts: [("claude", 52, 10)], keys: [], usages: [])
        s.applyOpenRouter(nil, now: Date())
        XCTAssertEqual(s.openRouterState, .idle)
        XCTAssertEqual(s.menuBarText, "52%")
        let fetch = await AppStore.fetchOpenRouter(configs: [], managementKeyConfigured: false, client: OpenRouterClient())
        XCTAssertNil(fetch, "nothing configured: no network")
    }

    func testTagsCollide() {
        let keys = [OpenRouterKeyConfig(id: "a", source: .managed, nickname: "prod"),
                    OpenRouterKeyConfig(id: "b", source: .managed, nickname: "research")]
        XCTAssertEqual(AppStore.openRouterTags(for: keys), ["a": "o1", "b": "o2"])
        let distinct = [OpenRouterKeyConfig(id: "a", source: .managed, nickname: "box2"),
                        OpenRouterKeyConfig(id: "b", source: .managed, nickname: "research")]
        XCTAssertEqual(AppStore.openRouterTags(for: distinct), ["a": "o2", "b": "o"])
    }

    // MARK: Percent

    func testOpenRouterPercent() {
        let s = store(accounts: [], keys: [], usages: [capped, OpenRouterKeyUsage(id: "hash-b", label: "x", usageDaily: 3)])
        XCTAssertEqual(s.openRouterPercent(for: "hash-a"), 60, "cap wins")
        XCTAssertNil(s.openRouterPercent(for: "hash-b"), "no cap, no rule")
        s.spendRules = [SpendRule(kind: .spend, scope: .allKeys, window: .utcDay, threshold: 1)]
        XCTAssertNil(s.openRouterPercent(for: "hash-b"), "an all-keys rule is a line on the total, not on this key")
        s.spendRules.append(SpendRule(kind: .spend, scope: .eachKey, window: .utcDay, threshold: 4))
        XCTAssertEqual(s.openRouterPercent(for: "hash-b"), 75)
        s.spendRules.append(SpendRule(kind: .spend, scope: .key("hash-b"), window: .utcDay, threshold: 2))
        XCTAssertEqual(s.openRouterPercent(for: "hash-b"), 100, "highest ratio, clamped")
        s.spendRules = s.spendRules.map { var r = $0; r.enabled = false; return r }
        XCTAssertNil(s.openRouterPercent(for: "hash-b"))
    }

    // MARK: Placement lists

    func testPlacementLists() {
        let s = AppStore()
        s.accounts = Placement.allCases.map { Account(name: $0.rawValue, kind: .remote, placement: $0) }
        s.openRouterKeys = Placement.allCases.map { OpenRouterKeyConfig(id: $0.rawValue, source: .managed, placement: $0) }
        XCTAssertEqual(s.popoverAccounts.map(\.name), ["menuBar", "popover"])
        XCTAssertEqual(s.moreAccounts.map(\.name), ["more"])
        XCTAssertEqual(s.popoverKeys.map(\.id), ["menuBar", "popover"])
        XCTAssertEqual(s.moreKeys.map(\.id), ["menuBar", "popover", "more"])
        XCTAssertEqual(s.hiddenKeyCount, 1)
        XCTAssertTrue(s.showsMoreEntry)

        let empty = AppStore()
        empty.accounts = [Account(name: "a", kind: .remote)]
        XCTAssertFalse(empty.openRouterConfigured)
        XCTAssertFalse(empty.showsMoreEntry)
    }

    // MARK: Merge, history, state

    func testMergedConfigs() {
        let pasted = OpenRouterKeyConfig(id: OpenRouter.pastedId(UUID()), source: .pasted, nickname: "laptop")
        let existing = [OpenRouterKeyConfig(id: "h1", source: .managed, nickname: "one", placement: .menuBar),
                        OpenRouterKeyConfig(id: "h2", source: .managed),
                        pasted]
        XCTAssertEqual(AppStore.mergedConfigs(existing, listing: nil), existing, "failed listing changes nothing")

        let merged = AppStore.mergedConfigs(existing, listing: [
            OpenRouterKeyUsage(id: "h1", name: "renamed", label: "sk-or-v1-aaa...111"),
            OpenRouterKeyUsage(id: "h3", name: "three", label: "sk-or-v1-ccc...333"),
        ])
        XCTAssertEqual(merged.map(\.id), ["h1", pasted.id, "h3"], "h2 gone, pasted kept, h3 appended")
        XCTAssertEqual(merged[0].placement, .menuBar)
        XCTAssertEqual(merged[0].nickname, "one")
        XCTAssertEqual(merged[0].lastName, "renamed")
        XCTAssertEqual(merged[1], pasted)
        XCTAssertEqual(merged[2].placement, .more)
        XCTAssertEqual(merged[2].lastLabel, "sk-or-v1-ccc...333")
    }

    func testShouldSample() {
        let last = OpenRouterSample(t: 1000, id: "k", u: 5)
        let at = { (seconds: Double) in Date(timeIntervalSince1970: 1000 + seconds) }
        XCTAssertTrue(AppStore.shouldSample(last: nil, usage: 5, now: at(0)))
        XCTAssertFalse(AppStore.shouldSample(last: last, usage: 6, now: at(OpenRouterHistory.minGap - 1)))
        XCTAssertTrue(AppStore.shouldSample(last: last, usage: 6, now: at(OpenRouterHistory.minGap)))
        XCTAssertFalse(AppStore.shouldSample(last: last, usage: 5, now: at(OpenRouterHistory.flatGap - 1)))
        XCTAssertTrue(AppStore.shouldSample(last: last, usage: 5, now: at(OpenRouterHistory.flatGap)))
    }

    func testSummary() {
        let snapshot = OpenRouterSnapshot(keys: [capped, plain], balance: OpenRouterBalance(totalCredits: 100, totalUsage: 57.83))
        XCTAssertEqual(AppStore.openRouterSummary(state: .ok(snapshot), keyCount: 14), "balance $42.17 · $3.61 today · 14 keys")
        XCTAssertEqual(AppStore.openRouterSummary(state: .ok(snapshot), keyCount: 1, showBalance: false), "$3.61 today · 1 key")
        XCTAssertEqual(AppStore.openRouterSummary(state: .idle, keyCount: 3), "checking…")
        XCTAssertEqual(AppStore.openRouterSummary(state: .failed("Management key expired — paste a new one in Settings"), keyCount: 3),
                       "management key expired")
        let pastedOnly = OpenRouterSnapshot(keys: [plain], managementError: "That's not a management key — paste a management key in Settings")
        XCTAssertEqual(AppStore.openRouterSummary(state: .stale(pastedOnly, error: "x"), keyCount: 1), "that's not a management key")
        XCTAssertEqual(AppStore.openRouterSummary(state: .ok(OpenRouterSnapshot(keys: [])), keyCount: 0), "no keys yet")
    }

    func testFailedPollKeepsLastNumbers() {
        let last = OpenRouterSnapshot(keys: [plain])
        XCTAssertEqual(AppStore.preservingOpenRouter(.failed("down"), last: last), .stale(last, error: "down"))
        XCTAssertEqual(AppStore.preservingOpenRouter(.failed("down"), last: nil), .failed("down"))
    }

    /// Connect / Add Key during a poll: the forced refresh is queued, and the running poll runs once more.
    func testForcedRefreshDuringPollRunsAgain() async {
        let store = AppStore()   // nothing configured: a poll makes no network call
        store.isRefreshing = true
        await store.refresh()
        XCTAssertFalse(store.refreshPending, "a timer refresh during a poll is dropped")
        await store.refresh(force: true)
        XCTAssertTrue(store.refreshPending)
        XCTAssertNil(store.lastRefresh, "nothing polled while the other poll runs")

        store.isRefreshing = false   // a poll that finds the flag runs again and clears it
        await store.refresh()
        XCTAssertFalse(store.refreshPending)
        XCTAssertFalse(store.isRefreshing)
        XCTAssertNotNil(store.lastRefresh)
    }
}
