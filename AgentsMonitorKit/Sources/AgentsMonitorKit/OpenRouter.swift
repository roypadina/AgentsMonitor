import Foundation

// MARK: - Namespace, money, UTC windows

public enum OpenRouter {
    /// Synthetic account the spend alerts are delivered as.
    public static let alertAccountId = UUID(uuidString: "0B2E6C1A-7D7A-4C1E-9D1B-5F3A6E8C2A11")!
    public static let managementService = "AgentsMonitor-openrouter-management"

    public static func pastedService(_ id: UUID) -> String { "AgentsMonitor-openrouter-key-\(id.uuidString)" }
    public static func pastedId(_ id: UUID) -> String { "pasted:\(id.uuidString)" }
    public static func pastedUUID(from id: String) -> UUID? {
        id.hasPrefix("pasted:") ? UUID(uuidString: String(id.dropFirst("pasted:".count))) : nil
    }

    static func money(_ usd: Double, fractionDigits: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = fractionDigits
        f.maximumFractionDigits = fractionDigits
        return f.string(from: NSNumber(value: usd)) ?? "$\(usd)"
    }

    /// "$3.20".
    public static func formatUSD(_ usd: Double) -> String { money(usd, fractionDigits: 2) }

    /// "$3.20" under $100, else "$123" (menu bar: cents are noise).
    public static func formatUSDCompact(_ usd: Double) -> String {
        // Judge the rounded value so 99.996 -> "$100.00" does not skip to "$100".
        abs(usd) >= 99.995 ? money(usd, fractionDigits: 0) : formatUSD(usd)
    }

    /// OpenRouter's calendar is UTC with Monday weeks, whatever the user's locale says.
    static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static func period(_ interval: String?, now: Date) -> DateInterval? {
        switch interval {
        case "daily": return utcCalendar.dateInterval(of: .day, for: now)
        case "weekly": return utcCalendar.dateInterval(of: .weekOfYear, for: now)
        case "monthly": return utcCalendar.dateInterval(of: .month, for: now)
        default: return nil
        }
    }

    /// "daily" -> next 00:00Z, "weekly" -> next Monday 00:00Z, "monthly" -> 1st of next month; else nil.
    public static func nextUTCReset(_ interval: String?, now: Date) -> Date? { period(interval, now: now)?.end }

    /// The current period's start for the same intervals.
    public static func utcWindowStart(_ interval: String, now: Date) -> Date? { period(interval, now: now)?.start }
}

// MARK: - Models

public struct OpenRouterBudget: Codable, Hashable, Sendable {      // effective_budget from /key
    public let scope: String
    public let limitUSD: Double
    public let spendUSD: Double
    public let remainingUSD: Double
    public let resetInterval: String?
    public let resetsAt: Date?

    public init(scope: String, limitUSD: Double, spendUSD: Double, remainingUSD: Double,
                resetInterval: String?, resetsAt: Date?) {
        self.scope = scope
        self.limitUSD = limitUSD
        self.spendUSD = spendUSD
        self.remainingUSD = remainingUSD
        self.resetInterval = resetInterval
        self.resetsAt = resetsAt
    }
}

public struct OpenRouterKeyUsage: Hashable, Sendable, Identifiable {
    public let id: String              // hash | "pasted:<UUID>"
    public let name: String?           // OpenRouter key name (managed only)
    public let label: String           // masked, e.g. "sk-or-v1-abc...123"
    public let expiresAt: Date?
    public let limit: Double?          // USD cap, nil = none
    public let limitRemaining: Double?
    public let limitReset: String?     // "daily" | "weekly" | "monthly" | nil
    public let usage: Double           // all-time USD
    public let usageDaily: Double
    public let usageWeekly: Double
    public let usageMonthly: Double
    public let budget: OpenRouterBudget?   // /key only
    public var error: String?          // set by the store for a pasted key whose poll failed

    public init(id: String, name: String? = nil, label: String, expiresAt: Date? = nil,
                limit: Double? = nil, limitRemaining: Double? = nil, limitReset: String? = nil,
                usage: Double = 0, usageDaily: Double = 0, usageWeekly: Double = 0, usageMonthly: Double = 0,
                budget: OpenRouterBudget? = nil, error: String? = nil) {
        self.id = id
        self.name = name
        self.label = label
        self.expiresAt = expiresAt
        self.limit = limit
        self.limitRemaining = limitRemaining
        self.limitReset = limitReset
        self.usage = usage
        self.usageDaily = usageDaily
        self.usageWeekly = usageWeekly
        self.usageMonthly = usageMonthly
        self.budget = budget
        self.error = error
    }

