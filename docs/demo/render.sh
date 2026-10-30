#!/bin/bash
# Regenerates the Agents Monitor demo from scratch: build the real AgentsMonitorKit, compile the app's real view files + kit + scene, render
# frames offscreen (no window is ever shown, nothing is clicked or captured, no credential or Keychain is read, the installed app is never
# launched), encode. One command: ./render.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="${KIT:-$HERE}"; [ -f "$KIT/DemoKit.swift" ] || KIT="$HERE/../kit"          # repo: kit is vendored next to this file
APP="${APP_SRC:-$HERE/../..}"                                                   # repo: docs/demo -> repo root
GIF="${GIF:-$HERE/../demo.gif}"                                                 # repo: docs/demo.gif
BUILD="${BUILD:-${TMPDIR:-/tmp}/agents-monitor-demo}"                           # never inside the repo (hundreds of MB of frames)
mkdir -p "$BUILD"
# The app's logic lives in the AgentsMonitorKit package; the view files `import AgentsMonitorKit`, so build it as a static module.
swiftc -swift-version 5 -O -emit-library -static -module-name AgentsMonitorKit -emit-module -emit-module-path "$BUILD/AgentsMonitorKit.swiftmodule" -suppress-warnings \
  -o "$BUILD/libAgentsMonitorKit.a" "$APP"/AgentsMonitorKit/Sources/AgentsMonitorKit/*.swift
# The same view files Scripts/render-screenshots compiles (+ its offscreen stand-in for the AppKit progress bar).
V="$APP/AgentsMonitor"
swiftc -swift-version 5 -parse-as-library -O -suppress-warnings -I "$BUILD" -L "$BUILD" -lAgentsMonitorKit -o "$BUILD/demo" \
  "$KIT/DemoKit.swift" "$HERE/scene.swift" \
  "$V/HistoryViews.swift" "$V/MenuBarLabel.swift" "$V/Notifier.swift" "$V/PopoverView.swift" "$V/ProviderBadge.swift" \
  "$V/SettingsView.swift" "$V/SettingsWindow.swift" "$V/ToastPanel.swift" "$V/WelcomeWindow.swift" \
  "$APP/Scripts/render-screenshots/Sources/render/ProgressStandIn.swift"
rm -rf "$BUILD/frames"
"$BUILD/demo" "$BUILD/frames" 30 -AppleLocale en_US -AppleLanguages "(en)"      # en_US: "9:41 AM"-style times
POSTER=${POSTER:-130}  # popover open with both cards (shows the app, never the empty desktop)
"$KIT/encode.sh" "$BUILD/frames" "$GIF" "${MP4:-}" "${WEBP:-}" "${POSTER:-}"
rm -rf "$BUILD/frames"                                                            # only after a successful encode (set -e)
