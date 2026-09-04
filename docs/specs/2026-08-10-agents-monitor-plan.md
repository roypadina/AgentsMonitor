# Agents Monitor — Implementation Plan (final, rev 2)

> Authored by opus planning agent, 2026-08-10. Design doc + addendum folded in. Facts verified against this machine or the vendorable OSS source (`docs/reference-ccsync.swift`, MIT).

## Facts pinned before planning

Verified live (macOS 26.6.1, Xcode 26.5, Swift 6.3.2):

| Fact | Result |
|---|---|
| `sha256("/Users/roypadina/.claude-work2")[0..8]` | `e5af6df1` — matches keychain item `Claude Code-credentials-e5af6df1` |
| `sha256("/Users/roypadina/.claude")[0..8]` | `f3e2a4de` — **no such item**; `~/.claude` uses the unsuffixed name |
| Keychain `acct` on both items | `roypadina` — query by **service only**, no account |
| `ISO8601DateFormatter` + `.withFractionalSeconds` on `"…345684+00:00"` | parses; **without** the flag → `nil` |
| `JSONDecoder` `.iso8601` on same string | works on macOS 26 swift-foundation only — do not rely on it |
| `swift package describe` on tools-version 5.9 | exit 0 under Swift 6.3 — LanGuard's recipe still valid |

Extracted from `docs/reference-ccsync.swift` (MIT, retain notice) — **adapt these, do not re-derive**:

| Thing | Value | line |
|---|---|---|
| Refresh endpoint | `POST https://platform.claude.com/v1/oauth/token` | 896 |
| Public client id | `9d1c250a-e61b-44d9-88ed-5944d1962f5e` (env override `CLAUDE_CODE_OAUTH_CLIENT_ID`) | 900 |
| Body | `application/x-www-form-urlencoded`: `grant_type=refresh_token&refresh_token=…&client_id=…` | 964-976 |
| Response | `{access_token, refresh_token?, expires_in, token_type?}` | 952-957 |
| Refresh leeway | 60s before expiry | 905 |
| `expiresAt` leniency | `v > 1e12 ? v/1000 : v` — accepts ms or s | 879 |
| Writeback merge | preserve all other `claudeAiOauth` keys, set `expiresAt` in **ms**, serialize `.sortedKeys`, **never `.prettyPrinted`** | 1152-1180 |
| Discovery | `kSecMatchLimitAll` + `kSecReturnAttributes`, filter `kSecAttrService` on prefix `Claude Code-credentials` | 515-540 |
| Labels | `~/.claude*/.claude.json` → `oauthAccount.emailAddress` / `organizationName`, keyed by derived service name | 461-495 |

Two warnings written into that source as comments — they are why the local/remote split exists, not a preference:
- Refreshing a lineage the CLI owns **consumes its single-use refresh token**; the CLI's next refresh fails `invalid_grant` and forces `/login` (ccsync:1012-1019).
- Delete-then-add keychain writeback left the item **partially overwritten as invalid JSON** under concurrent refresh (ccsync:935-938). Use `SecItemUpdate`, fall back to `SecItemAdd` only on `errSecItemNotFound`.

## Scaffolding decision

**Copy + `sed`-rename of LanGuard's 8 project files.** LanGuard's `project.pbxproj` already contains the exact local-package wiring plus an `.xctestplan` that runs the SPM test target under `xcodebuild`; copying costs one `sed` and has zero unknowns. Pure-SPM .app assembly rejected on correctness: `SMAppService.mainApp` and `UNUserNotificationCenter.current()` both require a real signed bundle registered with LaunchServices.

`objectVersion = 77` → `PBXFileSystemSynchronizedRootGroup`: source files are **never** listed in the pbxproj. Dropping a `.swift` file into `AgentsMonitor/` is sufficient; no project edit when adding files.

## File layout

Root `/Users/roypadina/Code/Padina/AgentsMonitor`.

