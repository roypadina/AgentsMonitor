import Foundation

// MARK: - Severity

public enum Severity: String, Codable, Comparable, Sendable {
    case normal, warning, critical

    private var rank: Int {
        switch self {
        case .normal: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
}

// MARK: - Account

public enum AccountKind: Codable, Hashable, Sendable {
    case local(configDirPath: String)   // credentials owned by Claude Code on this Mac
    case remote                         // pasted by the user, we own them
}

public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String              // from .claude.json oauthAccount, editable
    public var kind: AccountKind
    public var desktopAlerts: Bool       // default true
    public var ntfyEnabled: Bool         // default false
    public var ntfyTopicOverride: String?
    public var showInMenuBar: Bool = true
    // NEVER holds a token. UserDefaults is a plaintext plist.

    public init(id: UUID = UUID(), name: String, kind: AccountKind,
                desktopAlerts: Bool = true, ntfyEnabled: Bool = false,
                ntfyTopicOverride: String? = nil, showInMenuBar: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.desktopAlerts = desktopAlerts
        self.ntfyEnabled = ntfyEnabled
        self.ntfyTopicOverride = ntfyTopicOverride
        self.showInMenuBar = showInMenuBar
    }

    /// Lenient like `Settings`: an accounts blob written by an older version lacks newly added
    /// keys, and a strict throw here would drop the user's whole account list — including remote
    /// accounts, which cannot be rediscovered and would need their credentials pasted again.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(AccountKind.self, forKey: .kind)
        desktopAlerts = try c.decodeIfPresent(Bool.self, forKey: .desktopAlerts) ?? true
        ntfyEnabled = try c.decodeIfPresent(Bool.self, forKey: .ntfyEnabled) ?? false
        ntfyTopicOverride = try c.decodeIfPresent(String.self, forKey: .ntfyTopicOverride)
        showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? true
    }
}

/// Which number the menu bar shows per account.
public enum MenuBarMetric: String, Codable, CaseIterable, Sendable {
    case worst, session, weekly, modelScoped

    public var label: String {
        switch self {
        case .worst: return "Session or weekly (max)"
        case .session: return "Session (5h)"
        case .weekly: return "Weekly"
        case .modelScoped: return "Weekly (per model)"
        }
    }
}

// MARK: - LimitInfo

public struct LimitInfo: Codable, Hashable, Sendable, Identifiable {
    public let kind: String              // "session" | "weekly_all" | "weekly_scoped" | "spend"
    public let group: String?
    public let percent: Int
    public let severity: Severity
    public let resetsAt: Date?           // nullable; also nulled when now >= resetsAt
    public let modelDisplayName: String? // scope.model.display_name, e.g. "Fable"
    public let isActive: Bool
    public var id: String { kind + "|" + (modelDisplayName ?? "") }
    public var label: String             // "Session" / "Week" / "Week · Fable"
    public var windowLength: TimeInterval // 5h for session, 7d for weekly group

    public init(kind: String, group: String?, percent: Int, severity: Severity,
                resetsAt: Date?, modelDisplayName: String?, isActive: Bool) {
        self.kind = kind
        self.group = group
        self.percent = min(max(percent, 0), 100)
        self.severity = severity
        self.resetsAt = resetsAt
        self.modelDisplayName = modelDisplayName
        self.isActive = isActive
        (self.label, self.windowLength) = LimitInfo.labelAndWindow(kind: kind, modelDisplayName: modelDisplayName)
    }

    private static func labelAndWindow(kind: String, modelDisplayName: String?) -> (String, TimeInterval) {
        switch kind {
        case "session", "five_hour":
            return ("Session", 5 * 3600)
        case "weekly_all", "seven_day":
            return ("Week", 7 * 86400)
        case "weekly_scoped":
            if let name = modelDisplayName { return ("Week · \(name)", 7 * 86400) }
            return ("Week", 7 * 86400)
        case "spend":
            return ("Spend", 0)
        default:
            // ponytail: unknown bucket, no known window length — pacingFraction(...) just returns nil for it.
            return (kind.replacingOccurrences(of: "_", with: " ").capitalized, 0)
        }
    }
}

// MARK: - SpendInfo

