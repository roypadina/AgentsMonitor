import SwiftUI
import UserNotifications
import AgentsMonitorKit

@main
struct AgentsMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
        .commands {  // App menu while a window is open (policy .regular)
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsWindow.shared.show() }.keyboardShortcut(",")
            }
        }
    }
}

/// The menu bar label. SwiftUI renders it as a template image — `.foregroundStyle` on the
/// text/icon is silently dropped, so this stays plain text + a neutral SF Symbol. Severity
/// color lives in the popover and toast instead.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = AppStore.shared
        store.onAlerts = Notifier.deliver
        store.bootstrap()
        LoginItem.ensureRegistered()

        // First launch only (MBX-18). Existing users see it once after the update.
        if !UserDefaults.standard.bool(forKey: "didShowWelcome") {
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            WelcomeWindow.show()
        }

        // Notification authorization must be requested no earlier than this callback.
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                NSLog("AgentsMonitor: notification authorization error: \(error)")
            }
        }

        store.startPolling()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening Agents Monitor again (Finder, Raycast) shows Settings: the way in when the icon is hidden (MBX-8).
    @MainActor func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { SettingsWindow.shared.show() }
        return true
    }

    /// Without this, banners are suppressed while the app is frontmost (e.g. Settings open).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
