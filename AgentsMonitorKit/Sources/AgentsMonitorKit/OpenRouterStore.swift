import Foundation
import os

/// One poll's OpenRouter results, before they are merged into the store (design §7).
struct OpenRouterFetch: Sendable {
    var listing: [OpenRouterKeyUsage]?          // nil: no management key, or `/keys` failed
    var balance: OpenRouterBalance?
    var managementError: String?
    var pasted: [String: OpenRouterKeyUsage] = [:]
    var pastedErrors: [String: String] = [:]
}

/// A Settings action that failed; `errorDescription` is the inline text to show.
public struct OpenRouterSetupError: LocalizedError {
    public let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

private enum OpenRouterPart: Sendable {
    case listing(Result<[OpenRouterKeyUsage], Error>)
    case balance(Result<OpenRouterBalance, Error>)
    case pasted(String, Result<OpenRouterKeyUsage, Error>)
}

private func attempt<T>(_ body: () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}

/// Never log a key or a label: counts and status only.
private let openRouterLog = Logger(subsystem: "com.roy.agentsmonitor", category: "openrouter")

extension AppStore {
    // MARK: - Fetch (off-main)

    /// nil when nothing is configured (no network). One failing call never hides the others.
    nonisolated static func fetchOpenRouter(configs: [OpenRouterKeyConfig], managementKeyConfigured: Bool,
                                            client: OpenRouterClient) async -> OpenRouterFetch? {
        let pasted = configs.filter { $0.source == .pasted }
        guard managementKeyConfigured || !pasted.isEmpty else { return nil }
        var fetch = OpenRouterFetch()
        var managementKey: String?
        if managementKeyConfigured {
            do { managementKey = try openRouterSecret(OpenRouter.managementService) }
            catch { fetch.managementError = openRouterMessage(error, management: true) }
        }

        let parts = await withTaskGroup(of: OpenRouterPart.self) { group in
            if let managementKey {
                group.addTask { .listing(await attempt { try await client.listKeys(managementKey: managementKey) }) }
                group.addTask { .balance(await attempt { try await client.credits(managementKey: managementKey) }) }
            }
            for config in pasted {
                group.addTask {
                    .pasted(config.id, await attempt {
                        guard let uuid = OpenRouter.pastedUUID(from: config.id) else { throw CredentialError.notFound }
                        return try await client.key(apiKey: try openRouterSecret(OpenRouter.pastedService(uuid)), id: config.id)
                    })
                }
            }
            var all: [OpenRouterPart] = []
            for await part in group { all.append(part) }
            return all
        }

        for part in parts {
            switch part {
            case .listing(.success(let keys)): fetch.listing = keys
            case .balance(.success(let balance)): fetch.balance = balance
            case .pasted(let id, .success(let usage)): fetch.pasted[id] = usage
            case .listing(.failure(let error)), .balance(.failure(let error)):
                fetch.managementError = fetch.managementError ?? openRouterMessage(error, management: true)
            case .pasted(let id, .failure(let error)):
                fetch.pastedErrors[id] = openRouterMessage(error, management: false)
            }
        }
        return fetch
    }