public struct SpendInfo: Codable, Hashable, Sendable {
    public let usedMinor: Int
    public let limitMinor: Int?          // NULL in usage_team_no_spend.json
    public let exponent: Int
    public let currency: String
    public let percent: Int
    public let severity: Severity
    public let enabled: Bool
    public var isAlertable: Bool { enabled && limitMinor != nil }
    public var usedFormatted: String     // "$728.60"
    public var limitFormatted: String?   // "$800.00" or nil
    public var asLimitInfo: LimitInfo?   // kind "spend"; nil when !isAlertable

    public init(usedMinor: Int, limitMinor: Int?, exponent: Int, currency: String,
                percent: Int, severity: Severity, enabled: Bool) {
        self.usedMinor = usedMinor
        self.limitMinor = limitMinor
        self.exponent = exponent
        self.currency = currency
        self.percent = min(max(percent, 0), 100)
        self.severity = severity
        self.enabled = enabled
        self.usedFormatted = SpendInfo.formatMoney(minor: usedMinor, exponent: exponent, currency: currency)
        self.limitFormatted = limitMinor.map { SpendInfo.formatMoney(minor: $0, exponent: exponent, currency: currency) }
        self.asLimitInfo = (enabled && limitMinor != nil)
            ? LimitInfo(kind: "spend", group: nil, percent: self.percent, severity: severity,
                        resetsAt: nil, modelDisplayName: nil, isActive: true)
            : nil
    }

    // Decimal, not Double — money. NumberFormatter currency code comes from the payload, never the user's locale.
    /// Whole-currency-unit form for the menu bar, where cents are noise: "$739".
    public var usedCompactFormatted: String {
        let amount = Decimal(usedMinor) / pow(Decimal(10), exponent)
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 0
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(currency) \(amount)"
    }

    /// Formats an arbitrary minor-unit amount (e.g. a delta) in this payload's currency.
    public func format(minor: Int) -> String {
        SpendInfo.formatMoney(minor: minor, exponent: exponent, currency: currency)
    }

    private static func formatMoney(minor: Int, exponent: Int, currency: String) -> String {
        let amount = Decimal(minor) / pow(Decimal(10), exponent)
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(currency) \(amount)"
    }
}

// MARK: - UsageSnapshot

public struct UsageSnapshot: Sendable, Hashable {
    public let limits: [LimitInfo]
    public let spend: SpendInfo?
    public let fetchedAt: Date
    public var worstPercent: Int
    public var worstSeverity: Severity

    /// Convenience for callers (tests, AlertEngine fixtures) building a snapshot directly
    /// rather than through `decode`. Computes worst* the same way `decode` does.
    public init(limits: [LimitInfo], spend: SpendInfo?, fetchedAt: Date = Date()) {
        self.limits = limits
        self.spend = spend
        self.fetchedAt = fetchedAt
        (self.worstPercent, self.worstSeverity) = UsageSnapshot.computeWorst(limits: limits, spend: spend)
    }

    public static func decode(_ data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageDecodeError.invalidPayload
        }
        let limits: [LimitInfo]
        if let rawLimits = root["limits"] as? [[String: Any]] {
            limits = rawLimits.compactMap { parseLimit($0, now: fetchedAt) }
        } else {
            limits = parseFallbackWindows(root, now: fetchedAt)
        }
        let spend = (root["spend"] as? [String: Any]).flatMap(parseSpend)
        return UsageSnapshot(limits: limits, spend: spend, fetchedAt: fetchedAt)
    }

    /// Max of the windows that can actually stop you: session and weekly-all. Per-model windows
    /// are excluded — a maxed-out model still leaves the others usable — and so is spend, which
    /// is money, not a block.
    public var blockingPercent: Int? {
        limits.filter { $0.kind == "session" || $0.kind == "weekly_all" }.map(\.percent).max()
    }

    /// Highest per-model window, with the model's name (e.g. 100, "Fable").
    public var modelScoped: (percent: Int, modelName: String?)? {
        guard let limit = limits.filter({ $0.kind == "weekly_scoped" }).max(by: { $0.percent < $1.percent })
        else { return nil }
        return (limit.percent, limit.modelDisplayName)
    }

    private static func computeWorst(limits: [LimitInfo], spend: SpendInfo?) -> (Int, Severity) {
        var candidates = limits
        if let spendLimit = spend?.asLimitInfo { candidates.append(spendLimit) }
        guard let worstPercent = candidates.map(\.percent).max() else { return (0, .normal) }
        let worstSeverity = candidates.filter { $0.percent == worstPercent }.map(\.severity).max() ?? .normal
        return (worstPercent, worstSeverity)
    }
}

