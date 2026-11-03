import Foundation

// MARK: - Spend windows

public enum SpendWindow: String, Codable, CaseIterable, Sendable {
    case lastHour, last24h, utcDay, utcWeek, utcMonth

    public var label: String {
        switch self {
        case .lastHour: return "Last hour"
        case .last24h: return "Last 24 hours"
        case .utcDay: return "Today (UTC)"
        case .utcWeek: return "This week (UTC)"
        case .utcMonth: return "This month (UTC)"
        }
    }

    public var phrase: String {
        switch self {
        case .lastHour: return "in the last hour"
        case .last24h: return "in the last 24 hours"
        case .utcDay: return "today (UTC)"
        case .utcWeek: return "this week (UTC)"
        case .utcMonth: return "this month (UTC)"
        }
    }

    public var isRolling: Bool { length != nil }

    public var length: TimeInterval? {
        switch self {
        case .lastHour: return 3600
        case .last24h: return 86400
        default: return nil
        }
    }

    /// Rolling: `now - length`. Calendar: the UTC day / Monday-week / month start.
    public func start(now: Date) -> Date {
        if let length { return now.addingTimeInterval(-length) }
        let interval = self == .utcDay ? "daily" : self == .utcWeek ? "weekly" : "monthly"
        return OpenRouter.utcWindowStart(interval, now: now) ?? now
    }
}

public extension OpenRouterKeyUsage {
    /// Calendar windows come straight from OpenRouter; rolling ones need history (nil here).
    func spend(in window: SpendWindow) -> Double? {
        switch window {
        case .utcDay: return usageDaily
        case .utcWeek: return usageWeekly
        case .utcMonth: return usageMonthly
        case .lastHour, .last24h: return nil
        }
    }
}

// MARK: - History

public struct OpenRouterSample: Codable, Sendable, Hashable {
    public let t: Double     // epoch seconds
    public let id: String    // key id
    public let u: Double     // all-time usage USD

    public init(t: Double, id: String, u: Double) {
        self.t = t
        self.id = id
        self.u = u
    }
}

/// Append-only JSON lines of `OpenRouterSample`, a deliberate copy of the `UsageHistory` pattern.
public struct OpenRouterHistory: Sendable {
    public static let keepDays = 3
    public static let minGap: TimeInterval = 120
    public static let flatGap: TimeInterval = 3600   // unchanged `u` is written at most hourly

    public let url: URL

    public init(url: URL = OpenRouterHistory.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentsMonitor/openrouter-history.jsonl")
    }

    public func append(_ samples: [OpenRouterSample]) {
        guard !samples.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Self.encodeLines(samples))
    }

    /// Samples at or after `since`, oldest first. Unreadable lines are skipped.
    public func load(since: Date) -> [OpenRouterSample] {
        jsonLines(OpenRouterSample.self, url: url).filter { $0.t >= since.timeIntervalSince1970 }
    }

    /// Rewrites the file without the samples older than `before`; untouched when none are.
    public func prune(before: Date) {
        let all = jsonLines(OpenRouterSample.self, url: url)
        let kept = all.filter { $0.t >= before.timeIntervalSince1970 }
        guard kept.count < all.count else { return }
        try? Self.encodeLines(kept).write(to: url, options: .atomic)
    }

    private static func encodeLines(_ samples: [OpenRouterSample]) -> Data {
        let encoder = JSONEncoder()
        return samples.reduce(into: Data()) { data, sample in
            guard let line = try? encoder.encode(sample) else { return }
            data.append(line)
            data.append(0x0A)
        }
    }
}

/// Pure. `samples` = one key, oldest first. Baseline = latest sample with t <= since; none -> earliest
/// sample after since (partial window); no samples -> nil. nowUsage < baseline -> (0, false) (counter reset).
public func openRouterSpent(samples: [OpenRouterSample], since: Date, nowUsage: Double) -> (usd: Double, partial: Bool)? {
    let cut = since.timeIntervalSince1970
    let baseline: OpenRouterSample
    let partial: Bool
    if let before = samples.last(where: { $0.t <= cut }) {
        (baseline, partial) = (before, false)
    } else if let after = samples.first {
        (baseline, partial) = (after, true)
    } else {
        return nil
    }
    return nowUsage < baseline.u ? (0, false) : (nowUsage - baseline.u, partial)
}

// MARK: - Rules

