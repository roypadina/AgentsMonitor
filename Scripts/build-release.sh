#!/bin/sh
# Universal release build + zip: build/AgentsMonitor.zip.
# Signed with the maintainer's stable "KeyLayoutSwitcher Dev" identity when it is in the keychain
# (so macOS permission grants survive updates); override with AGENTSMONITOR_SIGN_IDENTITY.
# Otherwise (CI, contributors) the build stays ad-hoc signed.
set -e
cd "$(dirname "$0")/.."
xcodebuild -workspace AgentsMonitor.xcworkspace -scheme AgentsMonitor -configuration Release \
  -derivedDataPath build ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build
APP=build/Build/Products/Release/AgentsMonitor.app
ID="${AGENTSMONITOR_SIGN_IDENTITY:-}"
if [ -z "$ID" ] && security find-identity -v -p codesigning | grep -q "KeyLayoutSwitcher Dev"; then
  ID="KeyLayoutSwitcher Dev"
fi
if [ -n "$ID" ]; then
  ENT=$(mktemp)
  codesign -d --entitlements :- "$APP" > "$ENT" 2>/dev/null
  # Inside-out: any nested bundle or Mach-O (none today) before the app itself.
  find "$APP/Contents" -depth \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.dylib' \) \
    -not -path "$APP" | while read -r f; do
    codesign --force --options runtime --preserve-metadata=identifier,entitlements,flags -s "$ID" "$f"
  done
  codesign --force --options runtime --entitlements "$ENT" -s "$ID" "$APP"
  rm -f "$ENT"
  codesign --verify --deep --strict "$APP"
  echo "Signed with: $ID"
else
  echo "Stable signing identity not found: leaving the build ad-hoc signed"
fi
rm -f build/AgentsMonitor.zip
ditto -c -k --keepParent "$APP" build/AgentsMonitor.zip
echo build/AgentsMonitor.zip
