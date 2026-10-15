import Foundation

// MARK: - Usage samples

/// One account's numbers at one poll — the raw material of the usage graphs.
public struct UsageSample: Codable, Sendable, Hashable {
    public let t: Double                 // epoch seconds
    public let id: UUID                  // Account.id
    public let p: [String: Int]          // LimitInfo.label -> percent: "Session", "Week", "Week · Fable"
    public let spend: Int?               // extra usage used so far, minor units

    public var date: Date { Date(timeIntervalSince1970: t) }

    /// Keyed by label rather than kind, so a limit the server adds later is recorded and drawn
    /// with no code change.
    public init(account: UUID, snapshot: UsageSnapshot, at date: Date = Date()) {
        t = date.timeIntervalSince1970
        id = account
        p = snapshot.limits.reduce(into: [:]) { $0[$1.label] = $1.percent }
        spend = snapshot.spend.flatMap { $0.enabled ? $0.usedMinor : nil }
    }
}

/// Append-only JSON lines, one `UsageSample` per line:
///
///     ~/Library/Application Support/AgentsMonitor/history.jsonl
///
/// About 100 bytes per account per poll; lines older than `keepDays` are dropped at launch.
public struct UsageHistory: Sendable {
    public static let keepDays = 90
    /// At most one sample per account this often, whatever the poll interval is set to.
    public static let minGap: TimeInterval = 120

    public let url: URL

    public init(url: URL = UsageHistory.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentsMonitor/history.jsonl")
    }

    public func append(_ samples: [UsageSample]) {
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
    public func load(since: Date) -> [UsageSample] {
        jsonLines(UsageSample.self, url: url).filter { $0.t >= since.timeIntervalSince1970 }
    }

    /// Rewrites the file without the samples older than `before`; untouched when none are.
    public func prune(before: Date) {
        let all = jsonLines(UsageSample.self, url: url)
        let kept = all.filter { $0.t >= before.timeIntervalSince1970 }
        guard kept.count < all.count else { return }
        try? Self.encodeLines(kept).write(to: url, options: .atomic)
    }

    private static func encodeLines(_ samples: [UsageSample]) -> Data {
        let encoder = JSONEncoder()
        return samples.reduce(into: Data()) { data, sample in
            guard let line = try? encoder.encode(sample) else { return }
            data.append(line)
            data.append(0x0A)
        }
    }
}

func jsonLines<T: Decodable>(_ type: T.Type, url: URL, decoder: JSONDecoder = JSONDecoder()) -> [T] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    return data.split(separator: 0x0A).compactMap { try? decoder.decode(T.self, from: Data($0)) }
}

// MARK: - ccpool switch log

/// One line of ccpool's switch log, `~/.local/state/claude-pool/events.jsonl`. ccpool is a
/// separate script that moves a Claude Code session to another account at the plan limit; the
/// file exists only where it runs, and without it no switch markers are shown.
public struct PoolEvent: Decodable, Sendable, Hashable, Identifiable {
    public let ts: Date
    public let event: String             // "switch", "park" (no account free), "extra" (none free, paid usage)
    public let session: String
    public let from: String?             // ccpool's account names; map with `dir(of:)`
    public let to: String?
    public let trigger: String?          // "hard", "soft", "asked", "rate_limit", "launch"
    public let reason: String?
    public let accounts: [String: PoolAccount]

    public struct PoolAccount: Decodable, Sendable, Hashable {
        public let dir: String?
        public let session: Double?
        public let week: Double?
        public let fable: Double?
    }

    public var id: String { "\(ts.timeIntervalSince1970)|\(session)|\(event)" }
    /// Every account was at its limit: the session parked, or went on paid extra usage.
    public var noFreeAccount: Bool { event == "park" || event == "extra" }

    /// The config dir ccpool knows `name` by — the key for matching an `Account`.
    public func dir(of name: String?) -> String? {
        name.flatMap { accounts[$0]?.dir }
    }

    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/state/claude-pool/events.jsonl")
    }

    public static func load(url: URL = defaultURL, since: Date) -> [PoolEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return jsonLines(PoolEvent.self, url: url, decoder: decoder).filter { $0.ts >= since }
    }
}

// MARK: - Burn rate

/// When `limit` hits 100% at the pace of the recent samples — nil when it would not before it
/// resets, is not rising, or there is too little history to tell. Pace is the rise over the last
/// fifth of the window (1h of a session, ~33h of a week), counting only samples since the window
/// last reset, and needs at least a twentieth of the window (15 min / ~8h) of data.
public func projectedFull(_ points: [(date: Date, percent: Int)], limit: LimitInfo, now: Date = Date()) -> Date? {
    guard let resetsAt = limit.resetsAt, limit.windowLength > 0, limit.percent < 100 else { return nil }
    let start = max(resetsAt.addingTimeInterval(-limit.windowLength),
                    now.addingTimeInterval(-limit.windowLength / 5))
    let recent = points.filter { $0.date >= start && $0.date <= now }
    guard let first = recent.first, let last = recent.last else { return nil }
    let span = last.date.timeIntervalSince(first.date)
    guard span >= limit.windowLength / 20, last.percent > first.percent else { return nil }
    let perSecond = Double(last.percent - first.percent) / span
    let full = now.addingTimeInterval(Double(100 - limit.percent) / perSecond)
    return full < resetsAt ? full : nil
}
