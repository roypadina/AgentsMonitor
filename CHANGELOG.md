# Changelog

All notable changes to Agents Monitor (formerly Claude Monitor) are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.7.2] - 2026-10-30

### Fixed
- A failed refresh now says what went wrong in plain words, such as "Can't reach Anthropic: timed out", instead of an internal error code.
- After a relaunch, an account whose first refresh fails keeps showing its last known numbers, with how old they are, instead of a blank card.
- Numbers more than an hour old leave the menu bar while refreshes keep failing, because it has no room to say how old they are. The popover still shows them, with their age.

## [1.7.1] - 2026-10-30

### Fixed
- A Codex account no longer alerts at 75% when your warning threshold is higher: Codex alerts now follow only your own thresholds.

## [1.7.0] - 2026-10-30

### Added
- A welcome window on first launch (shown once after updating too, and **Welcome Guide…** in Settings > About): why Agents Monitor exists, where it lives, and the Open at Login switch.
- Opening Agents Monitor again from Applications or Raycast opens Settings, so there is a way in when the menu bar icon is hidden.
- The empty popover has an **Add Account…** button.
- Keyboard shortcuts in the popover: ⌘R Refresh, ⌘, Settings, ⌘Q Quit.

### Changed
- Settings is its own window with a toolbar of tabs, each sized to its content (Alerts and General are no longer cut off), and it shows in the Dock and ⌘-Tab while open.
- **Add Account** is one menu (Claude Code, Codex, Remote Claude) instead of three truncated buttons.
- With 5 or more accounts the popover scrolls instead of growing off the screen, so Settings and Quit stay reachable.
- Status and warning text in the popover is easier to read on the light background; only the symbols keep the orange/red colour.
- The repaste hint (the Terminal commands) can be selected and copied.

### Fixed
- Open at Login is no longer switched on by itself at first launch, and turning it off now sticks. It is a switch in the welcome window and Settings > General.
- The ntfy access token and fallback URL are saved when the Settings window is closed, not only on Return or tab change.
- The remove-account button has a name for VoiceOver and a tooltip.

## [1.6.1] - 2026-10-27

### Fixed
- No more repeated "security wants to use your confidential information" login-password prompts after updates. The keychain items Agents Monitor saves (ntfy access token and fallback URL, remote accounts) are now created through macOS's `security` tool, which every version reads silently. If you already saw the prompt for an item, click **Always Allow** once.

## [1.6.0] - 2026-10-25

### Added
- ntfy: optional access token (stored in the Keychain, sent only to your configured server) so the app can publish to a self-hosted server that requires a login.
- ntfy: optional fallback topic URL (Keychain) used when the server errors or times out.
- ntfy messages carry an `agents-monitor` tag and a short trace footer (sender, flow, event id, log hint); each send logs one `ntfy event=...` line.

## [1.5.5] - 2026-10-25

### Changed
- Releases are now signed with a stable identity, so permissions survive future updates. After this one update you may need to re-allow keychain access once (only if you added remote accounts; Claude Code and Codex accounts are unaffected).

## [1.5.4] - 2026-10-23

### Added
- About: request a feature / contribute. Two new buttons in the About window open the feature-request form and CONTRIBUTING.md; Ko-fi supporters' requests go to the front of the queue.

## [1.5.3] - 2026-10-23

### Removed
- The "ccpool switches" section and the switch markers on the graphs, together with the code that read an account-pooling script's log. Agents Monitor no longer depends on any other tool.

### Changed
- The per-account usage cache now lives in `~/Library/Caches/<bundle id>/` instead of `~/.cache/claude-pool/`. The old directory is simply no longer used.
- README and wiki: new Privacy section (what is read, what leaves the Mac, how remote accounts are stored, no affiliation with Anthropic or OpenAI).
- Test fixtures and docs use generic paths and addresses.

## [1.5.2] - 2026-10-23

### Changed
- Universal build: now runs on Intel Macs as well as Apple Silicon.
- README rewritten as a landing page with fresh screenshots (fake accounts), install one-liner and macOS 15+ first-launch steps (Open Anyway).
- Added CI, contributing guide, security policy, code of conduct and issue/PR templates; internal design docs are no longer tracked.

## [1.5.1] - 2026-10-15

### Fixed
- The footer no longer cuts the last-refresh time to "Update…": the popover is a little wider, and on a tight fit the word "Updated" is dropped before the time is.

## [1.5.0] - 2026-10-15

### Added
- **Usage graphs:** the chart button on a card turns it over to show each limit, and spend, as a graph over the last 24 hours, 7 days or 30 days. Same card, same size; the chip in its header switches the span.
- **Burn-rate warning:** a limit on track to run out before it resets shows "full in ~Xh at this pace" under its bar.
- **Usage history:** every poll is saved to `~/Library/Application Support/AgentsMonitor/history.jsonl` and kept for 90 days.
- **Account-switch markers:** when an account-pooling script (such as ccpool) writes `~/.local/state/claude-pool/events.jsonl`, its switches show as markers on the graphs (red when no account was free), and the last five appear under the cards with every account's numbers at that moment.

### Changed
- The popover is wider (420 pt), so the footer buttons no longer get cut off.

## [1.4.7] - 2026-10-03

### Changed
- Custom About window (no more clipped credits); compact Settings About tab.

## [1.4.6] - 2026-10-03

### Added
- About tab in Settings, About and Support menu items, Ko-fi support links.

## [1.4.5] - 2026-09-26

