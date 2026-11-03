import SwiftUI
import AgentsMonitorKit

// Fixed chip slots keep the bars in columns down the popover, whatever chips a row has.
private let chipWidth: CGFloat = 84
private let chipSpacing: CGFloat = 8

// MARK: - Compact account row (design §4.1)

/// One line per account (name, provider mark, up to three meter chips) and a second line only when
/// something needs attention. The whole tile is the Show details button; `AccountCard` replaces it
/// when expanded.
@MainActor
struct AccountRow: View {
    let account: Account
    let state: AccountState
    var onToggle: () -> Void
    var onRepaste: () -> Void
    private let store = AppStore.shared

    private var snapshot: UsageSnapshot? {
        switch state {
        case .ok(let snapshot), .stale(let snapshot, _): return snapshot
        default: return nil
        }
    }

    var body: some View {
        let note = compactNote(account: account, state: state)
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 6) {
                ProviderAccent(provider: account.provider)
                VStack(alignment: .leading, spacing: 3) {
                    line1
                    if let note { noteLine(note) }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(note?.text ?? "no warnings")
        .accessibilityAction(named: "Show details", onToggle)
        // A sibling on top, not inside the row button: nested buttons do not fire.
        .overlay(alignment: .bottomTrailing) {
            if case .needsCredentialsRepaste = state {
                Button("Paste credentials…", action: onRepaste)
                    .controlSize(.small)
                    .padding(.trailing, 8).padding(.bottom, 5)
            }
        }
    }

    private var line1: some View {
        HStack(spacing: 6) {
            Text(account.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(width: 90, alignment: .leading)
                .help(account.name)
            ProviderBadge(provider: account.provider,
                          style: store.settings.providerBadge == .hidden ? .hidden : .icon)
            if case .stale = state {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Showing the last known numbers")
            }
            Spacer(minLength: 0)
            HStack(spacing: chipSpacing) {
                ForEach(snapshot?.compactLimits ?? []) { MeterChip(limit: $0) }
            }
            .frame(width: 3 * chipWidth + 2 * chipSpacing, alignment: .leading)
            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func noteLine(_ note: CompactNote) -> some View {
        HStack(spacing: 4) {
            if let symbol = note.symbol {
                Image(systemName: symbol).foregroundStyle(note.color)
            }
            Text(note.text).foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.caption2)
        .help(note.tooltip ?? note.text)
    }

    /// "claude3, Claude, Session 52%, Week 12%, Week Fable 7%" (design §12).
    private var accessibilityLabel: String {
        let chips = (snapshot?.compactLimits ?? []).map {
            "\($0.label.replacingOccurrences(of: " · ", with: " ")) \($0.percent)%"
        }
        return ([account.name, account.provider.displayName] + chips).joined(separator: ", ")
    }
}

// MARK: - Meter chip

/// Tag · 36 pt severity-tinted bar · percent. The bar is decoration for VoiceOver; the text carries the value.
struct MeterChip: View {
    let limit: LimitInfo

    var body: some View {
        HStack(spacing: 3) {
            Text(limit.shortTag)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(minWidth: 14, alignment: .leading)
            ProgressView(value: Double(min(limit.percent, 100)), total: 100)
                .tint(limit.severity.tint)
                .frame(width: 36)
                .accessibilityHidden(true)
            Text("\(limit.percent)%")
                .font(.caption.monospacedDigit())
                .fixedSize()
                .frame(minWidth: 28, alignment: .trailing)
        }
        .frame(width: chipWidth, alignment: .leading)
        .help(help)
    }

    private var help: String {
        let resets = limit.resetsAt.map { " · resets in \(shortCountdown(to: $0))" } ?? ""
        return "\(limit.label) · \(limit.percent)%\(resets)"
    }
}

// MARK: - Line 2

/// What line 2 of a compact row says. `symbol` nil = no glyph (the stale ⚠ already sits in line 1).
typealias CompactNote = (symbol: String?, color: Color, text: String, tooltip: String?)

/// Line 2 of a compact row, first match wins (design §4.1 table); nil when the account is calm.
@MainActor
func compactNote(account: Account, state: AccountState) -> CompactNote? {
    switch state {
    case .idle:
        return ("clock", .secondary, "Waiting for first refresh…", nil)
    case .notLoggedIn:
        return ("person.crop.circle.badge.questionmark", .secondary, "Not logged in", nil)
    case .keychainDenied:
        return ("lock.slash", .orange, "Keychain access denied", nil)
    case .needsReauth:
        return ("exclamationmark.arrow.trianglehead.2.clockwise.rotate.90", .red,
                "Login token expired — \(account.provider.reauthHintShort)",
                "Login token expired — \(account.provider.reauthHint)")
    case .needsCredentialsRepaste:
        return ("key.slash", .red, "Credentials expired", nil)
    case .rateLimited(let until):
        return ("hourglass", .orange, "Usage API throttled — retrying \(until.formatted(date: .omitted, time: .shortened))", nil)
    case .failed(let message):
        return ("xmark.octagon", .red, message, nil)
    case .stale(let snapshot, let error):
        // Same text as the card: the numbers can predate this launch, so say how old they are.
        return (nil, .secondary, Date().timeIntervalSince(snapshot.fetchedAt) < 60 ? error
                : "\(error) · numbers from \(snapshot.fetchedAt.formatted(.relative(presentation: .numeric)))", nil)
    case .ok(let snapshot):
        let store = AppStore.shared
        if let hit = snapshot.attentionLimit(thresholds: store.settings.thresholds, projectedFull: {
            projectedFull(store.points(for: account.id, label: $0.label), limit: $0)
        }) {
            var text = "\(hit.limit.label) \(hit.limit.percent)%"
            if let resetsAt = hit.limit.resetsAt { text += " · resets in \(shortCountdown(to: resetsAt))" }
            if let full = hit.full { text += " · full in ~\(shortCountdown(to: full)) at this pace" }
            if hit.limit.percent >= 100 { return ("nosign", .red, text, nil) }
            return ("exclamationmark.triangle.fill", hit.severity == .critical ? .red : .orange, text, nil)
        }
        if let spend = snapshot.spend, spend.enabled, spend.severity >= .warning {
            let of = spend.limitFormatted.map { " of \($0)" } ?? ""
            return ("exclamationmark.triangle.fill", spend.severity.tint, "Extra usage \(spend.usedFormatted)\(of)", nil)
        }
        return nil
    }
}