### Copied from LanGuard (8 files, sed-renamed — no authoring)

| Path | Responsibility |
|---|---|
| `Config/Shared.xcconfig` | bundle id `com.roy.agentsmonitor`, `LSUIElement=YES`, `MACOSX_DEPLOYMENT_TARGET=14.0`, ad-hoc `CODE_SIGN_IDENTITY = -` |
| `Config/{Debug,Release,Tests}.xcconfig` | thin `#include` wrappers |
| `Config/AgentsMonitor.entitlements` | `app-sandbox = false` (other-app keychain + SMAppService) |
| `AgentsMonitor.xcodeproj/project.pbxproj` | app target + UITests stub + package product dependency |
| `…/project.xcworkspace/contents.xcworkspacedata`, `…/xcshareddata/xcschemes/AgentsMonitor.xcscheme` | shared scheme so `-scheme AgentsMonitor` works from CLI |
| `AgentsMonitor.xcworkspace/contents.xcworkspacedata` | ties `group:AgentsMonitorKit` + `container:AgentsMonitor.xcodeproj` — **this resolves the local package**; all builds must use `-workspace` |
| `AgentsMonitor/AgentsMonitor.xctestplan` | runs `AgentsMonitorKitTests` under `xcodebuild test` |
| `AgentsMonitorUITests/AgentsMonitorUITests.swift` | generated stub — **leave it**; removing the target is pbxproj surgery for no gain |

Rename order matters (longer tokens first — they contain the shorter ones):
```
LanGuardFeatureTests -> AgentsMonitorKitTests
LanGuardPackage      -> AgentsMonitorKit
LanGuardFeature      -> AgentsMonitorKit
LanGuard             -> AgentsMonitor
languard             -> agentsmonitor
```
Apply to file contents *and* file/dir names. Then hand-edit `Shared.xcconfig`: `PRODUCT_DISPLAY_NAME = Agents Monitor`, `MARKETING_VERSION = 1.0.0`, `CURRENT_PROJECT_VERSION = 1`; rewrite the entitlements comment to say why *this* app is unsandboxed.

### `AgentsMonitorKit/` — local SPM package, all logic

| File | Responsibility | LOC |
|---|---|---|
| `Package.swift` | tools-version 5.9, `.macOS(.v14)`, library + test target with `resources: [.copy("Fixtures")]` | 25 |
| `Sources/…/Models.swift` | value types, tolerant decoder, money formatting, pacing math, `AccountKind` | ~185 |
| `Sources/…/KeychainService.swift` | keychain **primitives**: sha256 derivation, `SecItemCopyMatching` read, `kSecMatchLimitAll` enumeration, owned-item read/write, `.claude.json` labels | ~130 |
| `Sources/…/CredentialStore.swift` | **policy**: local read (never refresh) vs remote read + refresh + writeback; 30-min negative cache | ~150 |
| `Sources/…/UsageClient.swift` | GET with mandatory UA, 429/401/403 mapping, 10s timeout | ~70 |
| `Sources/…/AlertEngine.swift` | level eval, de-dupe, re-arm | ~95 |
| `Sources/…/AppStore.swift` | `@MainActor @Observable` store, `Settings`, UserDefaults persistence, poll task, per-account backoff | ~160 |
| `Tests/AgentsMonitorKitTests/AgentsMonitorKitTests.swift` | **one** file, five `XCTestCase` classes | ~230 |
| `Tests/…/Fixtures/*.json` | already committed | — |

Primitives/policy split is deliberate: derivation and enumeration are pure and testable, while the refresh decision is the part that can destroy someone's CLI login if it leaks into the local path. One file invites exactly that mistake.

### `AgentsMonitor/` — app target, thin UI

