# Agents Monitor demo — storyboard (12.8 s, loops)

What it shows: how Agents Monitor works (dots + numbers in the menu bar, click for limit bars and reset times, flip a card for its usage
graph) and why it is worth installing (it warns you before a Claude Code / Codex limit runs out: desktop toast, notification, ntfy push).

Real code: `PopoverView`, `ToastContent`, `UsageDot`, `HistoryViews` (card flip faces, graph rows) and `ProviderBadge` from `AgentsMonitor/*.swift`
compiled unchanged, together with the real `AgentsMonitorKit` (built as a static module) — the same file set `Scripts/render-screenshots` compiles,
including its `ProgressStandIn.swift` (the repo's own offscreen stand-in for the AppKit progress bar). The popover is filled through the app's own
`AppStore.shared` (accounts, states, history). Status-item text comes from `AppStore.menuBarSegments` (joined like `MenuBarLabel.swift:19-22`), its
dots from `UsageDot.composite`. The toast alert is produced by the real `AlertEngine` (Codex session 74 % raises nothing, 80 % raises the warning: the real app grades Codex "warning" from 75 %), so its title and body ("Codex — Session" / "80% used") are the app's own; the card is `ToastContent`.
Fake data: accounts "Work" (Claude; Session 64 %, Week 41 %, Week · Fable 22 %) and "Codex" (Session 74 %, Week 38 %), clock 9:41, two days of
generated usage history (a made-up saw-tooth, not anyone's usage). Nothing reads a credential or the Keychain; the app is never launched, its views
are only drawn into bitmaps.

| # | Scene | Start | Dur | What happens | Caption |
|---|-------|-------|-----|--------------|---------|
| 1 | menu bar | 0.0 | 2.4 | Menu bar only, clock 9:41. Status item: two usage dots (yellow-orange, orange) + "c 64% · x 74%". | Every account's usage sits in the menu bar |
| 2 | popover | 2.4 | 3.2 | Cursor glides to the item, click: item highlights, the real popover opens at once: Work and Codex cards with bars, pacing ticks, "resets in …", "full in ~2h 24m at this pace", footer buttons. | Click for limit bars and reset times |
| 3 | graph | 5.6 | 3.6 | Cursor glides to the chart button on the Codex card, click: the card turns over (0.45 s, the app's own turn) to its 24 h graphs (Session saw-tooth, Week curve, "24h" chip). | Flip a card for its usage graph |
| 4 | toast | 9.2 | 3.6 | Click on the desktop: popover closes at once. The next poll sees Codex at 80 %: dot and number change ("x 80%", clock 9:46), the real toast slides in from the right (0.25 s, as `ToastPanel.show`) and stays. | Warns near the limit: toast, notification, phone push |

Transitions: 0.2 s crossfade between scenes; captions fade old 0–0.12 s / new 0.12–0.35 s (never two pills at once); the last 0.2 s
dissolves into scene 1's first frame (clean loop).
Cursor: system arrow (`NSCursor.arrow`), eased glides, click = dip + white ripple; visible only while it points at something.
Render: `./render.sh` (swiftc: real AgentsMonitorKit static lib, kit + scene + the app's real view files; 30 fps frames; encode). Byte-identical on
every run: the app's three `Date()` calls (graph axis, graph span, "resets in") are pinned to the fixture anchor by a `Date.init()` shadow in
`scene.swift`, so the chart's anti-aliasing cannot move with the wall clock.

Approximated (not the app's own pixels): the card turn is a perspective warp of the card's two real faces (0° and 180° are the app's own frames);
the popover sits in the kit's generic glass panel (16 pt corners, 6 pt under the bar) rather than a real MenuBarExtra window; the toast's
`.regularMaterial` renders as flat dark gray offscreen; the status-item dots are drawn over a blank slot the kit reserves in its menu bar.
