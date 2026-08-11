# Install

Requires **macOS 14 (Sonoma) or later**. No admin rights, no sudo, no paid Apple Developer
account needed to build or run it.

## Homebrew (recommended)

```bash
brew tap roypadina/tap
brew install --cask claude-monitor
```

Homebrew installs to `/Applications/ClaudeMonitor.app`. `brew upgrade --cask claude-monitor`
picks up new releases later.

## Manual install

1. Download the latest `ClaudeMonitor.app.zip` from the
   [Releases page](https://github.com/roypadina/ClaudeMonitor/releases).
2. Unzip it and drag `ClaudeMonitor.app` into `/Applications`.
3. Launch it from Applications or Spotlight.

## Build from source

```bash
git clone https://github.com/roypadina/ClaudeMonitor.git
cd ClaudeMonitor
xcodebuild -workspace ClaudeMonitor.xcworkspace -scheme ClaudeMonitor \
  -configuration Release -derivedDataPath build build
cp -R build/Build/Products/Release/ClaudeMonitor.app /Applications/
open /Applications/ClaudeMonitor.app
```

Run the unit tests first if you want to sanity-check your toolchain before building the app:

```bash
swift test --package-path ClaudeMonitorKit    # 19 tests, no network/keychain access needed
```

## Gatekeeper (ad-hoc signing)

Claude Monitor is signed ad-hoc (`CODE_SIGN_IDENTITY = -`), not notarized — there's no paid
Apple Developer ID behind it. macOS will refuse to open it the first time with a "can't be
opened because Apple cannot check it for malicious software" dialog. Two ways past it:

- **Right-click (or Control-click) `ClaudeMonitor.app` in `/Applications` → Open**, then click
  **Open** again on the follow-up dialog. Only needed once.
- Or clear the quarantine flag yourself:
  ```bash
  xattr -dr com.apple.quarantine "/Applications/ClaudeMonitor.app"
  ```

Homebrew casks generally clear quarantine automatically on install; if you still hit the dialog
after a `brew install --cask`, the `xattr` command above works regardless of install method.

Because the app is ad-hoc signed, its designated requirement (the cdhash) changes on every
rebuild. If you build from source repeatedly, expect the Gatekeeper prompt — and any keychain
"Always Allow" you granted — to reset each time. This is expected and harmless for a personal
tool; see [the Architecture wiki page](wiki/Architecture.md) for why the app doesn't need it
anyway.

## First run

1. **No Dock icon.** Claude Monitor is a menu-bar-only app (`LSUIElement`); look for the gauge
   icon in the menu bar.
2. **Accounts are auto-discovered.** On first launch, Claude Monitor checks `~/.claude` and any
   `~/.claude-*` directory for a matching keychain entry and adds every one it finds as a local
   account, named from that profile's email/org in its `.claude.json`. If you use Claude Code
   with only one profile, you'll see exactly one account card. Nothing is added if it can't find
   a matching keychain entry — check [Troubleshooting](USER-GUIDE.md#troubleshooting) if you
   expected an account that didn't show up.
3. **Notification permission.** macOS will prompt to allow notifications. Click **Allow** if
   you want desktop alerts — without it, desktop notifications are silently dropped (ntfy and
   toast alerts still work regardless of this permission).
4. It starts polling immediately at the default 180-second interval. The popover fills in as
   soon as the first poll for each account completes.

## Updating

- **Homebrew:** `brew upgrade --cask claude-monitor`
- **Manual / build from source:** repeat the install steps above — settings, accounts, and
  alert history all live in `UserDefaults` and the keychain, independent of the app bundle, so
  replacing the `.app` doesn't lose anything.

## Uninstall

```bash
# if installed via Homebrew
brew uninstall --cask claude-monitor

# otherwise, just remove the app
rm -rf /Applications/ClaudeMonitor.app
```

Also remove it from **System Settings → General → Login Items** if you enabled "Start at
login" and it's still listed there.

To forget all settings and accounts (optional — this does not touch your actual Claude Code
login, only Claude Monitor's own state):

```bash
defaults delete com.roy.claudemonitor
```

If you added any **remote accounts**, Claude Monitor stored their credentials in its own
keychain items, one per account, named `ClaudeMonitor-account-<uuid>`. `defaults delete` above
does not remove these — list and delete them explicitly if you want them gone:

```bash
# list them
security dump-keychain 2>/dev/null | grep -A1 'ClaudeMonitor-account-' | grep '"svce"' | sort -u

# delete one by its exact service name
security delete-generic-password -s "ClaudeMonitor-account-<uuid>"
```

Uninstalling never touches any `Claude Code-credentials*` keychain item — those belong to
Claude Code, not to this app, and Claude Monitor only ever reads them.
