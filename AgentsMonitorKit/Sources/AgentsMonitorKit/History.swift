import Foundation

// MARK: - Usage samples

/// One account's numbers at one poll — the raw material of the usage graphs.
public struct UsageSample: Codable, Sendable, Hashable {
    public let t: Double                 // epoch seconds
    public let id: UUID                  // Account.id
    public let p: [String: Int]          // LimitInfo.label -> percent: "Session", "Week", "Week · Fable"
    public let spend: Int?               // extra usage used so far, minor units
    public let r: [String: Double]?      // LimitInfo.label -> resets at, epoch seconds (1.7.2+)

    public var date: Date { Date(timeIntervalSince1970: t) }

    /// Keyed by label rather than kind, so a limit the server adds later is recorded and drawn
    /// with no code change.
    public init(account: UUID, snapshot: UsageSnapshot, at date: Date = Date()) {
        t = date.timeIntervalSince1970
        id = account
        p = snapshot.limits.reduce(into: [:]) { $0[$1.label] = $1.percent }
        spend = snapshot.spend.flatMap { $0.enabled ? $0.usedMinor : nil }
        let resets = snapshot.limits.reduce(into: [String: Double]()) { $0[$1.label] = $1.resetsAt?.timeIntervalSince1970 }
        r = resets.isEmpty ? nil : resets
    }
}

extension UsageSnapshot {
    /// A sample turned back into rows. It keeps percentages and (since 1.7.2) reset times, so
    /// spend is unknown and severity is graded locally, as for Codex.
    init(sample: UsageSample) {
        func kindAndModel(_ label: String) -> (String, String?) {
            switch label {
            case "Session": return ("session", nil)
            case "Week": return ("weekly_all", nil)
            case let l where l.hasPrefix("Week · "): return ("weekly_scoped", String(l.dropFirst("Week · ".count)))
            default: return (label.lowercased().replacingOccurrences(of: " ", with: "_"), nil)
            }
        }
        let order = ["session": 0, "weekly_all": 1, "weekly_scoped": 2]
        let limits = sample.p.map { label, percent -> LimitInfo in
            let (kind, model) = kindAndModel(label)
            return LimitInfo(kind: kind, group: nil, percent: percent,
                             severity: UsageSnapshot.codexSeverity(percent: percent),
                             resetsAt: sample.r?[label].map(Date.init(timeIntervalSince1970:)),
                             modelDisplayName: model, isActive: true)
        }.sorted { (order[$0.kind] ?? 3, $0.label) < (order[$1.kind] ?? 3, $1.label) }
        self.init(limits: limits, spend: nil, fetchedAt: sample.date)
    }
}

/// Append-only JSON lines, one `UsageSample` per line:
///
///     ~/Library/Application Support/AgentsMonitor/history.jsonl
///
/// About 150 bytes per account per poll; lines older than `keepDays` are dropped at launch.
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