| File | Responsibility | LOC |
|---|---|---|
| `App.swift` | `@main`, `MenuBarExtra(.window)`, `Settings` scene, `AppDelegate` bootstrap | ~60 |
| `PopoverView.swift` | account cards, limit rows with progress bar + pacing tick, countdown, spend row, error states, footer | ~145 |
| `SettingsView.swift` | `TabView`: Accounts (incl. remote paste flow) / Alerts / General | ~185 |
| `Notifier.swift` | `UNUserNotificationCenter` + ntfy POST + fan-out | ~90 |
| `ToastPanel.swift` | floating `NSPanel`, slide + fade, `NSSound` | ~90 |

**Total new Swift ≈ 1615 LOC. No third-party dependencies.**

## Key API surface (both agents code against this)

```swift
// ---------- Models.swift ----------
public enum Severity: String, Codable, Comparable, Sendable { case normal, warning, critical }

public enum AccountKind: Codable, Hashable, Sendable {
    case local(configDirPath: String)   // credentials owned by Claude Code on this Mac
    case remote                         // pasted by the user, we own them
}

public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String              // from .claude.json oauthAccount, editable
    public var kind: AccountKind
    public var desktopAlerts: Bool       // default true
    public var ntfyEnabled: Bool         // default false
    public var ntfyTopicOverride: String?
    // NEVER holds a token. UserDefaults is a plaintext plist.
}

public struct LimitInfo: Codable, Hashable, Sendable, Identifiable {
    public let kind: String              // "session" | "weekly_all" | "weekly_scoped" | "spend"
    public let group: String?
    public let percent: Int              // clamped 0...100
    public let severity: Severity
    public let resetsAt: Date?           // nullable; also nulled when now >= resetsAt
    public let modelDisplayName: String? // scope.model.display_name, e.g. "Fable"
    public let isActive: Bool
    public var id: String { kind + "|" + (modelDisplayName ?? "") }
    public var label: String             // "Session" / "Week" / "Week · Fable"
    public var windowLength: TimeInterval // 5h for session, 7d for weekly group
}

public struct SpendInfo: Codable, Hashable, Sendable {
    public let usedMinor: Int
    public let limitMinor: Int?          // NULL in usage_team_no_spend.json
    public let exponent: Int
    public let currency: String
    public let percent: Int
    public let severity: Severity
    public let enabled: Bool
    public var isAlertable: Bool { enabled && limitMinor != nil }
    public var usedFormatted: String     // "$728.60"
    public var limitFormatted: String?   // "$800.00" or nil
    public var asLimitInfo: LimitInfo?   // kind "spend"; nil when !isAlertable
}

public struct UsageSnapshot: Sendable, Hashable {
    public let limits: [LimitInfo]
    public let spend: SpendInfo?
    public let fetchedAt: Date
    public var worstPercent: Int
    public var worstSeverity: Severity
    public static func decode(_ data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot
}

/// Pure, unit-tested. Where an even burn "should" be — the progress-bar tick.
public func pacingFraction(resetsAt: Date, windowLength: TimeInterval,
                           now: Date = Date()) -> Double?   // 0...1, nil if unknown

public enum AccountState: Sendable, Equatable {
    case idle
    case ok(UsageSnapshot)
    case stale(UsageSnapshot, error: String)   // last good + latest failure
    case notLoggedIn                            // no keychain entry
    case keychainDenied                         // consent refused
    case needsReauth                            // local, 401
    case needsCredentialsRepaste                // remote, refresh grant failed
    case rateLimited(until: Date)
    case failed(String)
}

// ---------- KeychainService.swift ----------
public enum KeychainService {
    public static func serviceName(forConfigDir path: String,
                                   home: String = NSHomeDirectory()) -> String
    /// Source of truth for which accounts exist — finds entries whose config dir is gone.
    public static func discoverClaudeServices() -> [String]
    /// [serviceName: (email, organizationName?)] from ~/.claude*/.claude.json. No secrets.
    public static func discoverLabels(home: String = NSHomeDirectory())
        -> [String: (email: String, organizationName: String?)]
    public static func readPayload(service: String) throws -> Data          // BLOCKING, off-main
    public static func writeOwnedPayload(_ data: Data, service: String) throws  // Update-then-Add
    public static func ownedServiceName(accountId: UUID) -> String          // "AgentsMonitor-account-<uuid>"
}

// ---------- CredentialStore.swift ----------
public actor CredentialStore {
    public init(session: URLSession = .shared)
    /// Local: read fresh, NEVER refresh (ccsync:1012 — would force the CLI to /login).
    /// Remote: read our own item; if expiresAt - 60s <= now, run the refresh grant and
    ///         write the rotated lineage back BEFORE returning.
    public func accessToken(for account: Account) async throws -> String
    public func storeRemoteCredentials(_ json: Data, accountId: UUID) throws
    public func clearNegativeCache(accountId: UUID)
}

public enum CredentialError: Error, Equatable {
    case notFound            // -> .notLoggedIn
    case denied              // consent refused; 30-min negative cache
    case badPayload
    case refreshFailed(Int)  // -> .needsCredentialsRepaste (remote only)
}

// ---------- UsageClient.swift ----------
public struct UsageClient: Sendable {
    public static let userAgent = "claude-cli/2.1.175 (external, cli)"   // MANDATORY
    public init(session: URLSession = .shared)
    public func fetch(accessToken: String) async throws -> UsageSnapshot
}
public enum UsageError: Error, Equatable {
    case unauthorized        // 401/403 — no retry storm
    case rateLimited         // 429 — feeds the backoff ladder
    case http(Int), transport(String), decode(String)
}

// ---------- AlertEngine.swift ----------
public struct AlertThresholds: Codable, Equatable, Sendable {
    public var warning: Int = 80
    public var critical: Int = 95
}
public enum AlertLevel: Int, Comparable, Codable, Sendable { case none = 0, warning = 1, critical = 2 }

public struct Alert: Equatable, Sendable {
    public let accountId: UUID
    public let accountName: String
    public let key: String        // LimitInfo.id, or "auth"
    public let title: String
    public let body: String
    public let level: AlertLevel
}

public struct AlertEngine {
    public var thresholds: AlertThresholds
    public init(thresholds: AlertThresholds = .init())
    /// Mutates internal de-dupe memory. Pure w.r.t. everything else.
    public mutating func evaluate(account: Account, state: AccountState,
                                  now: Date = Date()) -> [Alert]
    public mutating func reset()
}

// ---------- AppStore.swift ----------
public struct Settings: Codable, Equatable, Sendable {
    public var pollSeconds: Int = 180          // clamp 30...600
    public var thresholds = AlertThresholds()
    public var ntfyServer: String = "https://ntfy.sh"
    public var ntfyDefaultTopic: String = ""   // user-local only, never committed
    public var showPercentInMenuBar: Bool = true
    public var toastEnabled: Bool = true
    public var soundEnabled: Bool = true
}

@MainActor @Observable
public final class AppStore {
    public static let shared = AppStore()
    public var accounts: [Account]
    public var states: [UUID: AccountState]
    public var settings: Settings
    public var lastRefresh: Date?
    public var isRefreshing: Bool
    /// App assigns Notifier.deliver here — the Kit never imports AppKit/UserNotifications.
    public var onAlerts: (([Alert], Account) -> Void)?

    public func bootstrap()          // load defaults; first run -> discovery
    public func refresh() async      // concurrent per-account; keychain+network off main
    public func startPolling(); public func stopPolling(); public func save()
    public var worst: (percent: Int, severity: Severity)?
    public var menuBarText: String   // "95%" or "" when showPercentInMenuBar is off
}
```

