// OAuth refresh-grant endpoint/params and writeback-merge logic adapted from
// Claude-Usage-Tracker's ClaudeCodeSyncService (docs/reference-ccsync.swift, vendored
// copy), MIT License:
//
//   Copyright (c) Claude-Usage-Tracker contributors
//   Permission is hereby granted, free of charge, to any person obtaining a copy of
//   this software and associated documentation files, to deal in the Software without
//   restriction, including without limitation the rights to use, copy, modify, merge,
//   publish, distribute, sublicense, and/or sell copies of the Software, subject to
//   inclusion of this notice in all copies or substantial portions of the Software.
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.

import Foundation
import os

public enum CredentialError: Error, Equatable {
    case notFound            // -> .notLoggedIn
    case denied              // consent refused; 30-min negative cache
    case badPayload
    case refreshFailed(Int)  // -> .needsCredentialsRepaste (remote only)
}

/// Local vs remote policy. Local credentials are owned by Claude Code on this Mac and are
/// **never** refreshed here — refreshing would consume the CLI's single-use refresh token
/// and force it to `/login` (ccsync:1012). Remote credentials are owned by us; we refresh
/// and write the rotated lineage back before returning.
public actor CredentialStore {
    private let session: URLSession
    private var negativeCacheUntil: [UUID: Date] = [:]

    private static let oauthRefreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let defaultOAuthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let refreshLeewaySeconds: TimeInterval = 60
    private static let log = Logger(subsystem: "com.roy.agentsmonitor", category: "credentials")
    private static let negativeCacheDuration: TimeInterval = 30 * 60

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func accessToken(for account: Account) async throws -> String {
        if account.provider == .codex {
            guard case .local(let configDirPath) = account.kind else {
                // Remote (pasted-credentials) accounts are a Claude-only path — the Codex token
                // lives in a file we read directly, so there is nothing to paste.
                throw CredentialError.notFound
            }
            return try CodexAuthFile.accessToken(configDir: configDirPath)
        }
        switch account.kind {
        case .local(let configDirPath):
            if let until = negativeCacheUntil[account.id], until > Date() {
                throw CredentialError.denied
            }
            let service = KeychainService.serviceName(forConfigDir: configDirPath)
            do {
                let data = try KeychainService.readPayload(service: service)
                guard let token = Self.accessToken(from: data) else { throw CredentialError.badPayload }
                return token
            } catch CredentialError.denied {
                Self.log.error("keychain denied for \(account.name, privacy: .public) — negative-caching 30m")
                negativeCacheUntil[account.id] = Date().addingTimeInterval(Self.negativeCacheDuration)
                throw CredentialError.denied
            }

        case .remote:
            let service = KeychainService.ownedServiceName(accountId: account.id)
            let data: Data
            do {
                data = try KeychainService.readPayload(service: service)
            } catch CredentialError.notFound {
                // Pre-rename item name. Migrate it across rather than making the user re-paste.
                let legacy = try KeychainService.readPayload(
                    service: KeychainService.legacyOwnedServiceName(accountId: account.id))
                try KeychainService.writeOwnedPayload(legacy, service: service)
                Self.log.info("migrated remote credentials for \(account.name, privacy: .public) to the new keychain item")
                data = legacy
            }

            guard let rawExpiresAt = Self.rawExpiresAt(from: data) else {
                // No expiry info in the payload = assume valid (mirrors ccsync).
                guard let token = Self.accessToken(from: data) else { throw CredentialError.badPayload }
                return token
            }
            let expirySeconds = Self.expiresAtSeconds(rawExpiresAt: rawExpiresAt)
            if Date().timeIntervalSince1970 < expirySeconds - Self.refreshLeewaySeconds {
                guard let token = Self.accessToken(from: data) else { throw CredentialError.badPayload }
                return token
            }

            guard let refreshToken = Self.refreshToken(from: data) else {
                Self.log.error("remote \(account.name, privacy: .public): payload has no refreshToken")
                throw CredentialError.refreshFailed(-1)
            }
            Self.log.info("remote \(account.name, privacy: .public): token expired, running refresh grant")
            let refreshed = try await performRefresh(refreshToken: refreshToken)
            guard let merged = Self.mergeCredentials(cliJSON: data, refreshed: refreshed) else {
                throw CredentialError.badPayload
            }
            try KeychainService.writeOwnedPayload(merged, service: service)
            guard let token = Self.accessToken(from: merged) else { throw CredentialError.badPayload }
            return token
        }
    }

    /// Validates the pasted blob parses and carries an access token, then stores it in our
    /// own keychain item. Never touches `UserDefaults`, never logs the payload.
    public func storeRemoteCredentials(_ json: Data, accountId: UUID) throws {
        guard Self.accessToken(from: json) != nil else { throw CredentialError.badPayload }
        try KeychainService.writeOwnedPayload(json, service: KeychainService.ownedServiceName(accountId: accountId))
    }

    public func clearNegativeCache(accountId: UUID) {
        negativeCacheUntil[accountId] = nil
    }

    // MARK: - Network (never exercised in tests — see the two pure helpers below instead)

    struct RefreshResponse: Decodable, Equatable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
        let token_type: String?
    }

    private func performRefresh(refreshToken: String) async throws -> RefreshResponse {
        let clientId = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_CLIENT_ID"] ?? Self.defaultOAuthClientID
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientId),
        ]
        var request = URLRequest(url: Self.oauthRefreshURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CredentialError.refreshFailed((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(RefreshResponse.self, from: data)
    }

    // MARK: - Pure helpers (unit-tested without network or keychain)

    /// `v > 1e12 ? v/1000 : v` — accepts an `expiresAt` in either milliseconds or seconds
    /// and returns seconds-since-epoch.
    static func expiresAtSeconds(rawExpiresAt: Double) -> Double {
        rawExpiresAt > 1e12 ? rawExpiresAt / 1000 : rawExpiresAt
    }

    /// Merges a refresh response into the existing `claudeAiOauth` payload, preserving every
    /// field the response doesn't touch. `expiresAt` is written in **milliseconds** (how
    /// Claude Code persists it). Sorted keys, never pretty-printed — embedded newlines have
    /// corrupted the stored payload under `security add-generic-password -w` on some builds.
    static func mergeCredentials(cliJSON: Data, refreshed: RefreshResponse, now: Date = Date()) -> Data? {
        guard let parsed = try? JSONSerialization.jsonObject(with: cliJSON) as? [String: Any],
              var oauth = parsed["claudeAiOauth"] as? [String: Any] else { return nil }
        var root = parsed

        oauth["accessToken"] = refreshed.access_token
        if let newRefreshToken = refreshed.refresh_token {
            oauth["refreshToken"] = newRefreshToken
        }
        oauth["expiresAt"] = Int64(now.timeIntervalSince1970 * 1000) + Int64(refreshed.expires_in) * 1000
        root["claudeAiOauth"] = oauth

        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func accessToken(from cliJSON: Data) -> String? {
        oauthField(cliJSON, "accessToken") as? String
    }

    private static func refreshToken(from cliJSON: Data) -> String? {
        oauthField(cliJSON, "refreshToken") as? String
    }

    private static func rawExpiresAt(from cliJSON: Data) -> Double? {
        (oauthField(cliJSON, "expiresAt") as? NSNumber)?.doubleValue
    }

    private static func oauthField(_ cliJSON: Data, _ key: String) -> Any? {
        guard let root = try? JSONSerialization.jsonObject(with: cliJSON) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth[key]
    }
}
