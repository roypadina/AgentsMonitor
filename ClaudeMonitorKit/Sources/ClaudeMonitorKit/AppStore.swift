import Foundation
import Observation
import os

public struct Settings: Codable, Equatable, Sendable {
    public var pollSeconds: Int = 180          // clamp 30...600 (enforced in the Settings UI)
    public var thresholds = AlertThresholds()
    public var ntfyServer: String = "https://ntfy.sh"
    public var ntfyDefaultTopic: String = ""   // user-local only, never committed
    public var showPercentInMenuBar: Bool = true
    public var toastEnabled: Bool = true
    public var soundEnabled: Bool = true

    public init() {}
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
    private var alertEngine = AlertEngine()
    private var backoffState: [UUID: BackoffLadder] = [:]
    private var rateLimitedUntil: [UUID: Date] = [:]
    private var pollTask: Task<Void, Never>?

    private static let accountsKey = "ClaudeMonitor.accounts"
    private static let settingsKey = "ClaudeMonitor.settings"
    private static let alertMemoryKey = "ClaudeMonitor.alertMemory"
    private static let log = Logger(subsystem: "com.roy.claudemonitor", category: "poll")

    public init() {}

    /// Loads persisted defaults; on first run (no saved accounts) discovers local ones.
    public func bootstrap() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = decoded
        }
        alertEngine = AlertEngine(thresholds: settings.thresholds)
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
        for account in accounts where states[account.id] == nil {
            states[account.id] = .idle
        }
        save()
    }

    public func save() {
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
        isRefreshing = true
        defer { isRefreshing = false; lastRefresh = Date() }

        let now = Date()
        var toFetch: [Account] = []
        for account in accounts {
            if let until = rateLimitedUntil[account.id], until > now {
                states[account.id] = .rateLimited(until: until)
            } else {
                toFetch.append(account)
            }
        }

        let credentialStore = self.credentialStore
        let usageClient = self.usageClient
        let results = await withTaskGroup(of: (UUID, AccountState).self) { group in
            for account in toFetch {
                group.addTask {
                    (account.id, await Self.fetch(account: account, credentialStore: credentialStore, usageClient: usageClient))
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

            let previous = states[id]
            states[id] = resolvedState
            Self.log.debug("\(account.name, privacy: .public): \(Self.describe(resolvedState), privacy: .public)")
            if let previous, Self.describe(previous) != Self.describe(resolvedState) {
                Self.log.info("\(account.name, privacy: .public) state: \(Self.describe(previous), privacy: .public) -> \(Self.describe(resolvedState), privacy: .public)")
            }
            let alerts = alertEngine.evaluate(account: account, state: resolvedState)
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

    public var menuBarText: String {
        guard settings.showPercentInMenuBar, let worst else { return "" }
        return "\(worst.percent)%"
    }

    // MARK: - Off-main fetch (nonisolated: runs inside TaskGroup child tasks)

    nonisolated private static func fetch(account: Account, credentialStore: CredentialStore, usageClient: UsageClient) async -> AccountState {
        do {
            do {
                let token = try await credentialStore.accessToken(for: account)
                return .ok(try await usageClient.fetch(accessToken: token))
            } catch UsageError.unauthorized {
                // Claude Code rotates its token mid-poll sometimes (observed live: single 401,
                // fresh token already in the keychain seconds later). Re-read and retry once
                // before surfacing anything.
                fetchLog.info("401 for \(account.name, privacy: .public) — re-reading keychain and retrying once (rotation race)")
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let token = try await credentialStore.accessToken(for: account)
                return .ok(try await usageClient.fetch(accessToken: token))
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

    /// Always adds `~/.claude` if a keychain entry exists; globs `~/.claude-*` dirs and adds
    /// those with keychain entries too. Names come from `.claude.json`; unlabeled falls back
    /// to the directory basename — never dropped.
    private static func discoverLocalAccounts() -> [Account] {
        let home = NSHomeDirectory()
        let existingServices = Set(KeychainService.discoverClaudeServices())
        let labels = KeychainService.discoverLabels(home: home)

        var candidateDirs = ["\(home)/.claude"]
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: home) {
            candidateDirs += entries.filter { $0.hasPrefix(".claude-") }.map { "\(home)/\($0)" }
        }

        return candidateDirs.compactMap { dir in
            let service = KeychainService.serviceName(forConfigDir: dir, home: home)
            guard existingServices.contains(service) else { return nil }
            var fallback = (dir as NSString).lastPathComponent
            if fallback.hasPrefix(".") { fallback.removeFirst() }   // ".claude" reads better as "claude"
            let name = labels[service]?.email ?? fallback
            return Account(name: name, kind: .local(configDirPath: dir))
        }
    }
}

/// Off-main logger for the nonisolated fetch path (AppStore's own logger is MainActor-bound).
private let fetchLog = Logger(subsystem: "com.roy.claudemonitor", category: "poll")

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
