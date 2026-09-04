import Foundation
import Observation
import os

public struct Settings: Codable, Equatable, Sendable {
    public var pollSeconds: Int = 300          // clamp 30...600 (enforced in the Settings UI)
    public var thresholds = AlertThresholds()
    public var ntfyServer: String = "https://ntfy.sh"
    public var ntfyDefaultTopic: String = ""   // user-local only, never committed
    public var showPercentInMenuBar: Bool = true
    public var menuBarMetric: MenuBarMetric = .worst
    public var menuBarBlockedDot: Bool = true      // green/red dot per account (session/weekly only)
    public var menuBarShowModelScoped: Bool = false // append the per-model window, e.g. "F 100%"
    public var menuBarShowSpend: Bool = false       // append extra-usage spend, e.g. "$739"
    public var toastEnabled: Bool = true
    public var soundEnabled: Bool = true
    public var extraUsageAlerts: Bool = true   // notify when paid extra usage starts moving

    public init() {}

    /// Every field decoded with `decodeIfPresent`: a settings blob written by an older version is
    /// missing newly added keys, and strict decoding would throw — which the caller turns into
    /// "fall back to defaults", silently wiping the user's ntfy topic and thresholds on upgrade.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        pollSeconds = try c.decodeIfPresent(Int.self, forKey: .pollSeconds) ?? d.pollSeconds
        thresholds = try c.decodeIfPresent(AlertThresholds.self, forKey: .thresholds) ?? d.thresholds
        ntfyServer = try c.decodeIfPresent(String.self, forKey: .ntfyServer) ?? d.ntfyServer
        ntfyDefaultTopic = try c.decodeIfPresent(String.self, forKey: .ntfyDefaultTopic) ?? d.ntfyDefaultTopic
        showPercentInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showPercentInMenuBar) ?? d.showPercentInMenuBar
        menuBarMetric = try c.decodeIfPresent(MenuBarMetric.self, forKey: .menuBarMetric) ?? d.menuBarMetric
        menuBarBlockedDot = try c.decodeIfPresent(Bool.self, forKey: .menuBarBlockedDot) ?? d.menuBarBlockedDot
        menuBarShowModelScoped = try c.decodeIfPresent(Bool.self, forKey: .menuBarShowModelScoped) ?? d.menuBarShowModelScoped
        menuBarShowSpend = try c.decodeIfPresent(Bool.self, forKey: .menuBarShowSpend) ?? d.menuBarShowSpend
        toastEnabled = try c.decodeIfPresent(Bool.self, forKey: .toastEnabled) ?? d.toastEnabled
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? d.soundEnabled
        extraUsageAlerts = try c.decodeIfPresent(Bool.self, forKey: .extraUsageAlerts) ?? d.extraUsageAlerts
    }
}

@MainActor
@Observable
public final class AppStore {
    public static let shared = AppStore()

    public var accounts: [Account] = []
    public var states: [UUID: AccountState] = [:]
    public var settings = Settings()
    public var lastRefresh: Date?
    public var isRefreshing = false
    /// App assigns Notifier.deliver here — the Kit never imports AppKit/UserNotifications.
    public var onAlerts: (([Alert], Account) -> Void)?

    private let credentialStore = CredentialStore()
    private let usageClient = UsageClient()
    private let codexClient = CodexUsageClient()
    private var alertEngine = AlertEngine()
    private var backoffState: [UUID: BackoffLadder] = [:]
    private var rateLimitedUntil: [UUID: Date] = [:]
    /// Last good snapshot per account, kept so a transient failure never blanks the rows.
    private var lastSnapshot: [UUID: UsageSnapshot] = [:]
    private var pollTask: Task<Void, Never>?

    private static let accountsKey = "AgentsMonitor.accounts"
    private static let settingsKey = "AgentsMonitor.settings"
    private static let alertMemoryKey = "AgentsMonitor.alertMemory"
    private static let scannedProvidersKey = "AgentsMonitor.scannedProviders"
    private static let log = Logger(subsystem: "com.roy.agentsmonitor", category: "poll")

