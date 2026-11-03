import SwiftUI
import AgentsMonitorKit

/// The OpenRouter-wide problem to flag next to the summary: a failed poll showing old numbers (⚠), or an
/// error (management key, nothing reachable). Which error it is lives in the words, not the glyph.
@MainActor
private func openRouterProblem(_ store: AppStore) -> (symbol: String, color: Color, text: String, stale: Bool)? {
    switch store.openRouterState {
    case .idle: return nil
    case .stale(let snapshot, let error):
        return ("exclamationmark.triangle.fill", .orange,
                "\(error) · numbers from \(snapshot.fetchedAt.formatted(.relative(presentation: .numeric)))", true)
    case .failed(let message): return ("xmark.octagon", .red, message, false)
    case .ok(let snapshot): return snapshot.managementError.map { ("xmark.octagon", .red, $0, false) }
    }
}

@MainActor
private func openRouterSummary(_ store: AppStore) -> String {
    AppStore.openRouterSummary(state: store.openRouterState, keyCount: store.openRouterKeys.count,
                               showBalance: store.settings.openRouter.balancePlacement != .hidden)
}

// MARK: - Main page header row (design §4.1)

/// "OpenRouter  balance $42.17 · $3.20 today · 14 keys  ›" — the way to the More page.
@MainActor
struct OpenRouterHeaderRow: View {
    var onOpenMore: () -> Void
    private let store = AppStore.shared

    private var title: String { store.openRouterConfigured ? "OpenRouter" : "More" }
    private var summary: String {
        if store.openRouterConfigured { return openRouterSummary(store) }
        return store.moreAccounts.count == 1 ? "1 account" : "\(store.moreAccounts.count) accounts"
    }

