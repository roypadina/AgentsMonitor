# Agents Monitor demo — storyboard (12.8 s, loops)

What it shows: how Agents Monitor works (dots + numbers in the menu bar, click for one compact line per account and per pinned OpenRouter
key, click a row for its full card with limit bars and reset times, the OpenRouter row opens the More page with every key's spend) and why it
is worth installing (it warns you before a Claude Code / Codex limit runs out: desktop toast, notification, ntfy push).

Real code: `PopoverView`, `AccountRows` (compact rows), `OpenRouterViews` (OpenRouter row, key rows, `MorePage`), `ToastContent`, `UsageDot`,
`HistoryViews` and `ProviderBadge` from `AgentsMonitor/*.swift` compiled unchanged, together with the real `AgentsMonitorKit` (built as a static
module) — the same file set `Scripts/render-screenshots` compiles, including its `ProgressStandIn.swift` (the repo's own offscreen stand-in for
the AppKit progress bar). The popover is filled through the app's own `AppStore.shared` (accounts, states, expanded rows, OpenRouter keys and
snapshot). Status-item text comes from `AppStore.menuBarSegments` (joined like `MenuBarLabel.swift:19-22`; two Claude accounts share the tag
"c", so the app numbers the accounts 1, 2, 3), its dots from `UsageDot.composite`. The toast alert is produced by the real `AlertEngine`
(Codex session 74 % raises nothing, 80 % raises the warning: the real app grades Codex "warning" from 75 %), so its title and body
("Codex — Session" / "80% used") are the app's own; the card is `ToastContent`.
Fake data: accounts "Work" (Claude; Session 64 %, Week 41 %, Week · Fable 22 %), "Personal" (Claude; Week 93 %, a warning line) and "Codex"
(Session 74 %, Week 38 %), six OpenRouter keys ("prod-agent" and "research" pinned to the popover, the rest on the More page; two with caps),
a $42.17 balance, clock 9:41. Nothing reads a credential or the Keychain; the app is never launched, its views are only drawn into bitmaps.

| # | Scene | Start | Dur | What happens | Caption |
|---|-------|-------|-----|--------------|---------|
| 1 | menu bar | 0.0 | 2.0 | Menu bar only, clock 9:41. Status item: three usage dots + "1 64% · 2 93% · 3 74%". | Every account's usage sits in the menu bar |
| 2 | popover | 2.0 | 2.8 | Cursor glides to the item, click: item highlights, the real popover opens at once: Work, Personal (with its "Week 93 %" line) and Codex as one-line rows with meter chips, the OpenRouter row (balance, today, 6 keys) and the two pinned keys. | One line per account and OpenRouter key |
| 3 | expand | 4.8 | 2.6 | Cursor glides to the Codex row's chevron, click: the row becomes the full card (bars, pacing ticks, "resets in …") in place, the rows below move down. | Click a row for bars and reset times |
| 4 | more | 7.4 | 2.6 | Cursor glides to the OpenRouter row, click: the popover shows the More page (Back, balance line, six keys with today / week / month, two cap bars, the UTC note); the cursor fades out. | Every OpenRouter key's spend on the More page |
| 5 | toast | 10.0 | 2.8 | Cursor fades in, clicks the desktop: popover closes at once. The next poll sees Codex at 80 %: dot and number change ("3 80%", clock 9:46), the real toast slides in from the right (0.25 s, as `ToastPanel.show`) and stays. | Warns near the limit: toast, notification, phone push |

Transitions: 0.2 s crossfade between scenes; captions fade old 0–0.12 s / new 0.12–0.35 s (never two pills at once); the last 0.2 s
dissolves into scene 1's first frame (clean loop).
Cursor: system arrow (`NSCursor.arrow`), eased glides, click = dip + white ripple; visible only while it points at something.
Render: `./render.sh` (swiftc: real AgentsMonitorKit static lib, kit + scene + the app's real view files; 30 fps frames; encode). Byte-identical on
every run: the views' `Date()` calls ("resets in", the cap line) are pinned to the fixture anchor by a `Date.init()` shadow in `scene.swift`, and
the demo's caps have no reset period (that countdown runs to the next UTC midnight from the wall clock).

Approximated (not the app's own pixels): the popover sits in the kit's generic glass panel (16 pt corners, 6 pt under the bar) rather than a real
MenuBarExtra window; the More page is `MorePage` stacked on the Divider and footer cut from the main page's capture (`PopoverView` draws the same
VStack); the toast's `.regularMaterial` renders as flat dark gray offscreen; the status-item dots are drawn over a blank slot the kit reserves in
its menu bar. The card flip to graphs is no longer in the clip; `docs/screenshots/graphs.png` shows it.
