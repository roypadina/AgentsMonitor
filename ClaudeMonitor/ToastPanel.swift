import AppKit
import SwiftUI
import ClaudeMonitorKit

/// Floating, non-activating toast that slides in from the top-right and auto-dismisses.
/// Multiple toasts stack vertically; dismissing one closes the gap for the ones below it.
@MainActor
enum ToastPanel {
    private static var active: [NSPanel] = []
    private static let width: CGFloat = 320
    private static let height: CGFloat = 64
    private static let gap: CGFloat = 8
    private static let margin: CGFloat = 12

    static func show(_ alert: ClaudeMonitorKit.Alert) {
        guard let screen = NSScreen.main else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.contentView = NSHostingView(rootView: ToastContent(alert: alert))

        let endFrame = frame(forIndex: active.count, screen: screen)
        let startFrame = endFrame.offsetBy(dx: width + margin, dy: 0)
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        active.append(panel)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().setFrame(endFrame, display: true)
            panel.animator().alphaValue = 1
        }

        if AppStore.shared.settings.soundEnabled {
            NSSound(named: alert.level == .critical ? "Basso" : "Glass")?.play()
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            dismiss(panel)
        }
    }

    private static func dismiss(_ panel: NSPanel) {
        guard let idx = active.firstIndex(of: panel) else { return }
        active.remove(at: idx)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
        reflow()
    }

    private static func reflow() {
        guard let screen = NSScreen.main else { return }
        for (i, panel) in active.enumerated() {
            let target = frame(forIndex: i, screen: screen)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().setFrame(target, display: true)
            }
        }
    }

    private static func frame(forIndex index: Int, screen: NSScreen) -> NSRect {
        let x = screen.visibleFrame.maxX - width - margin
        let y = screen.visibleFrame.maxY - margin - CGFloat(index + 1) * (height + gap) + gap
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

private struct ToastContent: View {
    let alert: ClaudeMonitorKit.Alert

    private var accent: Color {
        switch alert.level {
        case .critical: return .red
        case .warning: return .orange
        case .none: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(accent).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title).font(.subheadline.bold())
                Text(alert.body).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 320, height: 64, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}