    public var capTotal: Double? { limit ?? budget?.limitUSD }
    public var capRemaining: Double? { limitRemaining ?? budget?.remainingUSD }

    /// Used share of the cap; nil without a cap, without a remaining figure, or when the cap is 0.
    public var capPercent: Int? {
        guard let total = capTotal, let remaining = capRemaining, total > 0 else { return nil }
        return min(max(Int(((total - remaining) / total * 100).rounded()), 0), 100)
    }

    public var capSeverity: Severity {
        capPercent.map(UsageSnapshot.codexSeverity(percent:)) ?? .normal
    }

    public func capResetsAt(now: Date) -> Date? {
        budget?.resetsAt ?? OpenRouter.nextUTCReset(limitReset, now: now)
    }
}

public struct OpenRouterBalance: Hashable, Sendable {
    public let totalCredits: Double
    public let totalUsage: Double
    public var usd: Double { totalCredits - totalUsage }

    public init(totalCredits: Double, totalUsage: Double) {
        self.totalCredits = totalCredits
        self.totalUsage = totalUsage
    }
}

public struct OpenRouterSnapshot: Hashable, Sendable {
    public var keys: [OpenRouterKeyUsage]   // config order; hidden keys included (alerts need them)
    public var balance: OpenRouterBalance?  // nil without a management key
    public var managementError: String?     // mgmt key failed this poll; pasted keys may still be fresh
    public var fetchedAt: Date
    public var todayTotal: Double           // sum of usageDaily over keys without error

    public init(keys: [OpenRouterKeyUsage], balance: OpenRouterBalance? = nil,
                managementError: String? = nil, fetchedAt: Date = Date()) {
        self.keys = keys
        self.balance = balance
        self.managementError = managementError
        self.fetchedAt = fetchedAt
        self.todayTotal = keys.filter { $0.error == nil }.reduce(0) { $0 + $1.usageDaily }
    }
}

public enum OpenRouterState: Sendable, Equatable {
    case idle, ok(OpenRouterSnapshot), stale(OpenRouterSnapshot, error: String), failed(String)
}

public struct OpenRouterKeyConfig: Codable, Identifiable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable { case managed, pasted }
    public var id: String
    public var source: Source
    public var nickname: String?
    public var placement: Placement = .more
    public var lastName: String?     // cached from the last poll (shown before the first poll of a launch)
    public var lastLabel: String?
    public var displayName: String { nickname ?? lastName ?? lastLabel ?? "OpenRouter key" }

    public init(id: String, source: Source, nickname: String? = nil, placement: Placement = .more,
                lastName: String? = nil, lastLabel: String? = nil) {
        self.id = id
        self.source = source
        self.nickname = nickname
        self.placement = placement
        self.lastName = lastName
        self.lastLabel = lastLabel
    }

    /// Lenient: a strict throw would drop the user's whole key list.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        source = try c.decode(Source.self, forKey: .source)
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
        placement = try c.decodeIfPresent(Placement.self, forKey: .placement) ?? .more
        lastName = try c.decodeIfPresent(String.self, forKey: .lastName)
        lastLabel = try c.decodeIfPresent(String.self, forKey: .lastLabel)
    }
}

/// `Settings.openRouter`: what is connected, where the balance shows, how spend alerts are delivered.
public struct OpenRouterSettings: Codable, Equatable, Sendable {
    public var managementKeyConfigured = false     // avoids a keychain probe at launch
    public var balancePlacement: Placement = .more
    public var desktopAlerts = true
    public var ntfyEnabled = false
    public var ntfyTopicOverride: String?

    public init() {}

    /// Lenient like `Settings`: a strict throw would reset every setting to its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OpenRouterSettings()
        managementKeyConfigured = try c.decodeIfPresent(Bool.self, forKey: .managementKeyConfigured) ?? d.managementKeyConfigured
        balancePlacement = try c.decodeIfPresent(Placement.self, forKey: .balancePlacement) ?? d.balancePlacement
        desktopAlerts = try c.decodeIfPresent(Bool.self, forKey: .desktopAlerts) ?? d.desktopAlerts
        ntfyEnabled = try c.decodeIfPresent(Bool.self, forKey: .ntfyEnabled) ?? d.ntfyEnabled
        ntfyTopicOverride = try c.decodeIfPresent(String.self, forKey: .ntfyTopicOverride)
    }
}

// MARK: - Client

