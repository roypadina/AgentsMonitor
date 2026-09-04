import Foundation
import os

// MARK: - Credentials

/// Codex keeps its OAuth lineage in `<CODEX_HOME>/auth.json` (mode 600), not in the keychain —
/// so unlike Claude there is no consent prompt and no `/usr/bin/security` fallback to arrange.
///
/// The token is **never refreshed here**, for the same reason the Claude local path doesn't:
/// OpenAI rotates the refresh token on use, so spending it would invalidate the copy on disk and
/// force `codex login`. The file is re-read on every poll instead — the CLI writes a fresh token
/// back whenever it runs — and a 401 surfaces as `.needsReauth`.
enum CodexAuthFile {
    static let fileName = "auth.json"

    static func path(configDir: String) -> String {
        "\(configDir)/\(fileName)"
    }

    /// BLOCKING file read — call off-main, as `CredentialStore` does.
    static func accessToken(configDir: String) throws -> String {
        let root = try json(configDir: configDir)
        guard let tokens = root["tokens"] as? [String: Any] else {
            // `auth_mode: apikey` logins have no ChatGPT tokens and no usage to report.
            throw CredentialError.notFound
        }
        guard let token = tokens["access_token"] as? String, !token.isEmpty else {
            throw CredentialError.badPayload
        }
        return token
    }

    /// `tokens.account_id` — the `chatgpt-account-id` header the usage endpoint expects.
    static func accountId(configDir: String) -> String? {
        guard let root = try? json(configDir: configDir),
              let tokens = root["tokens"] as? [String: Any] else { return nil }
        return tokens["account_id"] as? String
    }

    /// Signed-in address, read from the `id_token` claims — used to label the account. Claims
    /// only, no signature check: this is a display string, never an authorization decision.
    static func email(configDir: String) -> String? {
        guard let root = try? json(configDir: configDir),
              let tokens = root["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String else { return nil }
        return jwtClaims(idToken)?["email"] as? String
    }

    static func exists(configDir: String) -> Bool {
        FileManager.default.fileExists(atPath: path(configDir: configDir))
    }

    private static func json(configDir: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: path(configDir: configDir))
        guard let data = try? Data(contentsOf: url) else { throw CredentialError.notFound }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialError.badPayload
        }
        return root
    }

    static func jwtClaims(_ jwt: String) -> [String: Any]? {
        let segments = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return claims
    }
}

// MARK: - Usage client

/// GET `https://chatgpt.com/backend-api/codex/usage` — the same numbers `codex` shows in its
/// status line, without spending a model call to see them. `chatgpt-account-id` and `originator`
/// mirror what the CLI sends.
public struct CodexUsageClient: Sendable {
    public static let userAgent = "codex_cli_rs/0.153.2"
    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/codex/usage")!
    private static let log = Logger(subsystem: "com.roy.agentsmonitor", category: "http")

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(accessToken: String, accountId: String?) async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let accountId {
            request.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        }
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageError.transport("no HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            Self.log.error("codex usage endpoint \(http.statusCode) unauthorized")
            throw UsageError.unauthorized
        case 429:
            Self.log.error("codex usage endpoint 429 rate-limited")
            throw UsageError.rateLimited
        default:
            Self.log.error("codex usage endpoint HTTP \(http.statusCode)")
            throw UsageError.http(http.statusCode)
        }

        do {
            return try UsageSnapshot.decodeCodex(data)
        } catch {
            throw UsageError.decode(String(describing: error))
        }
    }
}

// MARK: - Decoding

public extension UsageSnapshot {
    /// Maps the Codex payload onto the same windows the rest of the app already understands:
    /// `primary_window` is the rolling 5-hour limit, so it decodes as `session`, and
    /// `secondary_window` is the weekly one, so it decodes as `weekly_all`. That keeps the menu
    /// bar metrics, the blocked dot, pacing and the alert engine working untouched.
    ///
    /// Not mapped: `credits` and `spend_control` describe a *remaining* balance and a cap, not an
    /// amount spent, so there is nothing honest to put in `SpendInfo` (both are null on Team
    /// plans anyway). `additional_rate_limits` is left alone until a payload shows its shape.
    static func decodeCodex(_ data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageDecodeError.invalidPayload
        }
        let rateLimit = root["rate_limit"] as? [String: Any]
        let windows: [(String, Any?)] = [
            ("session", rateLimit?["primary_window"]),
            ("weekly_all", rateLimit?["secondary_window"]),
            ("code_review", root["code_review_rate_limit"]),
        ]
        let limits = windows.compactMap { kind, raw in
            codexWindow(raw as? [String: Any], kind: kind, now: fetchedAt)
        }
        return UsageSnapshot(limits: limits, spend: nil, fetchedAt: fetchedAt)
    }

    private static func codexWindow(_ dict: [String: Any]?, kind: String, now: Date) -> LimitInfo? {
        guard let dict, let usedPercent = (dict["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let percent = Int(usedPercent.rounded())
        let windowSeconds = (dict["limit_window_seconds"] as? NSNumber)?.doubleValue

        // `reset_at` is epoch seconds; `reset_after_seconds` is the same instant expressed as a
        // countdown. Prefer the absolute one — the relative one drifts with response latency.
        var resetsAt: Date?
        if let epoch = (dict["reset_at"] as? NSNumber)?.doubleValue {
            resetsAt = Date(timeIntervalSince1970: epoch)
        } else if let after = (dict["reset_after_seconds"] as? NSNumber)?.doubleValue {
            resetsAt = now.addingTimeInterval(after)
        }
        if let date = resetsAt, now >= date { resetsAt = nil }   // same rule as the Claude path

        return LimitInfo(kind: kind, group: nil, percent: percent,
                         severity: codexSeverity(percent: percent),
                         resetsAt: resetsAt, modelDisplayName: nil, isActive: true,
                         windowSeconds: windowSeconds)
    }

    /// Anthropic's usage endpoint grades each window for us; OpenAI's does not, so grade it here.
    /// The cutoffs match what Anthropic returns (observed: 81% warning, 95% critical) so the two
    /// providers' rows mean the same thing side by side. Alerting uses the user's own thresholds
    /// and is unaffected by this.
    private static func codexSeverity(percent: Int) -> Severity {
        switch percent {
        case 95...: return .critical
        case 75...: return .warning
        default: return .normal
        }
    }
}
