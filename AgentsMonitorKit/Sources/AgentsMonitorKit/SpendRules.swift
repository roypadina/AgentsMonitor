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