### Fixed
- Claude accounts no longer get stuck on "Usage API throttled" when other local tools poll the same account. Local accounts share one usage read through a cache file: a result under 3 minutes old is reused, and a 429 keeps every reader off the endpoint until its `Retry-After` has passed.

## [1.4.4] - 2026-09-26

### Fixed
- Claude accounts stuck on "Usage API throttled": the default account now reads whichever keychain item Claude Code keeps fresh, and an expired login token shows as "login expired" instead of being sent to the usage API.

## [1.4.3] - 2026-09-22

### Added
- App icon: amber speedometer gauge with the needle in the red (the app previously shipped with no icon).

## [1.4.2] - 2026-09-10

### Removed
- Expired-login-token notifications. They fired repeatedly while the CLI kept working; auth states no longer notify. The popover still shows the "Login token expired" status line.

## [1.4.1] - 2026-09-04

### Fixed
- The Settings button in the popover did nothing: the app is an accessory (menu-bar-only) app, so the Settings window stayed behind everything else. The button now activates the app first and then orders the window front.
- The three footer buttons now have accessibility labels (VoiceOver announced anonymous buttons).

## [1.4.0] - 2026-09-04

### Added
- Provider badge (mark plus name) on every account in the popover and in Settings → Accounts, and a stripe in the provider's color down the leading edge of popover cards.
- Settings → General → Accounts picks how much shows (icon and name, icon only, name only, or hidden) and whether it is colored, with a live preview.
- Rename any account from Settings → Accounts → Rename.

## [1.3.0] - 2026-09-04

### Added
- Codex support: any `CODEX_HOME` signed in with a ChatGPT account is discovered automatically and polled for usage (the same numbers the Codex status line shows, without a model call). The 5-hour window shows as Session, the weekly one as Week, plus the code-review cap if the plan reports one; menu-bar metrics, usage dot, pacing ticks and alerts work as for Claude accounts.
- Credentials come from `<CODEX_HOME>/auth.json`; the token is never refreshed by this app. A persistent 401 shows "run codex in this profile".

### Changed
- Renamed from Claude Monitor to Agents Monitor: app, bundle identifier, repository and Homebrew cask (`agents-monitor`). Accounts, settings and alert memory migrate automatically.

### Notes
- After upgrading from 1.2.x, remove the old `ClaudeMonitor.app` and its stale Login Items entry.

## [1.2.1] - 2026-08-21

### Fixed
- A single HTTP 429 from the usage endpoint no longer blanks an account: the last good snapshot stays on screen with a one-line note.
- The status line now says "Usage API throttled - retrying <time>" instead of "Rate limited until <time>", which read like an exhausted plan quota.

### Changed
- Fewer requests to the usage endpoint: default poll interval 180 s → 300 s, a 20 s floor between requests, and the 401 retry only spends a second request when the keychain token actually rotated.

## [1.2.0] - 2026-08-11

### Added
- Extra-usage alert: a notification the moment paid usage starts being consumed, with the amount just spent and the running monthly total.
- Configurable menu bar: which accounts appear, which value each shows (session/weekly max, session, weekly, or per-model weekly), optionally with the per-model window or the extra usage spent.
- Gradient usage dot per account (green → yellow → red); turn off percentages for a dots-only menu bar.

### Changed
- "Worst limit" is now "Session or weekly (max)": a maxed-out per-model window no longer becomes the account's headline number or drives the dot.

### Fixed
- Settings changes needed a relaunch to reach the alert engine.
- Settings and accounts could be silently reset on upgrade (strict decoding); both now decode leniently.

## [1.1.0] - 2026-08-11

### Added
- Extra-usage alert (Settings → Alerts), one alert per burst, re-armed after 30 minutes of flat spend; adding an account never alerts on past spend.

### Fixed
- Alert storm: window-roll detection now uses a 120 s tolerance, and alert de-dupe memory persists across relaunches.
- False "re-authentication needed" alerts: a single 401 now triggers a keychain re-read and one retry, and auth alerts need two consecutive failed polls.
- Settings changes needed a relaunch.
- Settings could be silently reset on upgrade; all fields now decode leniently.

## [1.0.0] - 2026-08-11

First public release (as Claude Monitor).

### Added
- macOS menu-bar monitor for Claude Code usage limits across multiple accounts: session / weekly / per-model windows, extra-usage spend, pacing ticks, desktop + ntfy + toast alerts.

### Notes
- Ad-hoc signed, not notarized: right-click → Open on first launch.

[Unreleased]: https://github.com/roypadina/AgentsMonitor/compare/v1.4.7...HEAD
[1.4.7]: https://github.com/roypadina/AgentsMonitor/compare/v1.4.6...v1.4.7
[1.4.6]: https://github.com/roypadina/AgentsMonitor/compare/v1.4.5...v1.4.6
[1.4.5]: https://github.com/roypadina/AgentsMonitor/compare/v1.4.4...v1.4.5
[1.4.4]: https://github.com/roypadina/AgentsMonitor/compare/v1.4.3...v1.4.4
[1.4.3]: https://github.com/roypadina/AgentsMonitor/compare/v1.4.2...v1.4.3
[1.4.2]: https://github.com/roypadina/AgentsMonitor/compare/v1.4.1...v1.4.2
[1.4.1]: https://github.com/roypadina/AgentsMonitor/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/roypadina/AgentsMonitor/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/roypadina/AgentsMonitor/compare/v1.2.1...v1.3.0
[1.2.1]: https://github.com/roypadina/AgentsMonitor/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/roypadina/AgentsMonitor/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/roypadina/AgentsMonitor/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/roypadina/AgentsMonitor/releases/tag/v1.0.0