public struct OpenRouterClient: Sendable {
    public static let base = URL(string: "https://openrouter.ai/api/v1")!
    private static let pageSize = 100
    private static let maxPages = 10

    private let session: URLSession

    public init(session: URLSession = UsageClient.noCacheSession) {
        self.session = session
    }

    /// GET /keys, pages of 100 (offset 0, 100, ...); stops on a short page or after 10 pages.
    public func listKeys(managementKey: String) async throws -> [OpenRouterKeyUsage] {
        var all: [OpenRouterKeyUsage] = []
        for page in 0..<Self.maxPages {
            let data = try await get("keys", query: [URLQueryItem(name: "offset", value: String(page * Self.pageSize))],
                                     key: managementKey)
            let (keys, rawCount) = try Self.decodeKeyPage(data)
            all += keys
            if rawCount < Self.pageSize { break }
        }
        return all
    }

    public func credits(managementKey: String) async throws -> OpenRouterBalance {
        try Self.decodeCredits(try await get("credits", key: managementKey))
    }

    public func key(apiKey: String, id: String) async throws -> OpenRouterKeyUsage {
        try Self.decodeKey(try await get("key", key: apiKey), id: id)
    }

    private func get(_ path: String, query: [URLQueryItem] = [], key: String) async throws -> Data {
        var comps = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var request = URLRequest(url: comps.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("agents-monitor", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.unreachable(error)
        }
        guard let http = response as? HTTPURLResponse else { throw UsageError.transport("no response") }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw UsageError.unauthorized
        case 403: throw UsageError.forbidden
        case 429: throw UsageError.rateLimited
        default: throw UsageError.http(http.statusCode)
        }
    }

    // MARK: Decoding (tolerant, like UsageSnapshot.decode)

    static func decodeKeyList(_ data: Data, now: Date = Date()) throws -> [OpenRouterKeyUsage] {
        try decodeKeyPage(data, now: now).keys
    }

    /// `rawCount` is the page's item count before skipping malformed ones — paging stops on it.
    private static func decodeKeyPage(_ data: Data, now: Date = Date()) throws -> (keys: [OpenRouterKeyUsage], rawCount: Int) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = (root["data"] as? [[String: Any]]) ?? (root["keys"] as? [[String: Any]])
        else { throw UsageError.decode("keys payload is not a list") }
        let keys = items.compactMap { item -> OpenRouterKeyUsage? in
            guard let hash = item["hash"] as? String, item["label"] is String else { return nil }
            return parseKey(item, id: hash, now: now)
        }
        return (keys, items.count)
    }

    static func decodeKey(_ data: Data, id: String, now: Date = Date()) throws -> OpenRouterKeyUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = root["data"] as? [String: Any]
        else { throw UsageError.decode("key payload is not an object") }
        return parseKey(item, id: id, now: now)
    }

    static func decodeCredits(_ data: Data) throws -> OpenRouterBalance {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = root["data"] as? [String: Any],
              let total = number(item["total_credits"]), let used = number(item["total_usage"])
        else { throw UsageError.decode("credits payload is not recognised") }
        return OpenRouterBalance(totalCredits: total, totalUsage: used)
    }

    private static func parseKey(_ d: [String: Any], id: String, now: Date) -> OpenRouterKeyUsage {
        let budget = (d["effective_budget"] as? [String: Any]).flatMap { b -> OpenRouterBudget? in
            guard let limit = number(b["limit_usd"]), let spend = number(b["spend_usd"]),
                  let remaining = number(b["remaining_usd"]) else { return nil }
            return OpenRouterBudget(scope: b["scope"] as? String ?? "", limitUSD: limit, spendUSD: spend,
                                    remainingUSD: remaining, resetInterval: b["reset_interval"] as? String,
                                    resetsAt: date(b["resets_at"]))
        }
        let expires = date(d["expires_at"]).flatMap { $0 > now ? $0 : nil }   // API already filters expired keys
        return OpenRouterKeyUsage(id: id, name: d["name"] as? String, label: d["label"] as? String ?? "",
                                  expiresAt: expires, limit: number(d["limit"]),
                                  limitRemaining: number(d["limit_remaining"]), limitReset: d["limit_reset"] as? String,
                                  usage: number(d["usage"]) ?? 0, usageDaily: number(d["usage_daily"]) ?? 0,
                                  usageWeekly: number(d["usage_weekly"]) ?? 0, usageMonthly: number(d["usage_monthly"]) ?? 0,
                                  budget: budget)
    }

    private static func number(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }

    private static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return isoFraction.date(from: s) ?? isoPlain.date(from: s)
    }
}
