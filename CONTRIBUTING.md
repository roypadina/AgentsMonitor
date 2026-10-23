# Contributing to Agents Monitor

Thanks for your interest! Bug reports, feature ideas, docs and code are all welcome.

## Ground rules

- **`main` is protected.** No direct pushes; changes land via Pull Request and are
  reviewed/merged by the maintainer ([@roypadina](https://github.com/roypadina)).
- Be respectful — see the [Code of Conduct](CODE_OF_CONDUCT.md).
- Keep changes focused. One logical change per PR, smallest diff that solves it.
- This repo is public: never commit tokens, real account names, ntfy topics or personal paths.

## Getting started

```bash
git clone https://github.com/roypadina/AgentsMonitor.git
cd AgentsMonitor
swift test --package-path AgentsMonitorKit      # logic tests
xcodebuild -workspace AgentsMonitor.xcworkspace -scheme AgentsMonitor \
  -configuration Release -derivedDataPath build build
open build/Build/Products/Release/AgentsMonitor.app
```

Requirements: **macOS 14+**, Xcode.

## Layout

- `AgentsMonitorKit` — Swift package: models, usage clients, alert engine, history, stores. All tested.
- `AgentsMonitor` — the SwiftUI menu-bar app (popover, settings, toasts, notifications).
- `Config` — xcconfig files and entitlements; the version lives in `Config/Shared.xcconfig`.
- `Scripts/render-screenshots` — dev-only renderer for the README screenshots (fake data).

## Workflow

1. **Fork** and branch: `git checkout -b feat/my-thing`.
2. Make your change; run the tests and try it in the built app.
3. Match the surrounding style; no drive-by refactors.
4. Open a **Pull Request** against `main`. CI must be green and the maintainer must approve.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org): `feat: ...`, `fix: ...`, `docs: ...`.

## Reporting bugs / requesting features

Use the [issue templates](https://github.com/roypadina/AgentsMonitor/issues/new/choose).