    nonisolated private static func openRouterSecret(_ service: String) throws -> String {
        String(decoding: try KeychainService.readPayload(service: service), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Design §7 texts. Non-HTTP errors here are keychain reads.
    nonisolated static func openRouterMessage(_ error: Error, management: Bool) -> String {
        switch error as? UsageError {
        case .unauthorized?:
            return management ? "Management key expired — paste a new one in Settings" : "Key rejected — paste a new one in Settings"
        case .forbidden?:
            return management ? "That's not a management key — paste a management key in Settings" : "Key rejected — paste a new one in Settings"
        case let usageError?:
            return usageError.message(company: "OpenRouter")
        case nil:
            return management ? "Can't read the management key — paste it again in Settings" : "Can't read this key — paste it again in Settings"
        }
    }

    // MARK: - Apply (main actor)

    func applyOpenRouter(_ fetch: OpenRouterFetch?, now: Date) {
        guard var fetch, openRouterConfigured else { openRouterState = .idle; return }
        // Disconnected while the poll was in flight: its listing must not bring the managed keys back.
        if !settings.openRouter.managementKeyConfigured {
            fetch.listing = nil
            fetch.balance = nil
            fetch.managementError = nil
        }

        var configs = Self.mergedConfigs(openRouterKeys, listing: fetch.listing)
        for index in configs.indices {
            if let fresh = fetch.pasted[configs[index].id] { configs[index].lastLabel = fresh.label }
        }
        if configs != openRouterKeys {
            openRouterKeys = configs
            save()
        }

        let listed = Dictionary((fetch.listing ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previous = Dictionary((lastOpenRouterSnapshot?.keys ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let keys = configs.compactMap { config -> OpenRouterKeyUsage? in
            if let fresh = listed[config.id] ?? fetch.pasted[config.id] { return fresh }
            let error = config.source == .managed ? fetch.managementError : fetch.pastedErrors[config.id]
            guard let error else { return nil }   // added while this poll was in flight
            var failed = previous[config.id] ?? OpenRouterKeyUsage(id: config.id, name: config.lastName,
                                                                    label: config.lastLabel ?? "")
            failed.error = error
            return failed
        }
        let snapshot = OpenRouterSnapshot(keys: keys, balance: fetch.balance,
                                          managementError: fetch.managementError, fetchedAt: now)
        openRouterLog.info("openrouter: \(keys.count) key(s), balance \(fetch.balance != nil), errors \(fetch.pastedErrors.count + (fetch.managementError == nil ? 0 : 1))")

        let anySuccess = fetch.listing != nil || fetch.balance != nil || !fetch.pasted.isEmpty
        guard anySuccess else {
            let message = fetch.managementError
                ?? configs.lazy.compactMap { fetch.pastedErrors[$0.id] }.first
                ?? "Couldn't check OpenRouter"
            openRouterState = Self.preservingOpenRouter(.failed(message), last: lastOpenRouterSnapshot)
            return   // stale numbers were judged when they were live
        }
        lastOpenRouterSnapshot = snapshot
        openRouterState = .ok(snapshot)

        let cutoff = now.timeIntervalSince1970 - Double(OpenRouterHistory.keepDays) * 86400
        var newSamples: [OpenRouterSample] = []
        for key in keys where key.error == nil {
            guard Self.shouldSample(last: openRouterSamples[key.id]?.last, usage: key.usage, now: now) else { continue }
            let sample = OpenRouterSample(t: now.timeIntervalSince1970, id: key.id, u: key.usage)
            newSamples.append(sample)
            openRouterSamples[key.id, default: []].append(sample)
            openRouterSamples[key.id]?.removeAll { $0.t < cutoff }
        }
        openRouterHistory.append(newSamples)

        let names = Dictionary(configs.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let alerts = alertEngine.evaluateSpendRules(spendRules, snapshot: snapshot,
                                                    displayName: { names[$0] ?? "OpenRouter key" },
                                                    spent: { self.rollingSpent($0, $1, now: now) }, now: now)
        if !alerts.isEmpty {
            openRouterLog.info("firing \(alerts.count) spend alert(s)")
            onAlerts?(alerts, openRouterAccount)
        }
    }

    /// Mirrors `preservingSnapshot`: a failed poll keeps the last good numbers, with the failure text.
    nonisolated static func preservingOpenRouter(_ state: OpenRouterState, last: OpenRouterSnapshot?) -> OpenRouterState {
        guard let last, case .failed(let message) = state else { return state }
        return .stale(last, error: message)
    }

    /// `listing == nil` (no management key, or the call failed) changes nothing. Otherwise managed
    /// configs missing from the listing go, new ones are appended on the More page, names refresh.
    static func mergedConfigs(_ existing: [OpenRouterKeyConfig], listing: [OpenRouterKeyUsage]?) -> [OpenRouterKeyConfig] {
        guard let listing else { return existing }
        let listed = Dictionary(listing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged = existing.compactMap { config -> OpenRouterKeyConfig? in
            guard config.source == .managed else { return config }
            guard let usage = listed[config.id] else { return nil }
            var config = config
            config.lastName = usage.name
            config.lastLabel = usage.label
            return config
        }
        for usage in listing where !merged.contains(where: { $0.id == usage.id }) {
            merged.append(OpenRouterKeyConfig(id: usage.id, source: .managed, placement: .more,
                                              lastName: usage.name, lastLabel: usage.label))
        }
        return merged
    }

    /// Changed usage is written at most every `minGap`, unchanged usage at most every `flatGap`.
    static func shouldSample(last: OpenRouterSample?, usage: Double, now: Date) -> Bool {
        guard let last else { return true }
        let gap = now.timeIntervalSince1970 - last.t
        return gap >= (usage == last.u ? OpenRouterHistory.flatGap : OpenRouterHistory.minGap)
    }

    /// Spend alerts are delivered as this synthetic account (design D15).
    var openRouterAccount: Account {
        Account(id: OpenRouter.alertAccountId, name: "OpenRouter", kind: .remote, provider: .openrouter,
                desktopAlerts: settings.openRouter.desktopAlerts, ntfyEnabled: settings.openRouter.ntfyEnabled,
                ntfyTopicOverride: settings.openRouter.ntfyTopicOverride, placement: .hidden)
    }

    func setOpenRouterStateForTesting(_ state: OpenRouterState) {
        openRouterState = state
        if case .ok(let snapshot) = state { lastOpenRouterSnapshot = snapshot }
    }

    // MARK: - Settings-facing API

    /// Validates with `/credits` (a regular key gets 403), stores the key, polls at once.
    public func connectManagementKey(_ key: String) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OpenRouterSetupError("Paste a management key first.") }
        do {
            _ = try await openRouterClient.credits(managementKey: key)
        } catch UsageError.forbidden {
            throw OpenRouterSetupError("That's a regular API key, not a management key.")
        } catch UsageError.unauthorized {
            throw OpenRouterSetupError("OpenRouter rejected this key.")
        } catch let error as UsageError {
            throw OpenRouterSetupError(error.message(company: "OpenRouter") + ".")
        }
        do {
            try KeychainService.writeOwnedPayload(Data(key.utf8), service: OpenRouter.managementService)
        } catch {
            throw OpenRouterSetupError("Couldn't save the key in the Keychain.")
        }
        settings.openRouter.managementKeyConfigured = true
        save()
        await refresh(force: true)
    }

    /// The listing's keys go with it; pasted keys stay. Numbers update on the next refresh.
    public func disconnectManagementKey() {
        KeychainService.deleteOwnedPayload(service: OpenRouter.managementService)
        settings.openRouter.managementKeyConfigured = false
        openRouterKeys.removeAll { $0.source == .managed }
        save()
        if !openRouterConfigured { openRouterState = .idle }
    }

    /// Validates with `/key`, stores the secret under a new UUID, appends the key, polls at once.
    public func addPastedKey(_ secret: String, nickname: String?) async throws {
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw OpenRouterSetupError("Paste a key first.") }
        let uuid = UUID()
        let id = OpenRouter.pastedId(uuid)
        let usage: OpenRouterKeyUsage
        do {
            usage = try await openRouterClient.key(apiKey: secret, id: id)
        } catch UsageError.unauthorized, UsageError.forbidden {
            throw OpenRouterSetupError("OpenRouter rejected this key.")
        } catch let error as UsageError {
            throw OpenRouterSetupError(error.message(company: "OpenRouter") + ".")
        }
        do {
            try KeychainService.writeOwnedPayload(Data(secret.utf8), service: OpenRouter.pastedService(uuid))
        } catch {
            throw OpenRouterSetupError("Couldn't save the key in the Keychain.")
        }
        let nickname = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        openRouterKeys.append(OpenRouterKeyConfig(id: id, source: .pasted,
                                                  nickname: nickname?.isEmpty == false ? nickname : nil,
                                                  lastName: usage.name, lastLabel: usage.label))
        save()
        await refresh(force: true)
    }

    /// Pasted: the secret and the config go. Managed keys come back with every listing, so they are hidden.
    public func removeKey(id: String) {
        guard let index = openRouterKeys.firstIndex(where: { $0.id == id }) else { return }
        if openRouterKeys[index].source == .managed {
            openRouterKeys[index].placement = .hidden
        } else {
            if let uuid = OpenRouter.pastedUUID(from: id) {
                KeychainService.deleteOwnedPayload(service: OpenRouter.pastedService(uuid))
            }
            openRouterKeys.remove(at: index)
        }
        save()
    }

    public func setPlacement(_ placement: Placement, forKey id: String) {
        guard let index = openRouterKeys.firstIndex(where: { $0.id == id }) else { return }
        openRouterKeys[index].placement = placement
        save()
    }

    /// Empty clears the nickname (back to OpenRouter's name or the masked label).
    public func setNickname(_ nickname: String?, forKey id: String) {
        guard let index = openRouterKeys.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        openRouterKeys[index].nickname = trimmed?.isEmpty == false ? trimmed : nil
        save()
    }

    /// `List.onMove` semantics: `destination` is an index in the list before the move.
    public func moveKeys(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { openRouterKeys[$0] }
        var rest = openRouterKeys.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        rest.insert(contentsOf: moving, at: destination - source.filter { $0 < destination }.count)
        openRouterKeys = rest
        save()
    }

    public func setPlacement(_ placement: Placement, forAccount id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].placement = placement
        save()
    }

    // MARK: - Placement-resolved lists (design §11)

    public var popoverAccounts: [Account] { accounts.filter { $0.placement.showsInPopover } }
    /// Accounts placed on the More page itself (Main already shows the others).
    public var moreAccounts: [Account] { accounts.filter { $0.placement == .more } }
    public var popoverKeys: [OpenRouterKeyConfig] { openRouterKeys.filter { $0.placement.showsInPopover } }
    /// Every key the More page lists: all but hidden ones.
    public var moreKeys: [OpenRouterKeyConfig] { openRouterKeys.filter { $0.placement.showsOnMore } }
    public var hiddenKeyCount: Int { openRouterKeys.filter { $0.placement == .hidden }.count }
    public var openRouterConfigured: Bool { settings.openRouter.managementKeyConfigured || !openRouterKeys.isEmpty }
    public var showsMoreEntry: Bool { openRouterConfigured || !moreAccounts.isEmpty }

    /// The last good snapshot (live or stale), whatever its age.
    public var openRouterSnapshot: OpenRouterSnapshot? {
        switch openRouterState {
        case .ok(let snapshot), .stale(let snapshot, _): return snapshot
        case .idle, .failed: return nil
        }
    }

    public func keyUsage(_ id: String) -> OpenRouterKeyUsage? {
        openRouterSnapshot?.keys.first { $0.id == id }
    }

    /// Cap percent; else the highest spend-rule ratio (value / threshold × 100, clamped) over the
    /// enabled rules for this key ("each key" or this key); else nil — no line, no dot (design D11).
    public func openRouterPercent(for id: String) -> Int? {
        guard let usage = keyUsage(id), usage.error == nil else { return nil }
        if let cap = usage.capPercent { return cap }
        let ratios = spendRules.compactMap { rule -> Double? in
            guard rule.enabled, rule.kind == .spend, rule.threshold > 0 else { return nil }
            switch rule.scope {
            case .eachKey: break
            case .key(let keyId) where keyId == id: break
            default: return nil
            }
            return rollingSpent(id, rule.window).map { $0 / rule.threshold * 100 }
        }
        return ratios.max().map { min(max(Int($0.rounded()), 0), 100) }
    }

    /// Spend of one key in any window: rolling ones from the local history, calendar ones from OpenRouter.
    public func rollingSpent(_ id: String, _ window: SpendWindow, now: Date = Date()) -> Double? {
        guard let usage = keyUsage(id) else { return nil }
        guard window.isRolling else { return usage.spend(in: window) }
        return openRouterSpent(samples: openRouterSamples[id] ?? [], since: window.start(now: now),
                               nowUsage: usage.usage)?.usd
    }

    // MARK: - Menu bar (design §4.5)

    /// "o" + the digits in the display name; any collision numbers them all `o1…oN`.
    public static func openRouterTags(for keys: [OpenRouterKeyConfig]) -> [String: String] {
        var tags = keys.reduce(into: [String: String]()) { $0[$1.id] = "o" + $1.displayName.filter(\.isNumber) }
        if Set(tags.values).count != keys.count {
            for (index, key) in keys.enumerated() { tags[key.id] = "o\(index + 1)" }
        }
        return tags
    }

    /// Menu-bar keys (config order), then the balance. Numbers past `menuBarMaxAge` leave, as for accounts.
    var openRouterMenuBarSegments: [MenuBarSegment] {
        let snapshot: OpenRouterSnapshot
        switch openRouterState {
        case .ok(let live): snapshot = live
        case .stale(let old, _) where Date().timeIntervalSince(old.fetchedAt) < Self.menuBarMaxAge: snapshot = old
        default: return []
        }
        let shown = openRouterKeys.filter { $0.placement.showsInMenuBar }
        let tags = Self.openRouterTags(for: shown)
        var segments = shown.compactMap { config -> MenuBarSegment? in
            guard let usage = snapshot.keys.first(where: { $0.id == config.id }), usage.error == nil else { return nil }
            let percent = openRouterPercent(for: config.id)
            let text = (settings.showPercentInMenuBar ? percent.map { "\($0)%" } : nil)
                ?? OpenRouter.formatUSDCompact(usage.usageDaily)
            return MenuBarSegment(id: config.id, tag: tags[config.id], dotPercent: percent,
                                  showDot: settings.menuBarBlockedDot && percent != nil, text: text)
        }
        if settings.openRouter.balancePlacement.showsInMenuBar, let balance = snapshot.balance {
            segments.append(MenuBarSegment(id: "openrouter-balance", tag: nil, dotPercent: nil, showDot: false,
                                           text: OpenRouter.money(balance.usd, fractionDigits: 0)))
        }
        return segments
    }
}
