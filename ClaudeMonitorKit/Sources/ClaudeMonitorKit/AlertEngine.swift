import Foundation
import os

public struct AlertThresholds: Codable, Equatable, Sendable {
    public var warning: Int = 80
    public var critical: Int = 95

    public init(warning: Int = 80, critical: Int = 95) {
        self.warning = warning
        self.critical = critical
    }
}

public enum AlertLevel: Int, Comparable, Codable, Sendable {
    case none = 0, warning = 1, critical = 2

    public static func < (lhs: AlertLevel, rhs: AlertLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct Alert: Equatable, Sendable {
    public let accountId: UUID
    public let accountName: String
    public let key: String        // LimitInfo.id, or "auth"
    public let title: String
    public let body: String
    public let level: AlertLevel

    // Explicit public init: a `public struct` only gets an `internal` synthesized memberwise
    // init by default, which blocks the app target from constructing a synthetic test alert.
    public init(accountId: UUID, accountName: String, key: String, title: String, body: String, level: AlertLevel) {
        self.accountId = accountId
        self.accountName = accountName
        self.key = key
        self.title = title
        self.body = body
        self.level = level
    }
}

public struct AlertEngine {
    public var thresholds: AlertThresholds

    /// The server recomputes `resets_at` on every request — the same logical window jitters by
    /// up to ~2s between polls (observed live: `19:00:00.399` vs `18:59:59.399`). Windows are
    /// hours long, so anything closer than this is the SAME window, not a roll.
    /// (Bug history: exact `Date` equality here caused a re-alert on every 3-minute poll — 351
    /// phone pushes in 12h.)
    public static let windowTolerance: TimeInterval = 120

    /// De-dupe/re-arm memory, keyed `"<accountId>|<limitKey>"`. Codable so it survives relaunch.
    public struct MemoryEntry: Codable, Equatable, Sendable {
        public var level: AlertLevel
        public var window: Date?
    }
    private var memory: [String: MemoryEntry] = [:]

    /// Consecutive auth-failure polls per account. Deliberately NOT persisted — a single 401 is
    /// usually Claude Code rotating its token mid-poll (observed live 2026-08-11), so the alert
    /// only fires on the second consecutive strike.
    private var authStrikes: [String: Int] = [:]

    private static let log = Logger(subsystem: "com.roy.claudemonitor", category: "alerts")

    public init(thresholds: AlertThresholds = .init()) {
        self.thresholds = thresholds
    }

    /// Persistence hooks — AppStore snapshots this across relaunches so an already-alerted
    /// critical doesn't re-fire every time the app starts.
    public var memorySnapshot: Data? {
        try? JSONEncoder().encode(memory)
    }

    public mutating func restoreMemory(from data: Data) {
        if let restored = try? JSONDecoder().decode([String: MemoryEntry].self, from: data) {
            memory = restored
        }
    }

    /// Mutates internal de-dupe memory. Pure w.r.t. everything else.
    public mutating func evaluate(account: Account, state: AccountState, now: Date = Date()) -> [Alert] {
        switch state {
        case .ok(let snapshot), .stale(let snapshot, _):
            var candidates = snapshot.limits
            if let spendLimit = snapshot.spend?.asLimitInfo { candidates.append(spendLimit) }
            let alerts = candidates.compactMap { evaluateLimit(account: account, limit: $0) }
            clearAuthEntry(accountId: account.id)
            return alerts

        case .needsReauth:
            return authAlert(account: account,
                              title: "Login token expired",
                              body: "\(account.name)'s token keeps failing — open a Claude Code session for it (only /login if that doesn't fix it).")

        case .needsCredentialsRepaste:
            return authAlert(account: account,
                              title: "Credentials expired",
                              body: "\(account.name)'s remote credentials could not be refreshed — paste fresh ones.")

        case .idle, .notLoggedIn, .keychainDenied, .rateLimited, .failed:
            return []
        }
    }

    public mutating func reset() {
        memory.removeAll()
        authStrikes.removeAll()
    }

    private mutating func evaluateLimit(account: Account, limit: LimitInfo) -> Alert? {
        let key = "\(account.id)|\(limit.id)"
        let newLevel = max(Self.severityLevel(limit.severity), Self.thresholdLevel(percent: limit.percent, thresholds: thresholds))
        let stored = memory[key]
        let sameWindow = Self.isSameWindow(stored?.window, limit.resetsAt)
        let shouldFire = newLevel > (stored?.level ?? .none) || (!sameWindow && stored != nil && newLevel > .none)
        // Keep the first-seen date while the window is unchanged, so per-poll jitter can never
        // random-walk past the tolerance.
        let windowToStore = (sameWindow && stored != nil) ? stored?.window : limit.resetsAt
        memory[key] = MemoryEntry(level: newLevel, window: windowToStore)
        if !sameWindow || shouldFire {
            Self.log.info("eval \(account.name, privacy: .public)/\(limit.id, privacy: .public): \(limit.percent)% level=\(newLevel.rawValue) stored=\(stored?.level.rawValue ?? -1) sameWindow=\(sameWindow) fire=\(shouldFire)")
        }
        guard shouldFire else { return nil }
        return Alert(accountId: account.id, accountName: account.name, key: limit.id,
                      title: "\(account.name) — \(limit.label)",
                      body: "\(limit.percent)% used",
                      level: newLevel)
    }

    /// Same logical window iff both absent, or both present within `windowTolerance`.
    static func isSameWindow(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let a?, let b?): return abs(a.timeIntervalSince(b)) < windowTolerance
        default: return false
        }
    }

    private mutating func authAlert(account: Account, title: String, body: String) -> [Alert] {
        let memKey = "\(account.id)|auth"
        let strikes = (authStrikes[memKey] ?? 0) + 1
        authStrikes[memKey] = strikes
        guard strikes >= 2 else {
            Self.log.info("auth strike 1 for \(account.name, privacy: .public) — debouncing (likely token rotation)")
            return []
        }
        let stored = memory[memKey]
        let shouldFire = AlertLevel.critical > (stored?.level ?? .none)
        memory[memKey] = MemoryEntry(level: .critical, window: nil)
        guard shouldFire else { return [] }
        return [Alert(accountId: account.id, accountName: account.name, key: "auth", title: title, body: body, level: .critical)]
    }

    private mutating func clearAuthEntry(accountId: UUID) {
        memory["\(accountId)|auth"] = nil
        authStrikes["\(accountId)|auth"] = nil
    }

    private static func severityLevel(_ severity: Severity) -> AlertLevel {
        switch severity {
        case .normal: return .none
        case .warning: return .warning
        case .critical: return .critical
        }
    }

    private static func thresholdLevel(percent: Int, thresholds: AlertThresholds) -> AlertLevel {
        if percent >= thresholds.critical { return .critical }
        if percent >= thresholds.warning { return .warning }
        return .none
    }
}
