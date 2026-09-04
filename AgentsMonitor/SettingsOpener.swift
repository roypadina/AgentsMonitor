import SwiftUI
import AppKit
import os

/// Opening the Settings scene from a menu-bar-only app takes more than asking for it.
///
/// `SettingsLink` — and the `openSettings` action it wraps — order the Settings window front
/// *within* the calling app. This app is `LSUIElement`, so it is an **accessory** app: it is
/// never the active application, and a window ordered front inside an inactive app stays behind
/// every other window. From the user's side that is indistinguishable from the button doing
/// nothing at all, which is exactly how it was reported.
///
/// So: activate first, ask second, and then make sure the window really is in front — SwiftUI
/// gives no callback to check, and `openSettings()` reports no failure when it silently doesn't
/// surface. `orderFrontRegardless()` is the one that does the work for an accessory app.
@MainActor
enum SettingsOpener {
    private static let log = Logger(subsystem: "com.roy.agentsmonitor", category: "settings")

    /// Identifier SwiftUI gives its Settings scene window. Also its frame-autosave name, which
    /// is why `NSWindow Frame com_apple_SwiftUI_Settings_window` shows up in the app's defaults.
    private static let windowIdentifier = "com_apple_SwiftUI_Settings_window"

    /// `openSettings` is an environment action, so the caller has to hand it over.
    static func open(using openSettings: OpenSettingsAction) {
        NSApp.activate()
        openSettings()
        // The window is created during openSettings(), but ordering it front has to wait for
        // the activation to land — on the same runloop turn it is still behind other apps.
        DispatchQueue.main.async { surface(attempt: 1) }
    }

    /// Two attempts, ~100ms apart: on a cold first open the window does not exist yet by the
    /// time the first pass runs. Bounded on purpose — a retry loop here would spin forever the
    /// day SwiftUI renames the identifier.
    private static func surface(attempt: Int) {
        if let window = settingsWindow() {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            log.info("settings window surfaced on attempt \(attempt)")
            return
        }
        guard attempt < 3 else {
            log.error("settings window never appeared — no window matching \(windowIdentifier, privacy: .public) in \(NSApp.windows.count) window(s)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { surface(attempt: attempt + 1) }
    }

    private static func settingsWindow() -> NSWindow? {
        NSApp.windows.first { window in
            window.identifier?.rawValue == windowIdentifier
                || window.frameAutosaveName == windowIdentifier
        }
    }
}

/// Replaces `SettingsLink`, which cannot be fixed from the outside — it owns its own action.
struct OpenSettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings") { SettingsOpener.open(using: openSettings) }
            .accessibilityLabel("Settings")
    }
}
