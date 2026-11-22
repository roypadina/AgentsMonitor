import AppKit
import OSLog
import SwiftUI

/// Real windows from a menu-bar-only app (MBX-15): Dock icon and menu bar while one is open, back to
/// `.accessory` when the last one closes. Toast panels can't become main, so they don't count.
@MainActor
final class AccessoryWindows: NSObject, NSWindowDelegate {
    static let shared = AccessoryWindows()
    static let log = Logger(subsystem: "com.roy.agentsmonitor", category: "activation")

    func show(_ window: NSWindow) {
        window.delegate = self
        NSApp.setActivationPolicy(.regular)
        // Forceful: a user action, and on macOS 14+ the front app can refuse the activate() request (window opens behind).
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        keepFront(window)
    }

    /// shortcut: ~0.5 s after the .accessory → .regular switch macOS hands activation back to the previous app (traced:
    /// Settings behind Ghostex, no click). Take it back once, within 1.5 s of the show, and only if there was no click or key
    /// press anywhere since (asked of the window server when activation goes, so no event monitor can lose the race: a click in
    /// Edge stole focus back, traced); drop when macOS stops. nil = Sparkle's update window.
    func keepFront(_ window: NSWindow?) {
        let shown = Date()
        var done = false
        let observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let elapsed = Date().timeIntervalSince(shown)
                let input = [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
                    .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? 0
                guard !done, elapsed < 1.5, input > elapsed, NSApp.activationPolicy() == .regular, window?.isVisible ?? true else { return }
                done = true
                Self.log.notice("keepFront: took activation back from \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-", privacy: .public) \(Int(elapsed * 1000)) ms after showing \(window?.title ?? "the update window", privacy: .public)")
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NotificationCenter.default.removeObserver(observer) }
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        let others = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.canBecomeMain }
        if !others { NSApp.setActivationPolicy(.accessory) }
    }
}

/// Own Settings window (MBX-16): `SettingsLink`/`openSettings` are unreliable in a menu-bar-only app, and
/// AppKit code (Welcome, reopen, the empty popover) cannot call them at all.
/// `NSTabViewController` keeps the tabs as toolbar icons; a SwiftUI `TabView` in a plain `NSWindow`
/// would draw in-window tabs instead.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    /// `tab`: the pane to open on, by label (the More page's Settings… opens "OpenRouter").
    func show(tab: String? = nil) {
        if window == nil {
            let tabs = SettingsTabs()
            tabs.tabStyle = .toolbar
            // Each pane gets its own height (SET-8): grouped forms have no intrinsic height. Measured offscreen:
            // Alerts needs ~850 (1.14.0 switches section +178), General ~760, OpenRouter ~800 with six keys showing and four rules (all fit below).
            add(tabs, "Accounts", "person.2", AccountsTab(), height: 500)
            add(tabs, "OpenRouter", "arrow.triangle.branch", OpenRouterTab(), height: 820)
            add(tabs, "Alerts", "bell", AlertsTab(), height: 860)
            add(tabs, "General", "gearshape", GeneralTab(), height: 760)
            add(tabs, "About", "info.circle", AboutTab(), height: 300)
            if let last = UserDefaults.standard.string(forKey: SettingsTabs.lastTabKey),  // reopen on the last pane (SET-3)
               let index = tabs.tabViewItems.firstIndex(where: { $0.label == last }) {
                tabs.selectedTabViewItemIndex = index
            }
            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable, .miniaturizable]  // keep .miniaturizable so the button dims, not vanishes
            w.title = tabs.tabViewItems[tabs.selectedTabViewItemIndex].label
            w.isReleasedWhenClosed = false
            w.standardWindowButton(.miniaturizeButton)?.isEnabled = false
            w.standardWindowButton(.zoomButton)?.isEnabled = false
            w.center()
            w.setFrameAutosaveName("SettingsWindow")
            window = w
            // Release the window on close: a kept-alive one keeps the panes (and their refreshes) alive.
            // Frame autosave and `settingsTab` restore the size and the pane on the next open.
            Task { @MainActor [weak self] in
                for await _ in NotificationCenter.default.notifications(named: NSWindow.willCloseNotification, object: w) { break }
                self?.window = nil
            }
        }
        if let tab, let tabs = window?.contentViewController as? NSTabViewController,
           let index = tabs.tabViewItems.firstIndex(where: { $0.label == tab }) {
            tabs.selectedTabViewItemIndex = index   // didSelect updates the title and the remembered pane
        }
        if let window { AccessoryWindows.shared.show(window) }
    }

    private func add(_ tabs: NSTabViewController, _ label: String, _ symbol: String, _ pane: some View, height: CGFloat) {
        let host = NSHostingController(rootView: pane.frame(width: 520, height: height))
        host.sizingOptions = .preferredContentSize  // the window follows the selected pane
        host.title = label
        let item = NSTabViewItem(viewController: host)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        tabs.addTabViewItem(item)
    }
}

/// Title follows the selected pane (SET-2); the pane is remembered for the next open (SET-3).
final class SettingsTabs: NSTabViewController {
    static let lastTabKey = "settingsTab"

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let label = tabViewItem?.label else { return }
        view.window?.title = label
        UserDefaults.standard.set(label, forKey: Self.lastTabKey)
    }
}
