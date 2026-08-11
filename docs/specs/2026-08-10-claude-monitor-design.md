# Claude Monitor — Design

**Date:** 2026-08-10 · **Status:** approved (Roy delegated approval; brainstorm run by Claude as proxy)

## What

Native macOS menubar app monitoring Claude Code usage limits across **N accounts** (each = a `CLAUDE_CONFIG_DIR`), with configurable desktop + ntfy phone alerts. Lives at `~/Code/Padina/ClaudeMonitor`.

## Why menubar app (not widget)

- WidgetKit refresh budget (~15 min granularity) too coarse for a live limit monitor; widget needs a containing app anyway; keychain access from widget extensions is awkward.
- SwiftUI `MenuBarExtra` (window style) = always visible, one glance, native notifications, tiny footprint. Precedent: LanGuard-app (same repo family, same build recipe).
- Rejected: SwiftBar plugin (no settings UI / per-account alerts / toast), Electron/Tauri (heavy, against "thin").

## Data source (verified live 2026-08-10)

`GET https://api.anthropic.com/api/oauth/usage`
Headers: `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`, `Content-Type: application/json`, **`User-Agent: claude-cli/2.1.175 (external, cli)` — mandatory; non-`claude-cli/` UA lands in an aggressively rate-limited bucket (persistent 429s, no Retry-After)**.

Poll default **180s** (community-proven safe TTL; CCSeva + Python monitor). 429 → back off 3→6→12→15 min. 401/403 → "unauthorized" state, no retry-storm. Rate limit bucket is per access token → N accounts poll independently. Endpoint undocumented/unsupported — decoder must be tolerant (all fields optional).

Response (fields we use):
- `limits[]`: `{kind, group, percent, severity(normal|warning|critical), resets_at, scope{model{display_name}}, is_active}` — covers **session** (5h), **weekly_all**, **weekly_scoped** (e.g. `display_name: "Fable"`). Rendered generically → new limit buckets appear automatically.
- `spend`: `{used{amount_minor,exponent,currency}, limit, percent, severity, enabled}` — **extra usage this month in $** (nice-to-have covered). Token-count extra usage skipped (needs JSONL mining à la ccusage; low value vs $ figure — YAGNI).

Credentials: macOS Keychain generic password, service `"Claude Code-credentials"` for `~/.claude`, else `"Claude Code-credentials-" + sha256(absConfigDirPath).hexPrefix(8)` (verified: `~/.claude-work2` → `e5af6df1`; independently confirmed by Claude-Usage-Tracker). JSON payload → `claudeAiOauth.accessToken`, `expiresAt` (**epoch ms**), `subscriptionType`.

Keychain access rules (from OSS research, hard-won):
- Use **`SecItemCopyMatching` API**, never the `security` CLI (payloads >~2KB truncate to invalid JSON) and never `dump-keychain` (hangs indefinitely on macOS 26.x from background-app context). Discovery: `kSecMatchLimitAll` + `kSecReturnAttributes`, filter service prefix `Claude Code-credentials`.
- **30-min negative cache** after a denied keychain prompt — don't re-prompt every poll.
- Account display names without touching secrets: read `~/.claude*/.claude.json` → `oauthAccount.emailAddress` / `organizationName`.

Vendoring (MIT, retain notice): CCSeva `OAuthLimitsProvider/Credentials` (~300 LOC hardened API layer — timeouts, negative cache, tolerant decoder) and Claude-Usage-Tracker keychain discovery/derivation. Copy of the latter at scratchpad `ccsync.swift`.

Decoding traps: treat any object with numeric `utilization` + `resets_at` as a window (auto-picks-up future buckets); `utilization` is percent-integer, clamp 0–100; **null out a window when now ≥ resets_at** (server serves stale windows); prefer `limits[]` (has severity + Fable scope) with the loose top-level windows as fallback. Weekly `resets_at` is unreliable upstream — show it, don't promise it.

