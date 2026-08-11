import SwiftUI
import AppKit
import ClaudeMonitorKit

/// The menu bar label: one usage dot per account, followed by the accounts' numbers.
///
/// Two children, deliberately: a `MenuBarExtra` label renders at most one image and one text —
/// verified on screen, where a `ForEach` of per-account groups silently collapsed to the first
/// image and first text. So every dot goes into a single composite image, in the same
/// left-to-right order as the text segments.
@MainActor
struct MenuBarLabel: View {
    private var segments: [AppStore.MenuBarSegment] { AppStore.shared.menuBarSegments }

    var body: some View {
        let segments = self.segments
        let dots = segments.filter(\.showDot)
        let text = segments.compactMap { segment -> String? in
            let parts = [segment.tag, segment.text.isEmpty ? nil : segment.text].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }.joined(separator: " · ")

        HStack(spacing: 4) {
            if !dots.isEmpty {
                Image(nsImage: UsageDot.composite(percents: dots.map(\.dotPercent),
                                                  diameter: text.isEmpty ? 11 : 9))
            } else if text.isEmpty {
                Image(systemName: "gauge")   // never leave the item invisible/unclickable
            }
            if !text.isEmpty {
                Text(text)
            }
        }
    }
}

enum UsageDot {
    /// Green at 0% through yellow to red at 100%, so the color alone reads as how much is left.
    /// nil (no data yet) is gray — an unknown state must not look like a healthy one.
    static func color(percent: Int?) -> NSColor {
        guard let percent else { return NSColor(white: 0.62, alpha: 1) }
        let fraction = min(max(Double(percent) / 100, 0), 1)
        // Hue 0.33 (green) -> 0.0 (red), passing through yellow near the midpoint.
        return NSColor(hue: 0.33 * (1 - fraction), saturation: 0.95, brightness: 0.9, alpha: 1)
    }

    static func composite(percents: [Int?], diameter: CGFloat, gap: CGFloat = 3) -> NSImage {
        let count = max(percents.count, 1)
        let width = CGFloat(count) * diameter + CGFloat(count - 1) * gap
        let image = NSImage(size: NSSize(width: width, height: diameter), flipped: false) { _ in
            for (index, percent) in percents.enumerated() {
                let origin = CGFloat(index) * (diameter + gap)
                let box = NSRect(x: origin, y: 0, width: diameter, height: diameter)
                color(percent: percent).setFill()
                NSBezierPath(ovalIn: box.insetBy(dx: 0.5, dy: 0.5)).fill()
            }
            return true
        }
        // A template image would be flattened to a monochrome mask, which would throw away the
        // gradient that is the entire point here.
        image.isTemplate = false
        image.accessibilityDescription = percents
            .map { $0.map { "\($0)% used" } ?? "no data" }
            .joined(separator: ", ")
        return image
    }
}
