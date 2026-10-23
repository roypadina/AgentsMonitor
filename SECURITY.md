# Security Policy

## Reporting a Vulnerability

Agents Monitor runs un-sandboxed, reads the Claude Code and Codex credentials stored on your Mac
and calls their usage endpoints, so security reports are taken seriously.
Please **do not** open a public issue for security problems.

Instead, use GitHub's private vulnerability reporting
(**Security → Report a vulnerability** on this repository).

You'll get an acknowledgement within a few days. Once a fix is available it will be released
and the report disclosed, with credit unless you prefer otherwise.

## Scope

Relevant areas: reading the keychain items of other apps (via `/usr/bin/security`), storing
pasted remote credentials in the keychain, the usage-endpoint requests, and the optional
[ntfy](https://ntfy.sh) push. Tokens are never logged or written to disk by the app, and a
local account's OAuth token is never refreshed by it.
