import SwiftUI
import AppKit
import AgentsMonitorKit

/// One instance shared by every write here (Popover repaste + Settings' add/repaste flows) —
/// it's a stateless keychain writer, cheap to create once instead of per view instantiation.
private let credentialStore = CredentialStore()

@MainActor
struct PopoverView: View {
    private let store = AppStore.shared
    @State private var repasteAccount: Account?

    var body: some View {
        VStack(spacing: 0) {
            if store.accounts.isEmpty {
                emptyState
            } else {
                // Plain VStack — a ScrollView collapses to zero height inside a
                // MenuBarExtra window (content-sized, no space to fill).
                VStack(spacing: 10) {
                    ForEach(store.accounts) { account in
                        AccountCard(account: account, state: store.states[account.id] ?? .idle) {
                            repasteAccount = account
                        }
                    }
                }
                .padding(12)
            }
            Divider()
            footer
        }
        .frame(width: 360)
        .sheet(item: $repasteAccount) { account in
            RemoteCredentialsSheet(
                mode: .repaste(accountId: account.id, accountName: account.name),
                credentialStore: credentialStore
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No accounts yet").font(.headline)
            Text("Add one from Settings.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let last = store.lastRefresh {
                Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
            } else {
                Text("Never refreshed")
            }
            Spacer()
            // Explicit accessibility labels. Inspecting this popover over the accessibility API
            // showed the footer as three buttons with no title, which would leave VoiceOver
            // announcing them as anonymous. The tree here reports its children inconsistently
            // (69 elements one moment, none the next), so treat these as belt-and-braces rather
            // than a confirmed fix — they cost nothing and are correct either way.
            Button("Refresh") { Task { await store.refresh() } }
                .disabled(store.isRefreshing)
                .accessibilityLabel("Refresh")
            OpenSettingsButton()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .accessibilityLabel("Quit")
        }
        .font(.caption)
        .controlSize(.small)
        .padding(10)
    }
}

// MARK: - Account card

private struct AccountCard: View {
    let account: Account
    let state: AccountState
    var onRepaste: () -> Void

    private var isLocal: Bool {
        if case .local = account.kind { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ProviderAccent(provider: account.provider)
            VStack(alignment: .leading, spacing: 8) {
                header
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(account.name).font(.headline)
            ProviderBadge(provider: account.provider)
            Text(isLocal ? "Local" : "Remote")
                .font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(.secondary)
            Spacer()
            if case .stale = state {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            statusLine("Waiting for first refresh…", systemImage: "clock", color: .secondary)

        case .ok(let snapshot):
            snapshotRows(snapshot)

        case .stale(let snapshot, let error):
            snapshotRows(snapshot)
            Text(error)
                .font(.caption2).foregroundStyle(.orange)

        case .notLoggedIn:
            statusLine("Not logged in", systemImage: "person.crop.circle.badge.questionmark", color: .secondary)

        case .keychainDenied:
            statusLine("Keychain access denied", systemImage: "lock.slash", color: .orange)

        case .needsReauth:
            statusLine("Login token expired — \(account.provider.reauthHint)",
                       systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90", color: .red)

        case .needsCredentialsRepaste:
            VStack(alignment: .leading, spacing: 6) {
                statusLine("Credentials expired", systemImage: "key.slash", color: .red)
                Button("Paste credentials…", action: onRepaste)
                    .controlSize(.small)
            }

        case .rateLimited(let until):
            // Not the plan quota — this is the usage endpoint throttling our polling.
            statusLine("Usage API throttled — retrying \(until.formatted(date: .omitted, time: .shortened))",
                       systemImage: "hourglass", color: .orange)

        case .failed(let message):
            statusLine(message, systemImage: "xmark.octagon", color: .red)
        }
    }

    private func statusLine(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func snapshotRows(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(snapshot.limits) { limit in
                LimitRow(limit: limit)
            }
            // Hide the row entirely for accounts with no extra-usage budget and nothing spent.
            if let spend = snapshot.spend, spend.enabled,
               spend.limitMinor != nil || spend.usedMinor > 0 {
                SpendRow(spend: spend)
            }
        }
    }
}

// MARK: - Limit row (progress bar + pacing tick)

private struct LimitRow: View {
    let limit: LimitInfo

    private var color: Color {
        switch limit.severity {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private var pacing: Double? {
        guard let resetsAt = limit.resetsAt, limit.windowLength > 0 else { return nil }
        return pacingFraction(resetsAt: resetsAt, windowLength: limit.windowLength)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(limit.label).font(.caption)
                Spacer()
                Text("\(limit.percent)%").font(.caption.monospacedDigit())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    ProgressView(value: Double(limit.percent), total: 100)
                        .tint(color)
                        .frame(maxWidth: .infinity)
                    if let pacing {
                        // Thin tick marking where an even burn rate would be right now.
                        Rectangle()
                            .fill(Color.primary.opacity(0.6))
                            .frame(width: 1.5, height: 12)
                            .offset(x: max(0, geo.size.width * pacing - 0.75))
                    }
                }
            }
            .frame(height: 12)
            if let resetsAt = limit.resetsAt {
                Text("resets in \(Self.countdown(to: resetsAt))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private static func countdown(to date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

// MARK: - Spend row

private struct SpendRow: View {
    let spend: SpendInfo

    private var color: Color {
        switch spend.severity {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Spend").font(.caption)
                Spacer()
                if let limitFormatted = spend.limitFormatted {
                    Text("\(spend.usedFormatted) / \(limitFormatted) · \(spend.percent)%")
                        .font(.caption.monospacedDigit())
                } else {
                    Text(spend.usedFormatted).font(.caption.monospacedDigit())
                }
            }
            if spend.limitFormatted != nil {
                ProgressView(value: Double(spend.percent), total: 100)
                    .tint(color)
                    .frame(height: 12)
            }
        }
    }
}
