# User Guide

Back to [[Home]]. See also: [[Installation]], [[Troubleshooting]], [[Architecture]].

## Menu bar

Gauge icon + the **worst percent across every configured account**. Plain text/icon only — it's
a template image, so it can't carry severity color (that lives in the popover and toasts).
Toggle it off in Settings → General → "Show percent in menu bar".

## Popover

One card per account, one row per limit, colored by severity exactly as Anthropic's API reports
it:

- 🟢 green = normal, 🟠 orange = warning, 🔴 red = critical
- **Pacing tick** on the bar — where you'd be if you were burning the limit at a perfectly even
  rate across the window. Bar left of the tick = under budget for the window so far; right of
  the tick = burning faster than even.
- `Session` = rolling 5-hour window · `Week` = 7-day window · `Week · <model>` = a model-scoped
  weekly limit (e.g. `Week · Fable`). New limit kinds Anthropic adds later render the same way
  automatically.
- A **Spend** row appears when there's a configured monthly extra-usage budget or anything's
  been spent: `$728.60 / $800.00 · 91%`.

Error states replace the limit rows entirely when something's wrong — see
[[Troubleshooting#card-states]] for what each one means.

## Accounts

**Local** — a `CLAUDE_CONFIG_DIR` already logged in to Claude Code on this Mac. Auto-discovered
on first launch. Tokens are read fresh from the keychain every poll and **never refreshed by
this app** — see [[Architecture#token-policy]] for why that rule exists and what would break if
it didn't.

**Remote** — an account living on another machine. Add it from Settings → Accounts → *Add
Remote Account…*, pasting the credentials JSON:

```bash
security find-generic-password -s "Claude Code-credentials" -w    # macOS source machine
cat ~/.claude/.credentials.json                                    # Linux source machine
```

Agents Monitor stores it in its own keychain item and refreshes it itself. If the source
machine is *also* actively refreshing that same lineage, one side loses the race — see
[[Troubleshooting#rotation-race]].

## Alerts

`level = max(API severity, threshold level of percent)`. Defaults: 80% warning, 95% critical.
Fires on a level **increase**, or on a window roll while above `none`; a drop clears the memory
so climbing back up alerts again. This memory persists across relaunches.

Auth failures debounce: a local account's single 401 is usually Claude Code rotating its own
token, so the alert only fires on the **second consecutive** failed poll. See
[[Troubleshooting#rotation-race]] for the full story.

Three sinks, each per-account toggleable: **Desktop** notification, **ntfy** push (JSON POST,
priority 3/4), **Toast** panel (global on/off, not per-account).

## ntfy setup

1. Install the [ntfy app](https://ntfy.sh) on your phone.
2. Pick an unguessable topic name, subscribe to it in the app.
3. Settings → Alerts: set server (default `https://ntfy.sh`) and default topic.
4. Settings → Accounts: enable ntfy per account, optionally with its own topic override.
5. Settings → Alerts → **Send Test Alert** to confirm delivery.

## Settings reference

| Tab | Options |
|---|---|
| Accounts | Add Local/Remote, rename, per-account Desktop/ntfy toggles + topic override, remove, Repaste for expired remote credentials |
| Alerts | Warning/critical thresholds, ntfy server + default topic, notification authorization status, Send Test Alert |
| General | Poll interval (30s–10m), Start at login (self-healing), show-percent toggle, toast on/off, sound on/off |

Full detail, screenshots, and the complete troubleshooting table live in
[docs/USER-GUIDE.md](https://github.com/roypadina/AgentsMonitor/blob/main/docs/USER-GUIDE.md) in
the repo.
