# Changelog

All notable changes to Agents Monitor (formerly Claude Monitor) are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
