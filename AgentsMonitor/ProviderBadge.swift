import SwiftUI
import AgentsMonitorKit

extension Provider {
    /// The Kit hands over sRGB components so it never has to import SwiftUI — see `tintRGB`.
    var tint: Color {
        let (red, green, blue) = tintRGB
        return Color(.sRGB, red: red, green: green, blue: blue)
    }
}

/// "Which agent is this account?" — shown next to every account name in the popover and in
/// Settings. Style comes from Settings → General, so an account list of one provider can drop it
/// entirely, and a mixed list can run icon-only once the colors are learned.
///
/// The tint stays on this badge and the account name only. Limit bars and the usage dot are
/// severity-colored, and tinting those by provider would read as a health signal.
@MainActor
struct ProviderBadge: View {
    let provider: Provider
    var style: ProviderBadgeStyle = AppStore.shared.settings.providerBadge
    var colored: Bool = AppStore.shared.settings.providerColors

    var body: some View {
        if style != .hidden {
            HStack(spacing: 3) {
                if style.showsIcon {
                    Image(systemName: provider.iconSystemName)
                        .font(.system(size: 9, weight: .bold))
                }
                if style.showsName {
                    Text(provider.displayName)
                }
            }
            .font(.caption2)
            .padding(.horizontal, style == .icon ? 4 : 5)
            .padding(.vertical, 1.5)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
            .accessibilityLabel(provider.displayName)
        }
    }

    private var background: Color {
        colored ? provider.tint.opacity(0.18) : Color.secondary.opacity(0.15)
    }

    /// `.secondary` when uncolored; the tint itself otherwise. Not `.white` on a solid fill —
    /// the capsule is deliberately faint so the badge never outshouts the usage numbers.
    private var foreground: Color {
        colored ? provider.tint : Color.secondary
    }
}

/// A 3pt stripe down the leading edge of an account card. Carries the provider color further
/// than the badge can — visible while scanning the popover without reading anything — and does
/// it without tinting the account name, which only costs legibility.
@MainActor
struct ProviderAccent: View {
    let provider: Provider

    var body: some View {
        if AppStore.shared.settings.providerColors && AppStore.shared.settings.providerBadge != .hidden {
            Capsule().fill(provider.tint).frame(width: 3)
        }
    }
}
