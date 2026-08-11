# Installation

Back to [[Home]]. See also: [[User-Guide]] for what happens after you launch it,
[[Troubleshooting]] if something's not right.

Requires macOS 14 (Sonoma) or later.

## Homebrew (recommended)

```bash
brew tap roypadina/tap
brew install --cask claude-monitor
```

## Manual install

Download `ClaudeMonitor.app.zip` from
[Releases](https://github.com/roypadina/ClaudeMonitor/releases), unzip, drag into
`/Applications`.

## Build from source

```bash
git clone https://github.com/roypadina/ClaudeMonitor.git
cd ClaudeMonitor
xcodebuild -workspace ClaudeMonitor.xcworkspace -scheme ClaudeMonitor \
  -configuration Release -derivedDataPath build build
cp -R build/Build/Products/Release/ClaudeMonitor.app /Applications/
open /Applications/ClaudeMonitor.app
```

`swift test --package-path ClaudeMonitorKit` runs the 19 unit tests with no keychain or network
access needed, if you want to verify your toolchain first.

## Gatekeeper

Claude Monitor is **ad-hoc signed, not notarized** — there's no paid Apple Developer ID behind
it, so macOS blocks the first launch. Two ways past it:

- Right-click `ClaudeMonitor.app` in `/Applications` → **Open** → **Open** again on the
  follow-up dialog.
- Or: `xattr -dr com.apple.quarantine "/Applications/ClaudeMonitor.app"`

Ad-hoc signing also means the app's designated requirement (its cdhash) changes on every
rebuild. If you build from source repeatedly, expect this prompt — and any keychain "Always
Allow" — to reset each time. See [[Architecture#why-no-notarization]] for the reasoning, and
[[Architecture#keychain-access]] for why that doesn't actually block normal use.

## First run

- No Dock icon — it's a menu-bar-only app. Look for the gauge icon.
- Accounts are **auto-discovered**: every `~/.claude` / `~/.claude-*` directory with a matching
  keychain entry becomes a local account automatically. See [[User-Guide#accounts]] for how
  naming and remote accounts work.
- macOS prompts for **notification permission** — click **Allow** if you want desktop alerts.
  ntfy and toast alerts work either way.
- Polling starts immediately at the default 180-second interval.

## Updating

`brew upgrade --cask claude-monitor`, or repeat the manual/source install — settings and
accounts live outside the app bundle so nothing is lost on replace.

## Uninstall

```bash
brew uninstall --cask claude-monitor        # or: rm -rf /Applications/ClaudeMonitor.app
defaults delete com.roy.claudemonitor       # optional: forget settings/accounts
```

Remote-account keychain items (`ClaudeMonitor-account-<uuid>`) aren't touched by
`defaults delete` — see the full [Uninstall section](https://github.com/roypadina/ClaudeMonitor/blob/main/docs/INSTALL.md#uninstall)
in the repo docs if you added any and want them gone too.
