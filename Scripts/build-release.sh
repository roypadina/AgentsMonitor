#!/bin/sh
# Universal release build + zip: build/AgentsMonitor.zip, plus build/appcast.xml (Sparkle feed)
# when the maintainer's Sparkle EdDSA key is in the login keychain. Upload both to the release.
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
  # Inside-out: nested bundles and Sparkle's Autoupdate tool before the app itself.
  find "$APP/Contents" -depth \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.dylib' \
    -o \( -name Autoupdate -type f \) \) \
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

# Sparkle feed for this release only (served as the latest release's appcast.xml asset).
SPARKLE=build/SourcePackages/artifacts/sparkle/Sparkle/bin
if "$SPARKLE/generate_keys" -p >/dev/null 2>&1; then
  VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
  D=$(mktemp -d)
  cp build/AgentsMonitor.zip "$D/"
  # This version's CHANGELOG section becomes the update prompt's release notes.
  awk -v v="## [$VER]" 'index($0, v) == 1 {f=1; next} /^## \[/ {f=0} f' CHANGELOG.md > "$D/AgentsMonitor.md"
  "$SPARKLE/generate_appcast" --embed-release-notes \
    --download-url-prefix "https://github.com/roypadina/AgentsMonitor/releases/download/v$VER/" \
    -o build/appcast.xml "$D"
  rm -rf "$D"
  echo build/appcast.xml
else
  echo "Sparkle signing key not in the keychain: no appcast.xml"
fi