**Alert semantics** (what the tests pin):
- `level = max(severityLevel(api.severity), thresholdLevel(percent))` — API severity can exceed the threshold verdict and must win.
- De-dupe memory `[String: (level: AlertLevel, window: Date?)]`, keyed `"\(accountId)|\(limitKey)"`.
- Fire when `newLevel > stored.level`, **or** when `window != stored.window && newLevel > .none`. Always overwrite afterwards — a drop re-arms.
- `needsReauth` and `needsCredentialsRepaste` each fire once under key `"auth"` at `.critical`; returning to `.ok` clears the entry so it can fire again later.
- Spend participates only when `isAlertable`. Fixture 2 has `enabled: true, limit: null, percent: 0` and must never alert.

**Backoff ladder:** per account, `[3, 6, 12, 15]` minutes, holding at 15. A 429 advances one rung and sets `.rateLimited(until:)`; any 2xx resets to rung 0. Strictly per-account — the bucket is per access token, so one throttled account must not stall the others.

## Commands

**Package tests (fast inner loop, no Xcode):**
```bash
swift test --package-path /Users/roypadina/Code/Padina/AgentsMonitor/AgentsMonitorKit
```
MCP: `swift_package_test({ packagePath: "/Users/roypadina/Code/Padina/AgentsMonitor/AgentsMonitorKit" })`

