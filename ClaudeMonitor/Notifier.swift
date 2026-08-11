import Foundation
import os
import UserNotifications
import ClaudeMonitorKit

/// Fan-out for a batch of alerts belonging to one account: desktop notification, ntfy push,
/// in-app toast — each gated by the account/settings toggle that owns it. `@MainActor` because
/// it reads `AppStore.shared.settings` (a MainActor-isolated property); this is invoked from
/// `AppStore.onAlerts`, which fires from inside `AppStore.refresh()` — already on MainActor.
@MainActor
enum Notifier {
    static func deliver(_ alerts: [Alert], account: Account) {
        guard !alerts.isEmpty else { return }
        let settings = AppStore.shared.settings

        for alert in alerts {
            if account.desktopAlerts {
                postDesktopNotification(alert)
            }
            if account.ntfyEnabled {
                let topic = (account.ntfyTopicOverride?.isEmpty == false)
                    ? account.ntfyTopicOverride!
                    : settings.ntfyDefaultTopic
                if !topic.isEmpty {
                    postNtfy(alert, server: settings.ntfyServer, topic: topic)
                }
            }
            if settings.toastEnabled {
                ToastPanel.show(alert)
            }
        }
    }

    private static func postDesktopNotification(_ alert: Alert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("ClaudeMonitor: notification post error: \(error)") }
        }
    }

    /// No account/settings state needed beyond the passed-in values — detached from MainActor
    /// so the network round-trip doesn't hold up the main actor's queue.
    nonisolated private static let ntfyLog = Logger(subsystem: "com.roy.claudemonitor", category: "notify")

    nonisolated private static func postNtfy(_ alert: Alert, server: String, topic: String) {
        guard let url = URL(string: server) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        let payload: [String: Any] = [
            "topic": topic,
            "title": alert.title,
            "message": alert.body,
            "priority": alert.level == .critical ? 4 : 3,
            "tags": [alert.level == .critical ? "rotating_light" : "warning"],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                if status == 200 {
                    ntfyLog.info("ntfy delivered: \(alert.title, privacy: .public)")
                } else {
                    ntfyLog.error("ntfy HTTP \(status) for \(alert.title, privacy: .public)")
                }
            } catch {
                ntfyLog.error("ntfy post error: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