**Token policy — two account types:**
- **Local** (has `CLAUDE_CONFIG_DIR` on this Mac): read keychain fresh on every poll; never refresh tokens ourselves (avoids refresh-race with Claude Code's own rotation). On 401/expired → account state "re-auth needed" (alertable). Claude Code running regularly on this Mac keeps tokens fresh.
- **Remote** (account not logged in on this Mac): user pastes the credentials JSON (from the other machine: `security find-generic-password -s "Claude Code-credentials" -w`, or `~/.claude/.credentials.json` on Linux). Stored in Claude Monitor's own keychain item (`ClaudeMonitor-account-<uuid>`). App refreshes the token itself when expired (OAuth refresh_token grant, Claude Code public client id — exact endpoint/params confirmed from OSS research); rotated refresh token saved back. No local Claude Code instance → no race. If refresh fails (rotation invalidated by source machine, revocation) → "re-paste credentials" state (alertable). Caveat documented in README: best for accounts not actively rotating on the source machine.

**Keychain prompt:** none, ever (amended during live QA). `SecKeychainSetUserInteractionAllowed(false)` turns the would-be consent modal into a clean `errSecAuthFailed`, and reads fall back to Apple-signed `/usr/bin/security` — which created Claude Code's items and passes their keychain partition check silently (verified live; a direct `SecItemCopyMatching` from an ad-hoc app blocks on a password prompt instead). Writes to app-owned items fall back to `security add-generic-password -U`, which also survives the ad-hoc cdhash changing every rebuild.

## Architecture

```
ClaudeMonitor.xcodeproj
├── ClaudeMonitorKit/            local SPM package — all logic, headless-testable
│   ├── Models.swift             UsageSnapshot, LimitInfo, SpendInfo, Account (Codable)
│   ├── KeychainService.swift    service-name derivation + SecItemCopyMatching read
│   ├── UsageClient.swift        URLSession GET + decode
│   ├── AlertEngine.swift        threshold eval + de-dupe + re-arm
│   └── Tests/                   XCTest: fixtures (real captured JSON), parsing,
│                                derivation, alert transitions
└── ClaudeMonitor/               app target — thin UI
    ├── App.swift                MenuBarExtra(.window) + poll loop (Timer, default 60s)
    ├── PopoverView.swift        account cards
    ├── SettingsView.swift       Accounts / Alerts / General tabs
    ├── Notifier.swift           UNUserNotificationCenter + ntfy POST + toast panel
    └── ToastPanel.swift         floating NSPanel, slide+fade animation, NSSound
```

- **Accounts** stored in `UserDefaults` (Codable array): `{id, name, configDirPath, desktopAlerts, ntfyEnabled, ntfyTopicOverride?}`.
- **First run auto-discovery:** always add `~/.claude` ("claude") if keychain entry exists; glob `~/.claude-*` dirs, derive hash, add those with keychain entries (→ finds `claude-work2`). Names editable.
- **Poll loop:** async, per-account concurrent, updates `@Observable` store; menubar + popover react.

## UI

- **Menubar:** gauge icon + worst-limit percent across accounts (e.g. `95%`). Color-tint if menu bar allows non-template rendering; otherwise plain text — severity color lives in popover/toast (implementer's call, don't fight AppKit).
- **Popover (window style):** card per account — name (default from `.claude.json` `oauthAccount.emailAddress`/org, editable) + tier badge; row per limit: label (Session / Week / Week Fable via `scope.display_name`), colored progress bar (green/orange/red by severity) **with pacing tick** (where you *should* be for even burn: elapsed% of window, start = resets_at − window length), %, "resets in 2h 14m"; spend row `$728.60 / $800.00 · 91% of monthly extra`. Error states: "not logged in" / "re-auth needed" / stale-data badge on network fail. Footer: last-refresh time, Refresh, Settings, Quit.
- **Settings:** Accounts (add via folder picker, rename, per-account alert toggles + ntfy topic override, remove) · Alerts (warning/critical thresholds — default 80/95, ntfy server+default topic, test-alert button) · General (poll interval 30s–10m, launch at login via `SMAppService`, show-percent-in-menubar toggle).
- Design: native macOS look, thin; one delight = toast slide-in animation + sound. No custom design system.

## Alerts

- **Trigger:** per (account, limit-kind): level = max(API `severity`, threshold eval of `percent`). Fire on level *increase*; also fire on "re-auth needed". Spend treated as another limit.
- **De-dupe/re-arm:** remember last alerted level per (account, kind, `resets_at`); reset when window rolls or level drops.
- **Sinks (per-account toggles):** desktop notification (UNUserNotificationCenter, sound) · ntfy POST (`server/topic`, Title/Priority/Tags headers; priority maps warning→default, critical→high) · in-app toast (NSPanel slide+fade, NSSound) always when app frontmost-visible.
- Default ntfy server `https://ntfy.sh`; the user's topic lives only in local settings, never in the repo.

## Testing / success criteria (goal: working, tested, ready)

1. `swift test` green in ClaudeMonitorKit (parsing both real fixture shapes — with/without spend limit, derivation, alert-engine transitions).
2. Release build, ad-hoc signed, unsandboxed, installed to /Applications, launched.
3. Live: both real accounts polling, correct %s vs curl ground truth.
4. Forced alert (threshold dropped to 1%) → desktop notification + ntfy delivery + toast w/ sound observed.
5. Settings changes persist across relaunch.

## Non-goals

Token-level usage accounting (ccusage exists), historical charts, token refresh, App Store distribution, sandboxing.