enum UsageDecodeError: Error, Equatable {
    case invalidPayload
}

// MARK: - Pacing

/// Pure, unit-tested. Where an even burn "should" be — the progress-bar tick.
public func pacingFraction(resetsAt: Date, windowLength: TimeInterval, now: Date = Date()) -> Double? {
    guard windowLength > 0 else { return nil }
    let start = resetsAt.addingTimeInterval(-windowLength)
    let elapsed = now.timeIntervalSince(start)
    return min(max(elapsed / windowLength, 0), 1)
}

// MARK: - AccountState

public enum AccountState: Sendable, Equatable {
    case idle
    case ok(UsageSnapshot)
    case stale(UsageSnapshot, error: String)   // last good + latest failure
    case notLoggedIn                            // no keychain entry
    case keychainDenied                         // consent refused
    case needsReauth                            // local, 401
    case needsCredentialsRepaste                // remote, refresh grant failed
    case rateLimited(until: Date)
    case failed(String)
}

// MARK: - Tolerant parsing (private)

private func numeric(_ any: Any?) -> Double? {
    (any as? NSNumber)?.doubleValue
}

private let isoWithFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let isoPlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private func parseDate(_ string: Any?) -> Date? {
    guard let string = string as? String else { return nil }
    return isoWithFraction.date(from: string) ?? isoPlain.date(from: string)
}

/// Server serves stale windows past their own reset time — null them out rather than show garbage.
private func nullIfPast(_ date: Date?, now: Date) -> Date? {
    guard let date else { return nil }
    return now >= date ? nil : date
}

private func parseLimit(_ dict: [String: Any], now: Date) -> LimitInfo? {
    guard let kind = dict["kind"] as? String else { return nil }
    let percent = Int((numeric(dict["percent"]) ?? 0).rounded())
    let severity = Severity(rawValue: dict["severity"] as? String ?? "") ?? .normal
    let resetsAt = nullIfPast(parseDate(dict["resets_at"]), now: now)
    let scope = dict["scope"] as? [String: Any]
    let model = scope?["model"] as? [String: Any]
    return LimitInfo(kind: kind, group: dict["group"] as? String, percent: percent, severity: severity,
                      resetsAt: resetsAt, modelDisplayName: model?["display_name"] as? String,
                      isActive: dict["is_active"] as? Bool ?? false)
}

/// Fallback for the older/looser response shape: any top-level object carrying a numeric
/// `utilization` and a `resets_at` key (even if null) is treated as a usage window.
private func parseFallbackWindows(_ root: [String: Any], now: Date) -> [LimitInfo] {
    root.keys.sorted().compactMap { key -> LimitInfo? in
        guard let dict = root[key] as? [String: Any],
              let utilization = numeric(dict["utilization"]),
              dict.keys.contains("resets_at") else { return nil }
        let resetsAt = nullIfPast(parseDate(dict["resets_at"]), now: now)
        return LimitInfo(kind: key, group: nil, percent: Int(utilization.rounded()), severity: .normal,
                          resetsAt: resetsAt, modelDisplayName: nil, isActive: false)
    }
}

private func parseSpend(_ dict: [String: Any]) -> SpendInfo? {
    let used = dict["used"] as? [String: Any]
    let limit = dict["limit"] as? [String: Any]
    let currency = used?["currency"] as? String ?? "USD"
    let exponent = Int(numeric(used?["exponent"]) ?? 2)
    let severity = Severity(rawValue: dict["severity"] as? String ?? "") ?? .normal
    return SpendInfo(usedMinor: Int(numeric(used?["amount_minor"]) ?? 0),
                      limitMinor: limit.flatMap { numeric($0["amount_minor"]).map(Int.init) },
                      exponent: exponent,
                      currency: currency,
                      percent: Int((numeric(dict["percent"]) ?? 0).rounded()),
                      severity: severity,
                      enabled: dict["enabled"] as? Bool ?? false)
}
