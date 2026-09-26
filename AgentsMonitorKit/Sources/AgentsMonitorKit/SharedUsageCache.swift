import Foundation

/// One usage-endpoint read per Claude account, shared with every other local tool that polls
/// the same account (e.g. a `claude-usage` script run by several terminal sessions). The endpoint
/// rate-limits per account and each extra caller lengthens the 429 window, so readers agree on
/// one file per config dir:
///
///     ~/.cache/claude-pool/<config-dir-name>.usage.json
///     {"fetched_at": <epoch s>, "body": "<raw 200 response>" | null, "throttled_until": <epoch s>}
///
/// A body younger than `minAge` is reused instead of fetched; a 429 parks every reader until
/// `Retry-After` has passed. Any tool writing this file must keep the same format.
enum SharedUsageCache {
    static let minAge: TimeInterval = 180
    static let defaultRetryAfter: TimeInterval = 900
    static let lockStale: TimeInterval = 30

    struct Entry: Codable, Equatable {
        var fetched_at: Double?
        var body: String?
        var throttled_until: Double?
    }

    enum Decision: Equatable {
        case use(String)      // cached body is good enough
        case throttled        // parked by a 429 and nothing cached
        case fetch
    }

    static func directory(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".cache/claude-pool", isDirectory: true)
    }

    static func file(configDir: String, in dir: URL = directory()) -> URL {
        let name = URL(fileURLWithPath: configDir).standardizedFileURL.lastPathComponent
        return dir.appendingPathComponent("\(name).usage.json")
    }

    static func decide(_ entry: Entry?, now: Date = Date()) -> Decision {
        let t = now.timeIntervalSince1970
        let body = entry?.body
        if t < (entry?.throttled_until ?? 0) {
            return body.map(Decision.use) ?? .throttled
        }
        if let body, t - (entry?.fetched_at ?? 0) < minAge {
            return .use(body)
        }
        return .fetch
    }

    static func read(_ url: URL) -> Entry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    static func write(_ entry: Entry, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        let tmp = url.appendingPathExtension("\(ProcessInfo.processInfo.processIdentifier)")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(tmp.path, url.path) != 0 { try? fm.removeItem(at: tmp) }   // atomic for readers
    }

    /// `mkdir` as a cross-process lock (same as the shell/Python side). A lock older than
    /// `lockStale` belongs to a reader that died mid-request and is broken.
    static func tryLock(_ url: URL, now: Date = Date()) -> Bool {
        let lock = lockURL(url)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? fm.createDirectory(at: lock, withIntermediateDirectories: false)) != nil { return true }
        if let made = (try? fm.attributesOfItem(atPath: lock.path))?[.modificationDate] as? Date,
           now.timeIntervalSince(made) > lockStale {
            try? fm.removeItem(at: lock)
            return (try? fm.createDirectory(at: lock, withIntermediateDirectories: false)) != nil
        }
        return false
    }

    static func unlock(_ url: URL) {
        try? FileManager.default.removeItem(at: lockURL(url))
    }

    private static func lockURL(_ url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("lock")
    }
}
