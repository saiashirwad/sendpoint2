#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-dist/Sendpoint.app}"
PLIST="$APP/Contents/Info.plist"

fail() {
    echo "App verification failed: $*" >&2
    exit 1
}

expect_plist() {
    local actual
    actual=$(/usr/libexec/PlistBuddy -c "Print :$1" "$PLIST")
    [ "$actual" = "$2" ] || fail "$1: expected '$2', got '$actual'"
}

plutil -lint "$PLIST"
expect_plist CFBundleIdentifier app.sendpoint
expect_plist CFBundleExecutable Sendpoint
expect_plist CFBundlePackageType APPL
expect_plist LSMinimumSystemVersion 26.0
expect_plist LSUIElement true
expect_plist ATSApplicationFontsPath Fonts
for key in CFBundleVersion CFBundleShortVersionString NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription; do
    value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$PLIST")
    [ -n "$value" ] || fail "$key is empty"
done

BIN="$APP/Contents/MacOS/Sendpoint"
[ -x "$BIN" ] || fail "missing executable: $BIN"
file "$BIN" | grep -q 'Mach-O.*executable' || fail "not a Mach-O executable: $BIN"
cmp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for font in Resources/Fonts/*.ttf; do
    cmp "$font" "$APP/Contents/Resources/Fonts/${font##*/}"
done

codesign --verify --deep --strict --verbose=2 "$APP"
ENTITLEMENTS=$(mktemp)
trap 'rm -f "$ENTITLEMENTS"' EXIT
codesign --display --entitlements :- "$APP" > "$ENTITLEMENTS" 2>/dev/null
[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$ENTITLEMENTS")" = true ] \
    || fail "missing audio-input entitlement"
echo "Verified $APP (bundle only; no launch or permission checks)"
