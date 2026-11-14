import Foundation

/// Ko-fi ask bookkeeping (UserDefaults → `AgentsMonitor.supportPrompt`). The rules live here, pure, so
/// tests can drive them with any clock and version. The card itself is the app's SupportPrompt.swift.
public struct SupportPromptState: Codable, Equatable, Sendable {
    public enum Answer: Sendable { case support, snooze, never }

    public var shownAt: [Date] = []  // asks in the last 365 days (older ones are dropped)
    public var snoozedUntil: Date?
    public var neverVersion: String?  // app version when the user said "Nope, don't ask again"
    public var neverAt: Date?
    public var supportedAt: Date?

    public static let day: TimeInterval = 24 * 3600
    /// Default polling (every 5 min) on a Mac awake ~8 h a day makes ~100 usage checks a day: ≈ 3 weeks.
    public static let usageChecksNeeded = 2000

    public init() {}

    // Tolerant decode, same reasoning as Settings: a missing key must not wipe the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shownAt = try c.decodeIfPresent([Date].self, forKey: .shownAt) ?? []
        snoozedUntil = try c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        neverVersion = try c.decodeIfPresent(String.self, forKey: .neverVersion)
        neverAt = try c.decodeIfPresent(Date.self, forKey: .neverAt)
        supportedAt = try c.decodeIfPresent(Date.self, forKey: .supportedAt)
    }

    /// First ask: ≥ 7 days installed and more than `usageChecksNeeded` usage checks. Then: snooze = 14 days,
    /// support = 180 days quiet, "never" = until the next major version AND ≥ 90 days, max 3 asks / 365 days.
    public func mayAsk(now: Date, installDate: Date, usageChecks: Int, appVersion: String) -> Bool {
        guard now >= installDate.addingTimeInterval(7 * Self.day), usageChecks > Self.usageChecksNeeded else { return false }
        if let snoozedUntil, now < snoozedUntil { return false }
        if let supportedAt, now < supportedAt.addingTimeInterval(180 * Self.day) { return false }
        if let neverAt, let neverVersion,
           Self.major(appVersion) <= Self.major(neverVersion) || now < neverAt.addingTimeInterval(90 * Self.day) {
            return false
        }
        return shownAt.filter { $0 > now.addingTimeInterval(-365 * Self.day) }.count < 3
    }

    public mutating func recordShown(_ now: Date) {
        shownAt = shownAt.filter { $0 > now.addingTimeInterval(-365 * Self.day) } + [now]
    }

    public mutating func record(_ answer: Answer, now: Date, appVersion: String) {
        switch answer {
        case .support: supportedAt = now
        case .snooze: snoozedUntil = now.addingTimeInterval(14 * Self.day)
        case .never: neverVersion = appVersion; neverAt = now
        }
    }

    static func major(_ version: String) -> Int { Int(version.split(separator: ".").first ?? "") ?? 0 }
}
