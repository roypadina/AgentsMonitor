<div align="center">

# Claude Monitor

### Watch your Claude Code usage limits from the menu bar — before you hit them.

A tiny native macOS menu-bar app that polls Claude Code's own usage endpoint for
**any number of accounts** on this Mac (or pasted in from another machine) and alerts you —
desktop notification, in-app toast with sound, and [ntfy](https://ntfy.sh) push to your phone —
before a session, weekly, or spend limit runs out from under you.

[![macOS](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Homebrew](https://img.shields.io/badge/brew-roypadina%2Ftap-FBB040?logo=homebrew&logoColor=white)](https://github.com/roypadina/homebrew-tap)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg?logo=opensourceinitiative&logoColor=white)](LICENSE)

<br>

<img src="docs/screenshots/popover.png" alt="Claude Monitor popover: three accounts, each showing Session/Week/Week · Fable progress bars with severity coloring and a pacing tick, plus a monthly spend row." width="420">

</div>

---

## What it shows

Per account, straight from Anthropic's OAuth usage endpoint — the same data behind `/usage`
in Claude Code itself:

- **Session** (5-hour window), **Week**, **Week · Fable** (and any future limit bucket —
  rendering is generic, so new buckets from Anthropic show up automatically, no update needed)
- **Extra-usage spend this month** (`$728.60 / $800.00 · 91%`)
- Severity coloring (green / orange / red) exactly as the API reports it, a **pacing tick** on
  each bar (where an even burn rate would put you right now), and a "resets in 2h 14m" countdown
- Menu-bar label: the worst percent across every configured account, at a glance

## Accounts

- **Local** — any `CLAUDE_CONFIG_DIR` already logged in on this Mac (`~/.claude`,
  `~/.claude-work2`, …). Auto-discovered on first launch straight from the keychain, and
  labeled using the email/org in `~/.claude*/.claude.json`. Tokens are read fresh from the
  keychain on every poll and **never refreshed by this app** — refreshing would burn Claude
  Code's single-use refresh token and force that profile into `/login`.
- **Remote** — an account that lives on a *different* machine. Settings → Accounts → **Add
  Remote Account…**, then paste the credentials JSON from the source machine:
  - macOS: `security find-generic-password -s "Claude Code-credentials" -w`
  - Linux: `cat ~/.claude/.credentials.json`

  Stored in an app-owned keychain item, device-only (no iCloud sync). Claude Monitor refreshes
  these tokens itself once they expire. One caveat: if the source machine's own Claude Code also
  refreshes that lineage, one side loses the race and the card falls back to
  *Paste credentials…* — see [the User Guide](docs/USER-GUIDE.md#remote-accounts) for the details.

## Alerts

Fires when the **worse of** your warning/critical thresholds (default 80% / 95%) and the API's
own severity is exceeded — de-duped per limit per reset window, and a drop below threshold
re-arms it. A single failed poll on a local account is treated as a likely token-rotation race,
not a real auth failure: the alert only fires on two consecutive strikes, and the memory of
what's already fired survives an app relaunch.

Three sinks, each toggleable per account in Settings:
- **Desktop** — a standard notification (grant permission once when macOS asks on first launch)
- **ntfy** — a JSON POST to your server/topic, priority 3 (warning) / 4 (critical); each account
  can override the default topic
- **Toast** — a floating panel top-right with a slide-and-fade animation and a sound

<div align="center">
<img src="docs/screenshots/toasts.png" alt="Claude Monitor toast notifications stacking top-right for a Week · Fable and a Spend alert, plus the macOS login-item banner." width="420">
</div>

## Install

### Homebrew (recommended)

```bash
brew tap roypadina/tap
brew trust --cask roypadina/tap/claude-monitor   # newer Homebrew requires trusting third-party casks
brew install --cask claude-monitor
```

The app is ad-hoc signed (not notarized). After install, either right-click it in
`/Applications` → **Open**, or clear quarantine: `xattr -dr com.apple.quarantine "/Applications/ClaudeMonitor.app"`.

### Manual install

Download the latest `ClaudeMonitor.app.zip` from
[Releases](https://github.com/roypadina/ClaudeMonitor/releases), unzip, and drag
`ClaudeMonitor.app` into `/Applications`.

### Build from source

```bash
git clone https://github.com/roypadina/ClaudeMonitor.git
cd ClaudeMonitor
xcodebuild -workspace ClaudeMonitor.xcworkspace -scheme ClaudeMonitor \
  -configuration Release -derivedDataPath build build
cp -R build/Build/Products/Release/ClaudeMonitor.app /Applications/
open /Applications/ClaudeMonitor.app
```

> Claude Monitor is **ad-hoc signed, not notarized** (no paid Apple Developer ID). On first
> launch macOS will refuse to open it — **right-click the app in `/Applications` → Open** (then
> Open again on the second dialog), or clear quarantine yourself:
> ```bash
> xattr -dr com.apple.quarantine "/Applications/ClaudeMonitor.app"
> ```
> Every line of this app is in this repo — build it yourself if you'd rather not trust a
> prebuilt binary. See [docs/INSTALL.md](docs/INSTALL.md) for the full walkthrough, including
> first-run behavior and uninstalling.

## No keychain prompts

Reading another app's keychain item from an ad-hoc-signed app normally blocks on a consent
dialog. Claude Monitor suppresses that keychain UI and falls back to Apple-signed
`/usr/bin/security`, which created Claude Code's items and passes their keychain partition check
silently — so it works headless, survives rebuilds, and never interrupts you with a password
prompt.

## Learn more

- [docs/INSTALL.md](docs/INSTALL.md) — install, first run, updating, uninstall
- [docs/USER-GUIDE.md](docs/USER-GUIDE.md) — every screen, every setting, ntfy setup from
  scratch, alert semantics, troubleshooting
- [Wiki](docs/wiki/Home.md) — architecture, design rationale, expanded FAQ

## Build & test

```bash
swift test --package-path ClaudeMonitorKit          # 19 unit tests (parsing, derivation, alert engine, credentials)
xcodebuild -workspace ClaudeMonitor.xcworkspace -scheme ClaudeMonitor \
  -configuration Release -derivedDataPath build build
cp -R build/Build/Products/Release/ClaudeMonitor.app /Applications/
```

No third-party dependencies. All logic lives in the `ClaudeMonitorKit` local SPM package,
independently testable with no keychain or network access required; the app target is thin
SwiftUI (`MenuBarExtra`).

Keychain/OAuth internals adapted from MIT-licensed [CCSeva](https://github.com/Iamshankhadeep/ccseva)
and [Claude-Usage-Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker) (see
`docs/reference-ccsync.swift`; attribution headers in `KeychainService.swift` /
`CredentialStore.swift`).

## Debugging / logs

Everything logs to unified logging under subsystem `com.roy.claudemonitor` (categories: `poll`,
`alerts`, `http`, `credentials`, `notify`). No tokens or credential payloads are ever logged; account display names do appear
in your local log (it never leaves this Mac).

```bash
# live tail
/usr/bin/log stream --predicate 'subsystem == "com.roy.claudemonitor"' --level debug
# recent history (persisted store)
/usr/bin/log show --last 2h --info --debug --predicate 'subsystem == "com.roy.claudemonitor"'
```

Alert decisions log as `eval <account>/<limit>: <pct>% level=<new> stored=<old> sameWindow=<bool>
fire=<bool>` — enough to reconstruct why any alert did or didn't fire. Alert de-dupe memory
persists across relaunches (`ClaudeMonitor.alertMemory` in `defaults`); delete that key to force
a full re-alert.

Window-roll detection uses a 120s tolerance on `resets_at` because the server recomputes it on
every request (±1–2s observed) — exact comparison caused an alert on every single poll once
(351 phone pushes in 12 hours, before this was caught).

## Caveats

- The usage endpoint is undocumented and unsupported by Anthropic; the mandatory
  `claude-cli/…` User-Agent and 180s default poll interval come from community-measured
  rate-limit behavior. If polling 429s, the app backs off 3 → 6 → 12 → 15 minutes per account.
- Weekly `resets_at` is the server's own naive rolling-window estimate — treat the countdown as
  approximate, not authoritative.
- Not sandboxed, not notarized. It reads another app's keychain item and calls an undocumented
  Anthropic endpoint — both are why. See [Is it safe?](docs/USER-GUIDE.md#is-it-safe) in the
  user guide.

## License

[MIT](LICENSE) © 2026 Roy Padina — see [LICENSE](LICENSE) for the vendored-code attribution to
CCSeva and Claude-Usage-Tracker.