**Session defaults** (set once; `build_macos` / `test_macos` read these):
```
session_set_defaults({
  workspacePath: "/Users/roypadina/Code/Padina/AgentsMonitor/AgentsMonitor.xcworkspace",
  scheme: "AgentsMonitor",
  configuration: "Release",
  derivedDataPath: "/Users/roypadina/Code/Padina/AgentsMonitor/build"
})
```
Then `list_schemes` to confirm the sed-rename produced scheme `AgentsMonitor`, then `build_macos({})`, `get_mac_app_path({})`, `test_macos({})`.

**CLI fallbacks** — note `-workspace`, never `-project`, or the package won't resolve:
```bash
cd /Users/roypadina/Code/Padina/AgentsMonitor
xcodebuild -workspace AgentsMonitor.xcworkspace -scheme AgentsMonitor -configuration Debug   -derivedDataPath build build
xcodebuild -workspace AgentsMonitor.xcworkspace -scheme AgentsMonitor -configuration Release -derivedDataPath build build
xcodebuild -workspace AgentsMonitor.xcworkspace -scheme AgentsMonitor -configuration Debug   test
```

**Install + launch:**
```bash
rm -rf /Applications/AgentsMonitor.app
cp -R build/Build/Products/Release/AgentsMonitor.app /Applications/
codesign -dv /Applications/AgentsMonitor.app     # verify ad-hoc signature survived
open /Applications/AgentsMonitor.app
```

**Ground truth for B5** (note the UA — without it you get throttled):
```bash
TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w | jq -r .claudeAiOauth.accessToken)
curl -s https://api.anthropic.com/api/oauth/usage \
  -H "Authorization: Bearer $TOKEN" -H "anthropic-beta: oauth-2025-04-20" \
  -H "User-Agent: claude-cli/2.1.175 (external, cli)" | jq '{limits, spend: .spend.percent}'
```

## Ordered steps

### Group A — scaffold + Kit + green tests

**A1** Copy + `sed`-rename the 8 project files per the table and rename order above; edit `Shared.xcconfig` and the entitlements comment.

**A2** `Package.swift` — tools-version 5.9, `.macOS(.v14)`, test target with `resources: [.copy("Fixtures")]`. MIT attribution header on the two files that vendor from CCSeva / Claude-Usage-Tracker (`KeychainService.swift`, `CredentialStore.swift`). Confirm with `swift package describe` before writing sources.

**A3** `Models.swift` — tolerant decoder. Prefer `limits[]` (it alone carries `severity` and the Fable `scope`). Fallback: treat **any** top-level object with numeric `utilization` + `resets_at` as a window. Clamp percent 0–100. **Null out any window where `now >= resetsAt`.** Every field optional; a missing key degrades, never throws. Decode percents as `Double` and round (`spend.percent` is `91` but `extra_usage.utilization` is `91.07`; `Int` decoding of `91.0` throws). `.custom` date strategy: try `.withInternetDateTime, .withFractionalSeconds`, fall back to `.withInternetDateTime`, else throw. Plus `pacingFraction`.

