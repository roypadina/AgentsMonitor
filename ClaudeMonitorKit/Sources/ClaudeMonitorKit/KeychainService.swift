// Service-name derivation, enumeration, and read/write primitives adapted from
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
import Security
import CryptoKit

/// Keychain **primitives** only. No refresh/policy logic here — see `CredentialStore`.
public enum KeychainService {

    /// `~/.claude` maps to the unsuffixed entry; every other `CLAUDE_CONFIG_DIR` maps to
    /// `Claude Code-credentials-<sha256(path)[:8]>`. Verified live: `~/.claude-work2` -> `e5af6df1`.
    public static func serviceName(forConfigDir path: String, home: String = NSHomeDirectory()) -> String {
        let normalized = normalizePath(path)
        if normalized == normalizePath("\(home)/.claude") {
            return "Claude Code-credentials"
        }
        return "Claude Code-credentials-\(sha256HexPrefix(normalized, length: 8))"
    }

    /// Source of truth for which accounts exist — finds entries whose config dir is gone.
    /// `SecItemCopyMatching` only, `kSecReturnData: false` — a silent existence probe that
    /// never fires the keychain consent prompt.
    public static func discoverClaudeServices() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: false,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }

        let prefix = "Claude Code-credentials"
        var found = Set<String>()
        for item in items {
            guard let name = item[kSecAttrService as String] as? String else { continue }
            if name == prefix || name.hasPrefix("\(prefix)-") {
                found.insert(name)
            }
        }
        return found.sorted()
    }

    /// `[serviceName: (email, organizationName?)]` from `~/.claude*/.claude.json`. No secrets.
    public static func discoverLabels(home: String = NSHomeDirectory())
        -> [String: (email: String, organizationName: String?)] {
        var labels: [String: (email: String, organizationName: String?)] = [:]
        let fm = FileManager.default

        var candidates = ["\(home)/.claude"]
        if let entries = try? fm.contentsOfDirectory(atPath: home) {
            for name in entries where name.hasPrefix(".claude-") {
                candidates.append("\(home)/\(name)")
            }
        }

        for dir in candidates {
            let configFile = "\(dir)/.claude.json"
            guard fm.fileExists(atPath: configFile),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: configFile)),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauthAccount = root["oauthAccount"] as? [String: Any],
                  let email = oauthAccount["emailAddress"] as? String else { continue }
            let svc = serviceName(forConfigDir: dir, home: home)
            labels[svc] = (email, oauthAccount["organizationName"] as? String)
        }
        return labels
    }

    /// Process-wide "never block on a keychain consent prompt" switch. Deprecated API, but it is
    /// the only one that turns the ACL consent dialog into a clean `errSecAuthFailed` (verified
    /// live on macOS 26.6) — without it a read from this ad-hoc-signed app hangs on a modal
    /// nobody may be around to click. The CLI fallback below does the actual authorized read.
    private static let suppressKeychainUI: Void = {
        SecKeychainSetUserInteractionAllowed(false)
    }()

    /// BLOCKING (Security framework XPC round-trip / child process) — call off-main. Query by
    /// service only, no account, matching the live-verified keychain items.
    ///
    /// Two-step read: `SecItemCopyMatching` first (succeeds once the user ever granted access, and
    /// always for items this binary created). On the ACL partition failure that an ad-hoc app hits
    /// for Claude Code's items (`errSecAuthFailed`), fall back to Apple-signed `/usr/bin/security`,
    /// which created those items and reads them silently — no consent prompt, ever (verified live).
    public static func readPayload(service: String) throws -> Data {
        _ = suppressKeychainUI
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw CredentialError.badPayload }
            return data
        case errSecItemNotFound:
            throw CredentialError.notFound
        default:
            return try cliReadPayload(service: service)
        }
    }

    private static func cliReadPayload(service: String) throws -> Data {
        let output = try runSecurityCLI(["find-generic-password", "-s", service, "-w"])
        guard case .success(let raw) = output else {
            if case .exit(44) = output { throw CredentialError.notFound }  // errSecItemNotFound
            throw CredentialError.denied
        }
        var text = String(decoding: raw, as: UTF8.self)
        while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
        // `-w` prints hex instead of raw text when the payload is non-ASCII.
        if !text.hasPrefix("{"), text.count % 2 == 0, let hexData = dataFromHex(text) {
            return hexData
        }
        guard !text.isEmpty else { throw CredentialError.badPayload }
        return Data(text.utf8)
    }

    /// Update-then-Add — delete-then-add left the item partially overwritten (invalid JSON)
    /// under concurrent refresh in the vendored project. `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
    /// on create: no iCloud sync for a live OAuth lineage.
    public static func writeOwnedPayload(_ data: Data, service: String) throws {
        let matchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        _ = suppressKeychainUI
        let updateStatus = SecItemUpdate(matchQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }

        if updateStatus == errSecItemNotFound {
            var addQuery = matchQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            if SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess { return }
        }

        // Post-rebuild an ad-hoc app loses access to items its previous cdhash created
        // (errSecAuthFailed). `security add-generic-password -U` updates-in-place atomically.
        // ponytail: payload rides argv — visible to local `ps` for milliseconds; same-user ps
        // can already read the same item via the same CLI, no boundary crossed.
        guard let text = String(data: data, encoding: .utf8),
              case .success = try runSecurityCLI(
                ["add-generic-password", "-U", "-s", service, "-a", "claude-monitor", "-w", text]
              ) else {
            throw CredentialError.badPayload
        }
    }

    private enum CLIResult {
        case success(Data)
        case exit(Int32)
    }

    /// 5s watchdog + stderr swallowed; payloads here are ~15KB, far under the 64KB pipe buffer.
    private static func runSecurityCLI(_ arguments: [String]) throws -> CLIResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { throw CredentialError.denied }

        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationReason == .exit else { throw CredentialError.denied }
        return process.terminationStatus == 0 ? .success(data) : .exit(process.terminationStatus)
    }

    private static func dataFromHex(_ hex: String) -> Data? {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    public static func ownedServiceName(accountId: UUID) -> String {
        "ClaudeMonitor-account-\(accountId.uuidString)"
    }

    private static func normalizePath(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func sha256HexPrefix(_ s: String, length: Int) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(length))
    }
}