    public init() {}

    /// Loads persisted defaults; on first run (no saved accounts) discovers local ones.
    public func bootstrap() {
        Self.migrateLegacyDefaults()
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = decoded
        }
        alertEngine = AlertEngine(thresholds: settings.thresholds)
        alertEngine.extraUsageAlerts = settings.extraUsageAlerts
        // Restore alert de-dupe memory so a relaunch doesn't re-fire everything already alerted.
        if let data = UserDefaults.standard.data(forKey: Self.alertMemoryKey) {
            alertEngine.restoreMemory(from: data)
        }

        if let data = UserDefaults.standard.data(forKey: Self.accountsKey),
           let decoded = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = decoded
        } else {
            accounts = Self.discoverLocalAccounts()
        }
        adoptUnscannedProviders()
        for account in accounts where states[account.id] == nil {
            states[account.id] = .idle
        }
        save()
    }

    /// Discovery only ever ran on first launch, so an existing install would never notice that
    /// the app learned about a new provider — Codex accounts would stay invisible until the user
    /// went looking for an Add button. Each provider is therefore scanned exactly once, and the
    /// fact that it was scanned is remembered: a provider the user has since deleted every
    /// account of stays deleted.
    private func adoptUnscannedProviders() {
        var scanned = Set(UserDefaults.standard.stringArray(forKey: Self.scannedProvidersKey) ?? [])
        let unscanned = Provider.allCases.filter { !scanned.contains($0.rawValue) }
        guard !unscanned.isEmpty else { return }

        // First launch of any build: whatever bootstrap just discovered counts as the scan.
        let knownDirs = Set(accounts.compactMap { account -> String? in
            guard case .local(let path) = account.kind else { return nil }
            return path
        })
        for provider in unscanned {
            let found = Self.discoverLocalAccounts()
                .filter { $0.provider == provider }
                .filter { account in
                    guard case .local(let path) = account.kind else { return true }
                    return !knownDirs.contains(path)
                }
            if !found.isEmpty {
                accounts.append(contentsOf: found)
                Self.log.info("adopted \(found.count) \(provider.rawValue, privacy: .public) account(s) on first scan")
            }
            scanned.insert(provider.rawValue)
        }
        UserDefaults.standard.set(Array(scanned).sorted(), forKey: Self.scannedProvidersKey)
    }

    /// The rename to Agents Monitor changed the bundle identifier, and with it the preferences
    /// domain — so an upgrade would land on first-run defaults and silently drop the account
    /// list (including remote accounts, which cannot be rediscovered) and the alert de-dupe
    /// memory, re-firing every threshold alert already sent. Copies the three keys over once,
    /// only into a domain that has nothing of its own yet. The app is un-sandboxed, so the old
    /// domain is readable by name.
    static func migrateLegacyDefaults(into defaults: UserDefaults = .standard,
                                      legacy legacyDefaults: UserDefaults? = UserDefaults(suiteName: legacyDefaultsDomain)) {
        guard defaults.data(forKey: accountsKey) == nil,
              defaults.data(forKey: settingsKey) == nil,
              let legacyDefaults else { return }
        var migrated: [String] = []
        for (legacyKey, key) in [("ClaudeMonitor.accounts", accountsKey),
                                 ("ClaudeMonitor.settings", settingsKey),
                                 ("ClaudeMonitor.alertMemory", alertMemoryKey)] {
            guard let data = legacyDefaults.data(forKey: legacyKey) else { continue }
            defaults.set(data, forKey: key)
            migrated.append(key)
        }
        guard !migrated.isEmpty else { return }
        log.info("migrated \(migrated.count) key(s) from \(legacyDefaultsDomain, privacy: .public): \(migrated.joined(separator: ","), privacy: .public)")
    }

    public func save() {
        // Settings edits must reach the live engine — otherwise a threshold or toggle change
        // only takes effect after a relaunch. Every Settings control routes through save().
        alertEngine.thresholds = settings.thresholds
        alertEngine.extraUsageAlerts = settings.extraUsageAlerts
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.accountsKey)
        }
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }

    /// Concurrent per-account; keychain read + network fetch happen off-main inside `fetch`.
    public func refresh() async {
        guard !isRefreshing else { return }
        // Floor between polls: the Refresh button, a wake-up and the poll timer can otherwise
        // land on top of each other and spend three requests per account for one screenful.
        if let last = lastRefresh, Date().timeIntervalSince(last) < Self.minRefreshInterval { return }
        isRefreshing = true
        defer { isRefreshing = false; lastRefresh = Date() }

        let now = Date()
        var toFetch: [Account] = []
        for account in accounts {
            if let until = rateLimitedUntil[account.id], until > now {
                states[account.id] = Self.preservingSnapshot(.rateLimited(until: until),
                                                             last: lastSnapshot[account.id])
            } else {
                toFetch.append(account)
            }
        }

        let credentialStore = self.credentialStore
        let usageClient = self.usageClient
        let codexClient = self.codexClient
        let results = await withTaskGroup(of: (UUID, AccountState).self) { group in
            for account in toFetch {
                group.addTask {
                    (account.id, await Self.fetch(account: account, credentialStore: credentialStore,
                                                  usageClient: usageClient, codexClient: codexClient))
                }
            }
            var collected: [(UUID, AccountState)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        for (id, fetchedState) in results {
            guard let account = accounts.first(where: { $0.id == id }) else { continue }

            let resolvedState: AccountState
            if case .rateLimited = fetchedState {
                // Backoff state is per-account — one throttled account never stalls the rest.
                var ladder = backoffState[id] ?? BackoffLadder()
                let wait = ladder.advance()
                backoffState[id] = ladder
                let until = Date().addingTimeInterval(wait)
                rateLimitedUntil[id] = until
                resolvedState = .rateLimited(until: until)
            } else {
                backoffState[id]?.reset()
                rateLimitedUntil[id] = nil
                resolvedState = fetchedState
            }

            if case .ok(let snapshot) = resolvedState { lastSnapshot[id] = snapshot }
            let displayState = Self.preservingSnapshot(resolvedState, last: lastSnapshot[id])

            let previous = states[id]
            states[id] = displayState
            Self.log.debug("\(account.name, privacy: .public): \(Self.describe(displayState), privacy: .public)")
            if let previous, Self.describe(previous) != Self.describe(displayState) {
                Self.log.info("\(account.name, privacy: .public) state: \(Self.describe(previous), privacy: .public) -> \(Self.describe(displayState), privacy: .public)")
            }
            let alerts = alertEngine.evaluate(account: account, state: displayState)
            if !alerts.isEmpty {
                Self.log.info("firing \(alerts.count) alert(s) for \(account.name, privacy: .public): \(alerts.map(\.key).joined(separator: ","), privacy: .public)")
                onAlerts?(alerts, account)
            }
        }

        // Persist the de-dupe memory (cheap: a few hundred bytes once per poll).
        if let snapshot = alertEngine.memorySnapshot {
            UserDefaults.standard.set(snapshot, forKey: Self.alertMemoryKey)
        }
    }

    static let minRefreshInterval: TimeInterval = 20

    /// A throttled or failed poll must not blank an account that already has numbers — keep the
    /// last good snapshot and hang the failure text off it. Auth states are deliberately NOT
    /// converted: AlertEngine keys its auth alerts off them, and a stale bar would hide the
    /// one problem the user has to act on.
    nonisolated static func preservingSnapshot(_ state: AccountState, last: UsageSnapshot?) -> AccountState {
        guard let last else { return state }
        switch state {
        case .rateLimited(let until):
            let time = until.formatted(date: .omitted, time: .shortened)
            return .stale(last, error: "usage API throttled — retrying \(time)")
        case .failed(let message):
            return .stale(last, error: "last refresh failed: \(message)")
        default:
            return state
        }
    }

    private static func describe(_ state: AccountState) -> String {
        switch state {
        case .idle: return "idle"
        case .ok(let s): return "ok worst=\(s.worstPercent)% \(s.worstSeverity.rawValue)"
        case .stale(let s, let e): return "stale worst=\(s.worstPercent)% err=\(e)"
        case .notLoggedIn: return "notLoggedIn"
        case .keychainDenied: return "keychainDenied"
        case .needsReauth: return "needsReauth"
        case .needsCredentialsRepaste: return "needsCredentialsRepaste"
        case .rateLimited(let until): return "rateLimited until=\(until.formatted(date: .omitted, time: .standard))"
        case .failed(let msg): return "failed \(msg)"
        }
    }

    /// One cancellable `Task` with `Task.sleep`, restarted whenever the interval changes.
    public func startPolling() {
        stopPolling()
        pollTask = Task {
            while !Task.isCancelled {
                await refresh()
                let seconds = max(settings.pollSeconds, 1)
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    public var worst: (percent: Int, severity: Severity)? {
        let live = states.values.compactMap { state -> (Int, Severity)? in
            switch state {
            case .ok(let snapshot), .stale(let snapshot, _):
                return (snapshot.worstPercent, snapshot.worstSeverity)
            default:
                return nil
            }
        }
        guard let maxPercent = live.map(\.0).max() else { return nil }
        let severity = live.filter { $0.0 == maxPercent }.map(\.1).max() ?? .normal
        return (maxPercent, severity)
    }

    /// Worst percent for one account, or nil when it has no usable snapshot yet.
    public func worstPercent(for accountId: UUID) -> Int? {
        snapshot(for: accountId)?.worstPercent
    }

    /// The percent for the configured metric, or nil when the account has no such limit.
    public func percent(for accountId: UUID, metric: MenuBarMetric) -> Int? {
        guard let snapshot = snapshot(for: accountId) else { return nil }
        switch metric {
        case .worst: return snapshot.blockingPercent
        case .session: return snapshot.limits.first { $0.kind == "session" }?.percent
        case .weekly: return snapshot.limits.first { $0.kind == "weekly_all" }?.percent
        case .modelScoped: return snapshot.limits.filter { $0.kind == "weekly_scoped" }.map(\.percent).max()
        }
    }

    /// Blocked = a limit you cannot work around is exhausted. Per-model windows are ignored on
    /// purpose: with Fable at 100% you can still work on another model.
    public func isBlocked(_ accountId: UUID) -> Bool {
        guard let snapshot = snapshot(for: accountId) else { return false }
        return snapshot.limits.contains { ($0.kind == "session" || $0.kind == "weekly_all") && $0.percent >= 100 }
    }

    private func snapshot(for accountId: UUID) -> UsageSnapshot? {
        switch states[accountId] {
        case .ok(let snapshot), .stale(let snapshot, _): return snapshot
        default: return nil
        }
    }

    /// Short per-account labels for the menu bar: a provider letter plus any digits in the name
    /// ("claude" -> "c", "claude2" -> "c2", a Codex account -> "x"). The letter comes from the
    /// provider rather than the name because Codex names default to an email address, whose
    /// first letter says nothing. Falls back to 1-based numbering if the tags collide.
    public static func menuBarTags(for accounts: [Account]) -> [UUID: String] {
        func tag(_ account: Account) -> String {
            let letter = account.provider == .codex ? "x" : "c"
            return letter + account.name.filter(\.isNumber)
        }
        var tags = accounts.reduce(into: [UUID: String]()) { $0[$1.id] = tag($1) }
        if Set(tags.values).count != accounts.count {
            for (index, account) in accounts.enumerated() { tags[account.id] = String(index + 1) }
        }
        return tags
    }

    /// Accounts the user chose to show in the menu bar (all of them by default).
    public var menuBarAccounts: [Account] {
        accounts.filter(\.showInMenuBar)
    }

    /// One entry per shown account. `dotPercent` is the session/weekly max — deliberately
    /// independent of the displayed metric, so the dot always means "how close to being stopped".
    /// nil means no data yet (drawn gray).
    public struct MenuBarSegment: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let tag: String?
        public let dotPercent: Int?
        public let showDot: Bool
        public let text: String
    }

    public var menuBarSegments: [MenuBarSegment] {
        let shown = menuBarAccounts
        let tags = Self.menuBarTags(for: shown)
        let single = shown.count == 1

        return shown.compactMap { account -> MenuBarSegment? in
            let snapshot = snapshot(for: account.id)
            var fields: [String] = []

            if settings.showPercentInMenuBar, let percent = percent(for: account.id, metric: settings.menuBarMetric) {
                fields.append("\(percent)%")
            }
            // Per-model window kept separate on purpose: a maxed-out model is not a block, so it
            // must never masquerade as the account's headline number.
            if settings.menuBarShowModelScoped, let model = snapshot?.modelScoped,
               settings.menuBarMetric != .modelScoped {
                let initial = model.modelName?.first.map { String($0).uppercased() } ?? "M"
                fields.append("\(initial) \(model.percent)%")
            }
            if settings.menuBarShowSpend, let spend = snapshot?.spend, spend.enabled, spend.usedMinor > 0 {
                fields.append(spend.usedCompactFormatted)
            }

            let showDot = settings.menuBarBlockedDot && snapshot != nil
            guard showDot || !fields.isEmpty else { return nil }
            // No numbers -> no tag either: a bare "c · c2" adds nothing the dot order doesn't
            // already say, and the point of dots-only mode is minimum width.
            return MenuBarSegment(id: account.id,
                                  tag: (single || fields.isEmpty) ? nil : tags[account.id],
                                  dotPercent: snapshot?.blockingPercent,
                                  showDot: showDot,
                                  text: fields.joined(separator: " "))
        }
    }

    /// Text-only rendering (no dots) — used for logging, tests, and as the accessibility title.
    public var menuBarText: String {
        menuBarSegments.compactMap { segment in
            let parts = [segment.tag, segment.text.isEmpty ? nil : segment.text].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }.joined(separator: " · ")
    }

    // MARK: - Off-main fetch (nonisolated: runs inside TaskGroup child tasks)

    nonisolated private static func fetch(account: Account, credentialStore: CredentialStore,
                                          usageClient: UsageClient,
                                          codexClient: CodexUsageClient) async -> AccountState {
        // Both providers answer with the same `UsageSnapshot`, so only the call differs.
        let fetchUsage: (String) async throws -> UsageSnapshot = { token in
            switch account.provider {
            case .claude:
                return try await usageClient.fetch(accessToken: token)
            case .codex:
                guard case .local(let configDirPath) = account.kind else {
                    throw CredentialError.notFound
                }
                return try await codexClient.fetch(accessToken: token,
                                                   accountId: CodexAuthFile.accountId(configDir: configDirPath))
            }
        }
        var usedToken: String?
        do {
            do {
                let token = try await credentialStore.accessToken(for: account)
                usedToken = token
                return .ok(try await fetchUsage(token))
            } catch UsageError.unauthorized {
                // Claude Code rotates its token mid-poll sometimes (observed live: single 401,
                // fresh token already in the keychain seconds later); Codex rewrites auth.json
                // on the same kind of schedule. Re-read and retry once —
                // but only when the token really changed: re-firing the same dead token just
                // buys a 429 on this account's usage-endpoint bucket (observed 2026-08-21).
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let token = try await credentialStore.accessToken(for: account)
                guard token != usedToken else {
                    fetchLog.info("401 for \(account.name, privacy: .public) — token unchanged, not retrying")
                    throw UsageError.unauthorized
                }
                fetchLog.info("401 for \(account.name, privacy: .public) — token rotated, retrying once")
                return .ok(try await fetchUsage(token))
            }
        } catch CredentialError.notFound {
            return .notLoggedIn
        } catch CredentialError.denied {
            return .keychainDenied
        } catch CredentialError.refreshFailed(_) {
            return .needsCredentialsRepaste
        } catch CredentialError.badPayload {
            return .failed("bad credentials payload")
        } catch UsageError.unauthorized {
            if case .local = account.kind { return .needsReauth }
            return .needsCredentialsRepaste
        } catch UsageError.rateLimited {
            return .rateLimited(until: Date())   // caller replaces with the real backoff date
        } catch {
            return .failed(String(describing: error))
        }
    }

    // MARK: - First-run discovery

    /// Every provider profile on this Mac, Claude first.
    static func discoverLocalAccounts() -> [Account] {
        discoverClaudeAccounts() + discoverCodexAccounts()
    }

    /// Config-dir candidates for a provider: `~/.claude`, `~/.claude-work2`, `~/.claude3`,
    /// `~/.codex`, ... Directories only — files such as `.claude.json` share the prefix.
    static func profileDirs(for provider: Provider, home: String = NSHomeDirectory()) -> [String] {
        let prefix = provider.configDirPrefix
        var dirs = ["\(home)/\(prefix)"]
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: home) {
            dirs += entries
                .filter { $0.hasPrefix(prefix) && $0 != prefix }
                .sorted()
                .map { "\(home)/\($0)" }
        }
        return dirs.filter { dir in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue
        }
    }

    /// A `~/.codex*` directory counts as an account once it holds an `auth.json` we can read a
    /// ChatGPT token out of — an api-key-only login has no usage to report. Named by the signed-in
    /// address from the token claims, falling back to the directory basename.
    private static func discoverCodexAccounts(home: String = NSHomeDirectory()) -> [Account] {
        profileDirs(for: .codex, home: home).compactMap(codexAccount(configDir:))
    }

    /// nil when the directory holds no readable ChatGPT login — also what the Settings
    /// "Add Codex Account…" panel uses to reject a wrong folder before adding it.
    public static func codexAccount(configDir: String) -> Account? {
        guard CodexAuthFile.exists(configDir: configDir),
              (try? CodexAuthFile.accessToken(configDir: configDir)) != nil else { return nil }
        var fallback = (configDir as NSString).lastPathComponent
        if fallback.hasPrefix(".") { fallback.removeFirst() }
        return Account(name: CodexAuthFile.email(configDir: configDir) ?? fallback,
                       kind: .local(configDirPath: configDir), provider: .codex)
    }

    /// Always adds `~/.claude` if a keychain entry exists; globs `~/.claude-*` dirs and adds
    /// those with keychain entries too. Names come from `.claude.json`; unlabeled falls back
    /// to the directory basename — never dropped.
    private static func discoverClaudeAccounts() -> [Account] {
        let home = NSHomeDirectory()
        let existingServices = Set(KeychainService.discoverClaudeServices())
        let labels = KeychainService.discoverLabels(home: home)

        return profileDirs(for: .claude, home: home).compactMap { dir in
            let service = KeychainService.serviceName(forConfigDir: dir, home: home)
            guard existingServices.contains(service) else { return nil }
            var fallback = (dir as NSString).lastPathComponent
            if fallback.hasPrefix(".") { fallback.removeFirst() }   // ".claude" reads better as "claude"
            let name = labels[service]?.email ?? fallback
            return Account(name: name, kind: .local(configDirPath: dir))
        }
    }
}

/// Preferences domain of the pre-rename Claude Monitor builds — see `AppStore.migrateLegacyDefaults`.
/// File scope, not a static member: `AppStore` is `@MainActor`, and a default argument is
/// evaluated in a nonisolated context.
let legacyDefaultsDomain = "com.roy.claudemonitor"

/// Off-main logger for the nonisolated fetch path (AppStore's own logger is MainActor-bound).
private let fetchLog = Logger(subsystem: "com.roy.agentsmonitor", category: "poll")

/// Per-account 429 backoff: 3 -> 6 -> 12 -> 15 minutes, holding at 15. Any 2xx resets to rung 0.
struct BackoffLadder: Sendable {
    private static let stepsMinutes: [Int] = [3, 6, 12, 15]
    private var rungIndex = 0

    mutating func advance() -> TimeInterval {
        let minutes = Self.stepsMinutes[rungIndex]
        rungIndex = min(rungIndex + 1, Self.stepsMinutes.count - 1)
        return TimeInterval(minutes * 60)
    }

    mutating func reset() {
        rungIndex = 0
    }
}
