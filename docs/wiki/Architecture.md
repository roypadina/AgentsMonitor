# Architecture

Back to [[Home]]. See also: [[User-Guide]], [[Troubleshooting]].

## Why a menu-bar app, not a widget

WidgetKit's refresh budget (roughly 15-minute granularity) is too coarse for a limit monitor
you actually want to check before you blow through a session window, and a widget still needs a
containing app to hold real keychain access — the extension sandbox makes that awkward. A
SwiftUI `MenuBarExtra` in `.window` style gives an always-visible, one-glance summary, native
notifications, and a tiny footprint, at the cost of nothing a widget would have bought here.

Also considered and rejected: a SwiftBar plugin (no room for a settings UI, per-account alerts,
or a toast panel) and an Electron/Tauri shell (heavy, for logic this is entirely `URLSession` +
`Security` framework calls).

## Components

```
ClaudeMonitor.xcodeproj
├── ClaudeMonitorKit/            local SPM package — all logic, headless-testable
│   ├── Models.swift             UsageSnapshot, LimitInfo, SpendInfo, Account, AccountState
│   ├── KeychainService.swift    service-name derivation + read/write primitives
│   ├── CredentialStore.swift    local (read-only) vs remote (read + refresh) token policy
│   ├── UsageClient.swift        URLSession GET + tolerant decode
│   ├── AlertEngine.swift        threshold + severity eval, de-dupe, re-arm, auth debounce
│   └── AppStore.swift           @Observable store, poll loop, per-account backoff
└── ClaudeMonitor/               app target — thin SwiftUI
    ├── App.swift                MenuBarExtra + Settings scene + AppDelegate bootstrap
    ├── PopoverView.swift        account cards, limit rows, pacing tick, spend row
    ├── SettingsView.swift       Accounts / Alerts / General tabs
    ├── Notifier.swift           fan-out: desktop notification + ntfy POST + toast
    └── ToastPanel.swift         floating NSPanel, slide + fade, NSSound
```

All logic — decoding, keychain access, credential policy, alert evaluation, polling — lives in
`ClaudeMonitorKit`, a local Swift package with zero dependency on AppKit or
`UserNotifications`. It's fully unit-tested (19 tests) without touching a real keychain or
network. The app target is thin: it wires the store to SwiftUI views and owns the three alert
sinks the Kit never imports.

## Data flow

1. `AppStore.startPolling()` runs one cancellable `Task` with `Task.sleep` (not a `Timer`,
   which would overlap with an in-flight refresh on interval changes).
2. Each poll fans out per account inside a `TaskGroup`: `CredentialStore.accessToken(for:)`
   resolves a usable token (keychain read, or keychain read + refresh for remote accounts), then
   `UsageClient.fetch(accessToken:)` hits the usage endpoint.
3. The response decodes into a `UsageSnapshot` via a tolerant parser — every field is optional,
   a missing key degrades rather than throws, and any window whose `resets_at` has already
   passed is nulled out rather than shown stale.
4. The resulting `AccountState` for each account feeds `AlertEngine.evaluate(account:state:)`,
   which decides what (if anything) should alert, then `Notifier.deliver` fans out to whichever
   sinks that account has enabled.
5. Accounts, settings, and the alert engine's de-dupe memory are persisted to `UserDefaults` as
   JSON `Data`, decoded with `try?` and a default fallback — a shape change from a future version
   degrades to defaults rather than crashing at launch (which would also lock you out of Settings
   to fix it).

## Data source

`GET https://api.anthropic.com/api/oauth/usage` — the same undocumented endpoint behind `/usage`
in Claude Code itself. Requires a mandatory `User-Agent: claude-cli/…` header; without it,
requests land in an aggressively rate-limited bucket with persistent 429s and no `Retry-After`.
Default poll interval is 180 seconds, a community-measured safe rate. A 429 walks a per-account
backoff ladder (3 → 6 → 12 → 15 minutes, holding at 15, resetting on any 2xx) — deliberately
per-account, since the rate-limit bucket is per access token and one throttled account must
never stall the others.

## <a name="token-policy"></a>Token policy: local vs remote

This is the one rule in the whole app that, if violated, breaks something *outside* the app —
so it's enforced at the type level, not by convention.

- **Local accounts** (`AccountKind.local`) — credentials are owned by Claude Code on this Mac.
  Claude Monitor reads the keychain fresh on every poll and **never runs a refresh grant against
  a local account's token.** Refreshing would consume Claude Code's single-use refresh token;
  the CLI's own next refresh would then fail `invalid_grant` and force that profile to `/login`
  — a bug in a *monitoring* tool logging you out of your own CLI. As long as you use Claude Code
  against that profile occasionally, its token stays fresh without Claude Monitor's help.
- **Remote accounts** (`AccountKind.remote`) — credentials are pasted in and owned entirely by
  Claude Monitor, stored in its own keychain item. There's no CLI on this machine holding the
  same lineage, so Claude Monitor is free to run the OAuth refresh grant
  (`POST https://platform.claude.com/v1/oauth/token`, `grant_type=refresh_token`) and write the
  rotated token back — *unless* the source machine's own Claude Code is still actively refreshing
  that same lineage, which is exactly the [[Troubleshooting#rotation-race|rotation race]].

The switch on `AccountKind` lives inside `CredentialStore.accessToken(for:)`, before any refresh
path is reachable — never left to callers to get right.

## <a name="keychain-access"></a>Keychain access, without a consent prompt

An ad-hoc-signed app reading *another* app's keychain item normally blocks on a password
prompt, because its code-signing identity doesn't match that item's access control list. Two
things make Claude Monitor's reads and writes silent:

- **Reads:** `SecKeychainSetUserInteractionAllowed(false)` turns the would-be consent modal into
  a clean `errSecAuthFailed` instead of a hang. On that failure, Claude Monitor falls back to
  Apple-signed `/usr/bin/security find-generic-password`, which — because it created Claude
  Code's items in the first place — passes the same ACL's partition check silently. This runs
  off-main with a 5-second watchdog, since it's a blocking XPC round trip / child process.
- **Writes** (remote accounts only, to Claude Monitor's *own* items): `SecItemUpdate` first,
  falling back to `SecItemAdd` only on `errSecItemNotFound` — a delete-then-add sequence
  corrupted an item mid-write under concurrent refresh during development, so update-in-place is
  the rule. If even that fails (an ad-hoc app loses access to items its *previous* build's
  cdhash created — expected every rebuild), it falls back again to
  `security add-generic-password -U`, which updates in place atomically regardless of cdhash.

Net effect: no keychain consent dialog, ever, for either reading Claude Code's items or writing
its own — verified live, not just built to spec.

## <a name="why-no-notarization"></a>Why ad-hoc signed, not notarized

Notarization needs a paid Apple Developer ID. This is a personal/local tool; ad-hoc signing
(`CODE_SIGN_IDENTITY = -`) is free and sufficient to run locally, at the cost of the Gatekeeper
prompt on first launch (see [[Installation#gatekeeper]]) and a signature that changes on every
rebuild. Neither cost affects the keychain-access design above, since that design already
assumes the signature is unstable.
