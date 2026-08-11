import SwiftUI
import UserNotifications
import ClaudeMonitorKit

@main
struct ClaudeMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        // Qualified: ClaudeMonitorKit also exports a `Settings` type (persisted app settings).
        SwiftUI.Settings {
            SettingsView()
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

        // Notification authorization must be requested no earlier than this callback.
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                NSLog("ClaudeMonitor: notification authorization error: \(error)")
            }
        }

        store.startPolling()
    }

    /// Without this, banners are suppressed while the app is frontmost (e.g. Settings open).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