public struct SpendRule: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case spend, capRemaining, balance }
    public enum Scope: Codable, Hashable, Sendable { case allKeys, eachKey, key(String) }
    public enum Unit: String, Codable, Sendable { case usd, percent }

    public var id: UUID = UUID()
    public var enabled: Bool = true
    public var kind: Kind = .spend
    public var scope: Scope = .allKeys
    public var window: SpendWindow = .utcDay
    public var unit: Unit = .usd
    public var threshold: Double = 10
    public var level: AlertLevel = .warning

    public init(id: UUID = UUID(), enabled: Bool = true, kind: Kind = .spend, scope: Scope = .allKeys,
                window: SpendWindow = .utcDay, unit: Unit = .usd, threshold: Double = 10,
                level: AlertLevel = .warning) {
        self.id = id
        self.enabled = enabled
        self.kind = kind
        self.scope = scope
        self.window = window
        self.unit = unit
        self.threshold = threshold
        self.level = level
    }

    /// Lenient: a strict throw would drop the user's whole rule list.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .spend
        scope = try c.decodeIfPresent(Scope.self, forKey: .scope) ?? .allKeys
        window = try c.decodeIfPresent(SpendWindow.self, forKey: .window) ?? .utcDay
        unit = try c.decodeIfPresent(Unit.self, forKey: .unit) ?? .usd
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? 10
        level = try c.decodeIfPresent(AlertLevel.self, forKey: .level) ?? .warning
    }

    private var thresholdText: String {
        unit == .percent && kind == .capRemaining ? "\(String(format: "%g", threshold))%" : OpenRouter.formatUSD(threshold)
    }

    /// "All keys · over $20.00 this week (UTC)", "prod-agent · cap below 10% left", "Balance below $10.00".
    public func summary(names: (String) -> String) -> String {
        let who: String
        switch scope {
        case .allKeys: who = "All keys"
        case .eachKey: who = "Each key"
        case .key(let id): who = names(id)
        }
        switch kind {
        case .spend: return "\(who) · over \(OpenRouter.formatUSD(threshold)) \(window.phrase)"
        case .capRemaining: return "\(who) · cap below \(thresholdText) left"
        case .balance: return "Balance below \(OpenRouter.formatUSD(threshold))"
        }
    }
}

// MARK: - Evaluation

extension AlertEngine {
    /// Fire/re-arm per design §10, on the existing memory (`or|<ruleId>|<target>`).
    /// `spent(keyId, window)` supplies rolling values from the store's history; calendar windows come from the key.
    public mutating func evaluateSpendRules(_ rules: [SpendRule], snapshot: OpenRouterSnapshot,
                                            displayName: (String) -> String,
                                            spent: (String, SpendWindow) -> Double?,
                                            now: Date = Date()) -> [Alert] {
        var alerts: [Alert] = []

        // One target's verdict; mutates memory, appends an alert when it fires.
        func check(_ rule: SpendRule, target: String, breached: Bool, windowId: Date?,
                   title: String, body: String) {
            let key = "or|\(rule.id.uuidString)|\(target)"
            let stored = memory[key]
            let fire = breached && (stored == nil || !Self.isSameWindow(stored?.window, windowId) || stored?.level == AlertLevel.none)
            memory[key] = MemoryEntry(level: breached ? rule.level : .none, window: windowId)
            if fire {
                alerts.append(Alert(accountId: OpenRouter.alertAccountId, accountName: "OpenRouter", key: key,
                                    title: title, body: body, level: rule.level))
            }
        }

        let healthy = snapshot.keys.filter { $0.error == nil }
        func scoped(_ scope: SpendRule.Scope) -> [OpenRouterKeyUsage] {
            switch scope {
            case .allKeys, .eachKey: return healthy
            case .key(let id): return healthy.filter { $0.id == id }
            }
        }
        func value(_ key: OpenRouterKeyUsage, _ window: SpendWindow) -> Double? {
            window.isRolling ? spent(key.id, window) : key.spend(in: window)
        }

        for rule in rules where rule.enabled {
            switch rule.kind {
            case .spend:
                let windowId: Date? = rule.window.isRolling ? nil : rule.window.start(now: now)
                func test(_ target: String, _ total: Double, _ name: String) {
                    check(rule, target: target, breached: total >= rule.threshold, windowId: windowId,
                          title: "OpenRouter — \(name)",
                          body: "\(OpenRouter.formatUSD(total)) spent \(rule.window.phrase) · over \(OpenRouter.formatUSD(rule.threshold))")
                }
                if rule.scope == .allKeys {
                    let values = healthy.compactMap { value($0, rule.window) }
                    if !values.isEmpty { test("all", values.reduce(0, +), "all keys") }
                } else {
                    for key in scoped(rule.scope) {
                        if let total = value(key, rule.window) { test(key.id, total, displayName(key.id)) }
                    }
                }

            case .capRemaining:
                // shortcut: "all keys" behaves as "each key"; the editor only offers those two + single keys.
                for key in scoped(rule.scope) {
                    guard let total = key.capTotal, let remaining = key.capRemaining, total > 0 else { continue }
                    let interval = key.limitReset ?? key.budget?.resetInterval
                    let windowId = interval.flatMap { OpenRouter.utcWindowStart($0, now: now) }
                    let percent = remaining / total * 100
                    let (value, left, below) = rule.unit == .percent
                        ? (percent, "\(Int(percent.rounded()))% left", "\(String(format: "%g", rule.threshold))%")
                        : (remaining, "\(OpenRouter.formatUSD(remaining)) of \(OpenRouter.formatUSD(total)) left",
                           OpenRouter.formatUSD(rule.threshold))
                    check(rule, target: key.id, breached: value <= rule.threshold, windowId: windowId,
                          title: "OpenRouter — \(displayName(key.id)) cap", body: "\(left) · below \(below)")
                }

            case .balance:
                guard let balance = snapshot.balance else { continue }
                check(rule, target: "balance", breached: balance.usd <= rule.threshold, windowId: nil,
                      title: "OpenRouter — balance",
                      body: "\(OpenRouter.formatUSD(balance.usd)) left · below \(OpenRouter.formatUSD(rule.threshold))")
            }
        }
        return alerts
    }
}