**A4** `KeychainService.swift` — derivation, read, enumeration, labels, owned-item write via Update-then-Add. **`SecItemCopyMatching` only.** Silent existence probes use `kSecReturnAttributes: true, kSecReturnData: false` so discovery never fires a consent prompt. Map `errSecUserCanceled`/`errSecAuthFailed`/`errSecInteractionNotAllowed` → `.denied`, `errSecItemNotFound` → `.notFound`.

**A5** `CredentialStore.swift` — local/remote split, refresh grant exactly per the ccsync table, merge-and-writeback, 30-minute negative cache keyed by account after a denied prompt.

**A6** `UsageClient.swift` — mandatory `User-Agent`, `anthropic-beta: oauth-2025-04-20`, `Content-Type: application/json`, 10s timeout, 429/401/403 mapping.

**A7** `AlertEngine.swift` per the semantics above.

**A8** `AppStore.swift` — `TaskGroup` refresh, single cancellable `Task.sleep` poll loop (**not** a `Timer`), per-account backoff, alert dispatch via `onAlerts`. Persist `accounts`/`settings` as JSON `Data` in `UserDefaults`, decoded with `try?` + default fallback.

**A9 `swift test` green.** One file, five classes:
1. *Parsing*: both fixtures — 3 limits each, kinds/percents/severities, `"Fable"` on `weekly_scoped`, `resetsAt` correct, `worstPercent` 95 / 13, `$728.60` / `$800.00` on fixture 1, `limitMinor == nil` + `isAlertable == false` on fixture 2.
2. *Tolerant decoding*: `limits[]` removed → loose fallback still yields windows; `utilization: 150` clamps to 100; window with past `resetsAt` is nulled.
3. *Derivation*: four cases incl. verified `e5af6df1`, plus trailing-slash normalization (`home:` injectable).
4. *AlertEngine*: normal→no alert; rise to warning→1; repeat→0; rise to critical→1; drop→0 + re-arm; rise again→1; window roll at same level→1; `needsReauth` once then suppressed then re-fires after `.ok`; API critical at percent 10 still critical; spend with nil limit→0.
5. *Credentials*: `expiresAt` accepted as ms and s; merge preserves unknown `claudeAiOauth` keys, writes `expiresAt` in ms, emits no newline; backoff ladder walks 3/6/12/15 and resets on success.

Group A ends here. Do not write UI.

### Group B — UI, notifier, install

**B1** `App.swift` — `MenuBarExtra { PopoverView() } label: { … }.menuBarExtraStyle(.window)` + `Settings { SettingsView() }`. `AppDelegate.applicationDidFinishLaunching` calls `bootstrap()`, assigns `onAlerts = Notifier.deliver`, requests notification authorization, sets the `UNUserNotificationCenterDelegate`, starts polling.

**B2** `PopoverView.swift` — card per account: name + tier badge; row per `LimitInfo` (label, severity-tinted `ProgressView` with thin vertical **pacing tick** at `pacingFraction`, percent, "resets in 2h 14m"); spend row when present; all `AccountState` variants. Footer: last-refresh, Refresh, Settings, Quit.

