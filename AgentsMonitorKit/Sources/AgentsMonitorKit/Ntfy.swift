import Foundation
import Security

/// Pure helpers for ntfy publishing (auth scoping, message trace footer, fallback decision) plus
/// the two Keychain items that hold secrets. The network call itself lives in the app's `Notifier`.
public enum Ntfy {
    public static let bundleId = "com.roy.agentsmonitor"
    /// Origin used for the fallback log line and the footer's `log:` key.
    public static let logHint = "Console: subsystem \(bundleId)"

    // MARK: Keychain (service-only items, no account; a public topic URL is a secret too)

    public enum Secret: String {
        case token = "com.roy.agentsmonitor.ntfy-token"
        case fallbackURL = "com.roy.agentsmonitor.ntfy-fallback-url"
    }

    /// BLOCKING Keychain read — call off-main. Nil when unset or unreadable.
    public static func secret(_ s: Secret) -> String? {
        guard let data = try? KeychainService.readPayload(service: s.rawValue),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    /// Empty value deletes the item.
    public static func setSecret(_ s: Secret, _ value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: s.rawValue] as CFDictionary)
        } else {
            try? KeychainService.writeOwnedPayload(Data(v.utf8), service: s.rawValue)
        }
    }

    // MARK: Auth scoping

    /// scheme + host + port (default ports normalised); nil when the URL has no host.
    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : 0)
        return "\(scheme)://\(host):\(port)"
    }

    public static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        guard let x = origin(a), let y = origin(b) else { return false }
        return x == y
    }

    /// `Authorization` header value, only when `target` is on the configured server's origin.
    public static func authorization(token: String?, target: URL, server: URL) -> String? {
        guard let token, !token.isEmpty, sameOrigin(target, server) else { return nil }
        return "Bearer \(token)"
    }

    // MARK: Message content

    /// `agents-monitor` always first; `extra` tags follow.
    public static func tags(_ extra: [String]) -> [String] { ["agents-monitor"] + extra }

    /// `YYYYMMDD-HHMMSS-<4 hex>` in local time.
    public static func eventId(date: Date = Date(), random: UInt16 = .random(in: 0...UInt16.max)) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date) + "-" + String(format: "%04x", random)
    }

    public static func shortHost(_ hostName: String = ProcessInfo.processInfo.hostName) -> String {
        hostName.split(separator: ".").first.map(String.init) ?? hostName
    }

    /// Alert key (`LimitInfo.id`, `spendBurst`, `test`) → footer `flow` value.
    public static func flow(forAlertKey key: String) -> String {
        switch key.split(separator: "|", omittingEmptySubsequences: false).first.map(String.init) ?? key {
        case "session": return "session-limit"
        case "weekly_all": return "weekly-limit"
        case "weekly_scoped": return "weekly-model-limit"
        case "spendBurst", "spend": return "extra-usage"
        case "test": return "test"
        default: return key.lowercased().replacingOccurrences(of: " ", with: "-")
        }
    }

    public static func body(_ text: String, flow: String, event: String, host: String = shortHost()) -> String {
        "\(text)\n\nsender: agents-monitor@\(host)\nflow: \(flow)\nevent: \(event)\nlog: \(logHint)"
    }

    // MARK: Fallback

    /// Fallback only after a failure (no response or non-2xx) and only if one is configured.
    public static func shouldFallback(status: Int?, hasFallback: Bool) -> Bool {
        guard hasFallback else { return false }
        guard let status else { return true }
        return !(200..<300).contains(status)
    }

    /// Splits a full topic URL (`https://host[:port]/topic`) into the server root and topic, so the
    /// same JSON payload can be posted to it.
    public static func splitTopicURL(_ s: String) -> (server: URL, topic: String)? {
        guard let url = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme, scheme == "https" || scheme == "http",
              let host = url.host else { return nil }
        let topic = url.path.split(separator: "/").first.map(String.init) ?? ""
        guard !topic.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = scheme; c.host = host; c.port = url.port
        guard let server = c.url else { return nil }
        return (server, topic)
    }
}