    var body: some View {
        let problem = store.openRouterConfigured ? openRouterProblem(store) : nil
        Button(action: onOpenMore) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(summary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let problem {
                    Image(systemName: problem.symbol)
                        .font(.caption2)
                        .foregroundStyle(problem.color)
                        .help(problem.text)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Show every key")
        .accessibilityLabel(title)
        .accessibilityValue([summary, problem?.text].compactMap { $0 }.joined(separator: ", "))
    }
}

// MARK: - Key row (design §4.1, §4.2)

/// Name, masked label and today / week / month spend (OpenRouter's UTC calendar); line 2 for a cap or
/// an error. `showsMenu` adds the ⋯ placement menu (More page).
@MainActor
struct OpenRouterKeyRow: View {
    let config: OpenRouterKeyConfig
    var showsMenu = false
    private let store = AppStore.shared

    var body: some View {
        let usage = store.keyUsage(config.id)
        HStack(spacing: 6) {
            ProviderAccent(provider: .openrouter)
            VStack(alignment: .leading, spacing: 3) {
                line1(usage)
                if let usage { line2(usage) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(config.displayName), OpenRouter")
            .accessibilityValue(accessibilityValue(usage))
            if showsMenu { placementMenu }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func line1(_ usage: OpenRouterKeyUsage?) -> some View {
        HStack(spacing: 6) {
            Text(config.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(width: 90, alignment: .leading)
                .help(config.displayName)
            if let label = maskedLabel(usage) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 64, alignment: .leading)
                    .help(label)
            }
            Spacer(minLength: 0)
            if usage?.error == nil {
                // No numbers yet (first poll of a launch): the same text as a placeholder, not zeros.
                Text(money(usage ?? OpenRouterKeyUsage(id: config.id, label: "")))
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
                    .redacted(reason: usage == nil ? .placeholder : [])
            }
        }
    }

    @ViewBuilder
    private func line2(_ usage: OpenRouterKeyUsage) -> some View {
        if let error = usage.error {
            HStack(spacing: 4) {
                Image(systemName: "xmark.octagon").foregroundStyle(.red)
                Text(error).foregroundStyle(.secondary).lineLimit(1).help(error)
            }
            .font(.caption2)
        } else if let percent = usage.capPercent, let cap = capText(usage) {
            HStack(spacing: 4) {
                Text("cap").foregroundStyle(.secondary)
                ProgressView(value: Double(percent), total: 100)
                    .tint(usage.capSeverity.tint)
                    .frame(width: 60)
                Text(cap).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            .font(.caption2)
        }
    }

    /// OpenRouter's own masked form, shortened to its tail ("sk-or-v1-abc...123" → "sk-or-…123"): the tail
    /// is what tells keys apart. Skipped when the label already is the name.
    private func maskedLabel(_ usage: OpenRouterKeyUsage?) -> String? {
        Self.maskedLabel(usage?.label ?? config.lastLabel, displayName: config.displayName)
    }

    /// Also used by Settings → OpenRouter.
    static func maskedLabel(_ label: String?, displayName: String) -> String? {
        guard let label, !label.isEmpty, label != displayName else { return nil }
        guard let tail = label.components(separatedBy: "...").last, tail != label else { return label }
        return (label.hasPrefix("sk-or-") ? "sk-or-…" : "…") + tail
    }

    private func money(_ usage: OpenRouterKeyUsage) -> String {
        "Today \(OpenRouter.formatUSDCompact(usage.usageDaily)) · Week \(OpenRouter.formatUSDCompact(usage.usageWeekly))"
            + " · Month \(OpenRouter.formatUSDCompact(usage.usageMonthly))"
    }

    /// "$12.00 of $20.00 · resets daily in 4h 12m".
    private func capText(_ usage: OpenRouterKeyUsage) -> String? {
        guard let total = usage.capTotal, let remaining = usage.capRemaining else { return nil }
        var text = "\(OpenRouter.formatUSD(max(total - remaining, 0))) of \(OpenRouter.formatUSD(total))"
        if let resetsAt = usage.capResetsAt(now: Date()) {
            let interval = (usage.limitReset ?? usage.budget?.resetInterval).map { "\($0) " } ?? ""
            text += " · resets \(interval)in \(shortCountdown(to: resetsAt))"
        }
        return text
    }

    private func accessibilityValue(_ usage: OpenRouterKeyUsage?) -> String {
        guard let usage else { return "checking" }
        if let error = usage.error { return error }
        var parts = ["\(OpenRouter.formatUSD(usage.usageDaily)) today", "\(OpenRouter.formatUSD(usage.usageWeekly)) this week",
                     "\(OpenRouter.formatUSD(usage.usageMonthly)) this month"]
        if usage.capPercent != nil, let cap = capText(usage) { parts.append("cap \(cap)") }
        return parts.joined(separator: ", ")
    }

    /// The current placement is checked; Hidden takes the key off this page (Settings brings it back).
    private var placementMenu: some View {
        Menu {
            Picker("Placement", selection: Binding(get: { config.placement },
                                                   set: { store.setPlacement($0, forKey: config.id) })) {
                ForEach(Placement.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Placement")
        .accessibilityLabel("Placement")
    }
}

// MARK: - More page (design §4.2)

/// Accounts placed on the More page and every OpenRouter key that is not hidden, in the same window.
@MainActor
struct MorePage: View {
    @Binding var filter: String
    var onBack: () -> Void
    var onRepaste: (Account) -> Void
    private let store = AppStore.shared

    private var query: String { filter.trimmingCharacters(in: .whitespaces) }

    /// Name, nickname and label, case-insensitive; only offered past eight keys.
    private var keys: [OpenRouterKeyConfig] {
        guard store.moreKeys.count > 8, !query.isEmpty else { return store.moreKeys }
        return store.moreKeys.filter { config in
            [config.nickname, config.lastName, config.lastLabel].contains { $0?.localizedCaseInsensitiveContains(query) == true }
        }
    }

    private var isEmpty: Bool {
        let checking = store.openRouterState == .idle && store.openRouterConfigured
        return store.moreKeys.isEmpty && store.moreAccounts.isEmpty && !checking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(12)
            if isEmpty {
                ContentUnavailableView {
                    Label("No keys", systemImage: "arrow.triangle.branch")
                } description: {
                    Text(store.hiddenKeyCount > 0
                         ? "\(hiddenKeys) — show them again in Settings › OpenRouter."
                         : "Connect a management key or add keys in Settings › OpenRouter.")
                } actions: {
                    Button("Open Settings…") { SettingsWindow.shared.show(tab: "OpenRouter") }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if store.openRouterConfigured { summary }
                    if store.moreKeys.count > 8 {
                        TextField("Filter keys", text: $filter)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                CappedScroll(maxHeight: 520) { list }
                if store.openRouterConfigured {
                    Text("Day, week and month follow OpenRouter's UTC calendar."
                         + (store.hiddenKeyCount > 0 ? " \(hiddenKeys) — see Settings." : ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding([.horizontal, .bottom], 12)
                }
            }
        }
    }

    private var hiddenKeys: String { store.hiddenKeyCount == 1 ? "1 hidden key" : "\(store.hiddenKeyCount) hidden keys" }

    private var header: some View {
        HStack {
            Button(action: onBack) { Label("Back", systemImage: "chevron.left") }
                .keyboardShortcut("[", modifiers: .command)
                .help("Back (⌘[)")
            Spacer()
            Button("Settings…") { SettingsWindow.shared.show(tab: "OpenRouter") }
        }
        .buttonStyle(.borderless)
        .overlay {
            Text("More").font(.headline).accessibilityAddTraits(.isHeader)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("OpenRouter").font(.subheadline.weight(.semibold))
                Text("· \(openRouterSummary(store))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            if let problem = openRouterProblem(store) {
                HStack(spacing: 4) {
                    Image(systemName: problem.symbol).foregroundStyle(problem.color)
                    Text(problem.text).foregroundStyle(.secondary).lineLimit(2)
                    if problem.stale {
                        Button("Try Again") { Task { await store.refresh() } }
                            .controlSize(.small)
                            .disabled(store.isRefreshing)
                    }
                }
                .font(.caption2)
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(keys) { OpenRouterKeyRow(config: $0, showsMenu: true) }
            if keys.isEmpty && !query.isEmpty {
                Text("No keys match “\(query)”.").font(.caption).foregroundStyle(.secondary)
            }
            if !store.moreAccounts.isEmpty {
                Text("Accounts")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .accessibilityAddTraits(.isHeader)
                AccountList(accounts: store.moreAccounts, onRepaste: onRepaste)
            }
        }
        .padding(12)
    }
}