**B3** `SettingsView.swift` — three tabs. Accounts: list, folder picker to add local account, rename, per-account toggles, ntfy topic override, remove, plus **Add Remote Account**: sheet with paste field, one-line hint naming the source (`security find-generic-password -s "Claude Code-credentials" -w` on macOS, `~/.claude/.credentials.json` on Linux), validation that the blob parses and contains `claudeAiOauth.accessToken`, then `storeRemoteCredentials`. An account in `needsCredentialsRepaste` offers the same sheet from its card. Alerts: threshold steppers, ntfy server + default topic, test-alert button pushing a synthetic `Alert` through `Notifier.deliver`. General: poll interval, launch-at-login via `SMAppService` (copy LanGuard's `LoginItem` self-heal pattern incl. stored-bundle-path check), show-percent toggle.

**B4** `Notifier.swift` + `ToastPanel.swift` — three sinks. Desktop via `UNUserNotificationCenter`. ntfy via **JSON body** POST to the server root (`{"topic":…,"title":…,"message":…,"priority":…,"tags":[…]}`), priority 3 warning / 4 critical. Toast via `.nonactivatingPanel` `NSPanel` at `.floating` level, slide + fade, auto-dismiss, `NSSound` when `soundEnabled`.

**B5** Release build, install to `/Applications`, launch, verify against curl ground truth — both local accounts polling and matching. Then: drop warning threshold to 1%, confirm desktop notification + ntfy delivery + toast with sound; restore; relaunch and confirm settings persisted. Remote path: configure one remote account from a pasted blob, confirm it polls, then set its `expiresAt` into the past and confirm the refresh grant fires and rotated lineage is written back.

## Pitfalls

**Never refresh a local account's token.** The one bug that damages something *outside* the app — consumes Claude Code's single-use refresh token, CLI lands on `Please run /login`. Guard belongs in `CredentialStore.accessToken`, switching on `AccountKind` before any refresh path is reachable, never in the callers.

**Remote credentials are a trust boundary, not a settings value.** The pasted blob is a live OAuth lineage: store only in the app-owned keychain item with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (no iCloud sync), never in `UserDefaults`, never in a log line, clear the paste field after save. `Account` carries `kind` and nothing secret. Upside: we create that item ourselves → remote accounts never trigger a consent prompt.

**Writeback must be Update-then-Add.** Delete-then-add corrupted the item under concurrent refresh in the vendored project. Serialize `.sortedKeys`, never `.prettyPrinted`.

**The User-Agent is load-bearing.** Without `claude-cli/2.1.175 (external, cli)` requests land in an aggressively rate-limited bucket returning persistent 429s with no `Retry-After`. If polling mysteriously dies, check the UA first.

**Date parsing.** `resets_at` is `"2026-08-10T21:20:00.345684+00:00"` — six fractional digits, `+00:00` not `Z`. `ISO8601DateFormatter` needs `.withFractionalSeconds` explicitly or returns `nil`. `resets_at` is nullable → `Date?`.

**Money.** `{amount_minor: 72860, exponent: 2}` = $728.60. `Decimal`, not `Double`; `NumberFormatter` with `currencyCode` from the payload, not the user's locale. Fixture 2: null limit with `enabled: true` — render used only, no bar, never alert.

**MenuBarExtra label color.** SwiftUI renders the label as a template image — `.foregroundStyle(.red)` is silently dropped. Plain text percent in the menu bar; severity color in popover and toast.

**Notification authorization in an LSUIElement app.** Works, but only from a properly bundled and signed app. Call `UNUserNotificationCenter.current()` no earlier than `applicationDidFinishLaunching`. Denial drops notifications with no error → surface authorization status in the Alerts tab.

**Keychain consent has two traps.** Blocking modal — keychain work must be off-main. Ad-hoc signing makes the designated requirement a cdhash that changes every rebuild, so "Always Allow" does not survive a rebuild; expect a fresh prompt per build. Acceptable for a personal tool. The 30-min negative cache keeps a *denied* prompt from re-firing every poll.

**Timer/async overlap.** One cancellable `Task` with `Task.sleep`, restarted when the interval changes, plus an `isRefreshing` guard on manual Refresh.

**UserDefaults + Codable.** Encode to `Data`; decode with `try?` + fall back to defaults — otherwise a shape change crashes at launch and Settings can't be opened to fix it.

**Discovery has two halves.** Keychain enumeration says which accounts *exist*; `.claude.json` says what to *call* them. Join on derived service name; unlabeled account falls back to directory basename — don't drop it.

**Don't let one throttled account stall the rest.** Backoff state per-account — bucket is per access token.
