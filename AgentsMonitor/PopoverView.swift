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
            } else if store.accounts.count < 5 {
                // Plain VStack — a bare ScrollView collapses to zero height inside a
                // MenuBarExtra window (content-sized, no space to fill).
                cards
            } else {
                // From 5 accounts the cards outgrow the screen and push the footer (Settings, Quit)
                // off it. An explicit height is what keeps the ScrollView from collapsing.
                ScrollView { cards }
                    .frame(height: min(860, (NSScreen.main?.visibleFrame.height ?? 900) - 120))
            }
            Divider()
            footer
        }
        .frame(width: 440)
        .sheet(item: $repasteAccount) { account in
            RemoteCredentialsSheet(
                mode: .repaste(accountId: account.id, accountName: account.name),
                credentialStore: credentialStore
            )
        }
    }

    private var cards: some View {
        VStack(spacing: 10) {
            ForEach(store.accounts) { account in
                AccountCard(account: account, state: store.states[account.id] ?? .idle) {
                    repasteAccount = account
                }
            }
        }
        .padding(12)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No accounts yet", systemImage: "person.crop.circle.badge.plus")
        } description: {
            Text("Agents Monitor looks for Claude Code and Codex logins on this Mac.")
        } actions: {
            Button("Add Account…") { SettingsWindow.shared.show() }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            // Drops the word before it would cut the time to "Update…".
            if let last = store.lastRefresh {
                let time = last.formatted(date: .omitted, time: .shortened)
                ViewThatFits {
                    Text("Updated \(time)")
                    Text(time)
                }
                .lineLimit(1)
            } else {
                Text("Never refreshed").lineLimit(1)
            }
            Spacer(minLength: 0)
            // Explicit accessibility labels. Inspecting this popover over the accessibility API
            // showed the footer as three buttons with no title, which would leave VoiceOver
            // announcing them as anonymous. The tree here reports its children inconsistently
            // (69 elements one moment, none the next), so treat these as belt-and-braces rather
            // than a confirmed fix — they cost nothing and are correct either way.
            // Natural width: squeezed, the bordered buttons truncated to "Refr…", "Setti…".
            HStack(spacing: 8) {
                Button("Refresh") { Task { await store.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(store.isRefreshing)
                    .accessibilityLabel("Refresh")
                Button("Settings") { SettingsWindow.shared.show() }
                    .keyboardShortcut(",")
                    .accessibilityLabel("Settings")
                Button("About") { AboutInfo.showWindow() }
                Button("Support ☕") { NSWorkspace.shared.open(AboutInfo.kofi) }
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
                    .accessibilityLabel("Quit")
            }
            .fixedSize()
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
    @State private var flipped = RenderHooks.flipCards
    @State private var span: GraphSpan = .day
    private let store = AppStore.shared

    private var isLocal: Bool {
        if case .local = account.kind { return true }
        return false
    }

    /// The chart button turns the card over: bars on the front, the same rows as graphs on the
    /// back. The back is laid over the front, so the card keeps exactly its size.
    var body: some View {
        let angle = flipped ? 180.0 : 0
        face(back: false)
            .modifier(FlipFace(angle: angle, isBack: false))
            .overlay {
                face(back: true)
                    .modifier(FlipFace(angle: angle, isBack: true))
            }
    }

    private func face(back: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ProviderAccent(provider: account.provider)
            VStack(alignment: .leading, spacing: 8) {
                header(back: back)
                if back { graphs } else { content }
            }
            .frame(maxWidth: .infinity, maxHeight: back ? .infinity : nil, alignment: .topLeading)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var snapshot: UsageSnapshot? {
        switch state {
        case .ok(let snapshot), .stale(let snapshot, _): return snapshot
        default: return nil
        }
    }

    private func header(back: Bool) -> some View {
        HStack(spacing: 6) {
            Text(account.name).font(.headline)
            ProviderBadge(provider: account.provider)
            Text(isLocal ? "Local" : "Remote")
                .font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(.secondary)
            Spacer()
            if back {
                Button(span.rawValue) { span = span.next }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .help("Graph span — click for the next one")
            }
            if snapshot != nil {
                Button {
                    withAnimation(.easeInOut(duration: 0.45)) { flipped.toggle() }
                } label: {
                    Image(systemName: back ? "chart.bar.xaxis" : "chart.xyaxis.line").font(.caption)
                }
                .buttonStyle(.borderless)
                .help(back ? "Show bars" : "Show usage graphs")
                .accessibilityLabel(back ? "Show bars" : "Show usage graphs")
            }
            if case .stale = state {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Showing the last known numbers")
                    .accessibilityLabel("Numbers out of date")
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
            // The numbers can predate this launch (seeded from disk), so say how old they are.
            Text(Date().timeIntervalSince(snapshot.fetchedAt) < 60 ? error
                 : "\(error) · numbers from \(snapshot.fetchedAt.formatted(.relative(presentation: .numeric)))")
                .font(.caption2).foregroundStyle(.secondary)

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

    /// Only the symbol is tinted: 11 pt orange/red text is under 4.5:1 on the light card (CLR-5).
    private func statusLine(_ text: String, systemImage: String, color: Color) -> some View {
        Label {
            Text(text).foregroundStyle(color == .secondary ? Color.secondary : Color.primary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func snapshotRows(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(snapshot.limits) { limit in
                LimitRow(limit: limit,
                         full: projectedFull(AppStore.shared.points(for: account.id, label: limit.label), limit: limit))
            }
            // Hide the row entirely for accounts with no extra-usage budget and nothing spent.
            if let spend = snapshot.spend, spend.enabled,
               spend.limitMinor != nil || spend.usedMinor > 0 {
                SpendRow(spend: spend)
            }
        }
    }

    /// Back of the card: the front's rows, each as a graph over `span`.
    @ViewBuilder
    private var graphs: some View {
        if let snapshot {
            let since = Date().addingTimeInterval(-span.seconds)
            let samples = store.history[account.id] ?? []
            VStack(alignment: .leading, spacing: 8) {
                ForEach(snapshot.limits) { limit in
                    LimitGraphRow(label: limit.label, value: "\(limit.percent)%", color: limit.severity.tint,
                                  points: samples.compactMap { s in s.p[limit.label].map { (s.date, Double($0)) } },
                                  since: since)
                }
                if let spend = snapshot.spend, spend.enabled,
                   spend.limitMinor != nil || spend.usedMinor > 0 {
                    LimitGraphRow(label: "Spend", value: spend.usedFormatted, color: spend.severity.tint,
                                  points: samples.compactMap { s in s.spend.map { (s.date, Double($0)) } },
                                  since: since,
                                  domain: spend.limitMinor.map { 0...Double(max($0, 1)) })
                }
            }
        }
    }
}

// MARK: - Limit row (progress bar + pacing tick)

private struct LimitRow: View {
    let limit: LimitInfo
    /// When the recent pace runs it out before it resets (`projectedFull`).
    var full: Date?

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
                HStack(spacing: 4) {
                    Text("resets in \(Self.countdown(to: resetsAt))").foregroundStyle(.secondary)
                    if let full {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("full in ~\(Self.countdown(to: full)) at this pace").foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
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
