# Troubleshooting

Back to [[Home]]. See also: [[User-Guide]], [[Architecture]].

## Card states

| Card shows | Meaning | Fix |
|---|---|---|
| Waiting for first refresh… | No poll has completed yet for this account | Wait, or click Refresh |
| Not logged in | No matching keychain entry for this account's config dir | Log in to Claude Code for that profile, or remove the account |
| Keychain access denied | A read hit a real consent failure (rare — see [[Architecture#keychain-access]]); 30-minute negative cache | Usually clears on its own; check Keychain Access if it doesn't |
| Login token expired | Local Claude account, two consecutive 401s | Open a Claude Code session for that profile; `/login` only if that alone doesn't fix it |
| Login token expired (Codex) | Codex account, two consecutive 401s | Run `codex` in that profile to rewrite `auth.json`; `codex login` only if that alone doesn't fix it |
| Credentials expired (+ Paste credentials…) | Remote account's refresh grant failed, almost always the [[#rotation-race]] | Re-paste fresh credentials from the source machine |
| Rate limited until HH:MM | 429 from the usage endpoint; backoff 3→6→12→15 min, resets on success | Nothing to do — recovers on its own |
| Last refresh failed: … | Stale-but-displayed: last poll failed, previous good snapshot still shown | Check the error text; usually transient network |

## FAQ

### Why did I get a "login token expired" alert when Claude Code was working fine?

Two different things can cause this, and Agents Monitor already accounts for the common one:

A **single** 401 on a local account is usually Claude Code itself rotating that profile's access
token mid-poll — you were actively using Claude Code, it refreshed on its own schedule, and
Agents Monitor's in-flight request landed on the old token by a second or two. Agents Monitor
re-reads the keychain and retries once after a short delay, and even then the alert only fires
on the **second consecutive** failed poll. If you see a state flash to "needs reauth" in the
logs and then clear on its own without an alert, that's this debounce working correctly — not a
bug.

If the alert *does* fire, it means two polls in a row failed — that profile's token really is
stuck. Open a terminal, run `claude` (or any command) against that `CLAUDE_CONFIG_DIR`, and let
Claude Code refresh it normally.

### <a name="rotation-race"></a>What's the "rotation race" for remote accounts?

A remote account's credentials are a live OAuth lineage — same access/refresh token pair Claude
Code itself would use. Agents Monitor refreshes it when it expires and writes the *new* token
back into its own keychain item. That's fine as long as nothing else is refreshing the *same*
lineage.

If the source machine is still actively running Claude Code against that same profile, its
Claude Code will also refresh that lineage on its own schedule. OAuth refresh tokens are
single-use: whichever side refreshes first invalidates the refresh token the other side is
holding. If Agents Monitor loses that race, its next refresh attempt fails and the card falls
back to "Credentials expired — Paste credentials…". Re-pasting a fresh copy fixes it for as long
as the two sides don't race again.

**The fix that actually avoids this:** use remote accounts for profiles you're not concurrently
running Claude Code against on the source machine — a spare laptop, a CI service account, a
profile you check in on rather than use daily. For a machine you use constantly, prefer running
Agents Monitor *on* that machine as a local account instead, where the "never refresh a local
token" rule sidesteps the race entirely.

### Why does an account show "Rate limited", and is that a real API rate limit?

Yes — the usage endpoint returned HTTP 429 for that account's access token. This isn't your
Claude usage limits; it's Anthropic throttling the *usage-checking endpoint itself*, which is
undocumented and, per community-measured behavior, sensitive to request rate and to a missing
or wrong `User-Agent` header (Agents Monitor always sends the same
`claude-cli/…` UA Claude Code itself uses). Each account backs off independently: 3 → 6 → 12 →
15 minutes, holding at 15, resetting to the first rung the moment a poll succeeds. One
throttled account never stalls polling for the others, since the rate-limit bucket is per
access token.

If every account is permanently rate-limited, something else on this Mac (or another instance
of Agents Monitor, or a competing usage-tracker tool) is likely also hammering the same
endpoint with the same tokens.

### What does "Keychain access denied" actually mean, and why does it self-heal?

This app deliberately suppresses the keychain consent dialog (see
[[Architecture#keychain-access]]) and falls back to a silent, Apple-signed CLI read — so in
practice this state is rare. It shows up only if that fallback itself fails outright (for
example, a corrupted keychain item, or `/usr/bin/security` unavailable for some reason). Because
a real denial shouldn't be retried on every 3-minute poll, it's cached negatively for 30 minutes
before Agents Monitor tries that account again — which is why the card usually clears on its own
without anything being done. If it doesn't clear after 30 minutes, check Keychain Access.app for
a `Claude Code-credentials…` item with an unusual ACL.

### The weekly reset countdown looks wrong / keeps shifting by a few seconds.

Expected. `resets_at` for a weekly window is the server's own naive rolling-window estimate, and
it's recomputed (not stored) on every request — it jitters by a second or two between polls even
for what's logically the same window. Agents Monitor tolerates up to 120 seconds of that jitter
before treating it as an actual window roll, specifically so this doesn't cause spurious
re-alerts. Treat the countdown as approximate.
