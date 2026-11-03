# Screenshots

The images here are rendered offscreen with fake data by `Scripts/render-screenshots`. It writes
more images than the docs use (light variants, error and empty states), so render into a scratch
folder and copy the ones below:

```bash
swift run --package-path Scripts/render-screenshots render /tmp/am-screens
cp /tmp/am-screens/{popover,popover-more,graphs,settings-accounts,settings-openrouter,spend-rule,toasts}.png docs/screenshots/
```

- `popover.png`: the compact popover, four Claude accounts (one with an expired login), Codex, the
  OpenRouter row and two pinned keys.
- `popover-more.png`: the More page with the OpenRouter keys, the balance and an account placed there.
- `graphs.png`: every card expanded and turned over to its graphs.
- `settings-accounts.png`: Settings > Accounts with the **Show in** pop-up.
- `settings-openrouter.png`: Settings > OpenRouter with a management key, four keys and spend alerts.
- `spend-rule.png`: the Add Spend Alert sheet.
- `toasts.png`: three toast alerts.
