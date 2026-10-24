import Foundation
import os
import UserNotifications
import AgentsMonitorKit

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
            if let error { NSLog("AgentsMonitor: notification post error: \(error)") }
        }
    }

    /// No account/settings state needed beyond the passed-in values — detached from MainActor
    /// so the network round-trip doesn't hold up the main actor's queue.
    nonisolated private static let ntfyLog = Logger(subsystem: "com.roy.agentsmonitor", category: "notify")

    nonisolated private static func postNtfy(_ alert: Alert, server: String, topic: String) {
        guard let serverURL = URL(string: server) else { return }
        let flow = Ntfy.flow(forAlertKey: alert.key)
        let event = Ntfy.eventId()
        let payload: [String: Any] = [
            "title": alert.title,
            "message": Ntfy.body(alert.body, flow: flow, event: event),
            "priority": alert.level == .critical ? 4 : 3,
            "tags": Ntfy.tags([alert.level == .critical ? "rotating_light" : "warning"]),
        ]

        Task {
            // Keychain reads block: off the main actor (this Task inherits none).
            let token = Ntfy.secret(.token)
            let fallback = Ntfy.secret(.fallbackURL).flatMap(Ntfy.splitTopicURL)
            let status = await send(payload, to: serverURL, topic: topic, token: token, server: serverURL, event: event)
            if let fallback, Ntfy.shouldFallback(status: status, hasFallback: true) {
                _ = await send(payload, to: fallback.server, topic: fallback.topic, token: token, server: serverURL, event: event)
            }
        }
    }

    /// One POST; logs one line (never the token). Returns the HTTP status, nil on transport error.
    nonisolated private static func send(_ payload: [String: Any], to url: URL, topic: String,
                                         token: String?, server: URL, event: String) async -> Int? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth = Ntfy.authorization(token: token, target: url, server: server) {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 10
        var body = payload
        body["topic"] = topic
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // A public ntfy.sh topic name is a secret: keep it out of the log.
        let shownTopic = url.host == "ntfy.sh" ? "(hidden)" : topic
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String ?? "-"
            ntfyLog.info("ntfy event=\(event, privacy: .public) topic=\(shownTopic, privacy: .public) http=\(status, privacy: .public) id=\(id, privacy: .public)")
            return status
        } catch {
            ntfyLog.error("ntfy event=\(event, privacy: .public) topic=\(shownTopic, privacy: .public) http=error id=- \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
