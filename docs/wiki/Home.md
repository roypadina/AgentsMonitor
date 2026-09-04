# Agents Monitor Wiki

Agents Monitor is a native macOS menu-bar app that polls the usage endpoints Claude Code and
Codex use themselves, for any number of accounts of either — local ones already logged in on
this Mac, and remote ones pasted in from elsewhere — and alerts you (desktop,
[ntfy](https://ntfy.sh) push, in-app toast) before a session, weekly, or spend limit runs out.

No third-party dependencies, no telemetry, MIT licensed. See the
[repository README](https://github.com/roypadina/AgentsMonitor#readme) for the elevator pitch
and install one-liner.

## Pages

- **[[Installation]]** — Homebrew, manual, build from source, Gatekeeper, first run
- **[[User-Guide]]** — reading the popover, accounts, alert semantics, every setting, ntfy setup
- **[[Troubleshooting]]** — expanded FAQ: rotation races, 429s, keychain denials, and what each
  card state actually means
- **[[Architecture]]** — components, data flow, why a menu-bar app instead of a widget, and the
  keychain/token rules that keep this app from breaking your Claude Code or Codex login

## Quick facts

| | |
|---|---|
| Platform | macOS 14+ (Sonoma), Apple Silicon and Intel |
| Distribution | Homebrew tap (`roypadina/tap`), GitHub Releases, build from source |
| Signing | Ad-hoc (not notarized) — see [[Installation#gatekeeper]] |
| Dependencies | None — pure SwiftUI + Foundation + Security framework |
| Data source | Anthropic's undocumented OAuth usage endpoint (same data as `/usage` in Claude Code) and `chatgpt.com/backend-api/codex/usage` (same numbers as the Codex status line) |
| License | MIT |

For the full canonical guides (kept in the repo itself, not just the wiki) see
[docs/INSTALL.md](https://github.com/roypadina/AgentsMonitor/blob/main/docs/INSTALL.md) and
[docs/USER-GUIDE.md](https://github.com/roypadina/AgentsMonitor/blob/main/docs/USER-GUIDE.md).
