#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

CONFIGURATION="${1:-release}"
APP="dist/Sendpoint.app"

swift build -c "$CONFIGURATION" --product Sendpoint
BIN_DIR=$(swift build -c "$CONFIGURATION" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Sendpoint" "$APP/Contents/MacOS/Sendpoint"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/Fonts"
cp Resources/Fonts/*.ttf "$APP/Contents/Resources/Fonts/"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD 2>/dev/null || echo 1)" "$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then   # set by scripts/package.sh; otherwise Resources/Info.plist's version stands
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi

# A stable identity keeps the Accessibility grant across rebuilds; ad-hoc loses it.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F '"' '/Developer ID Application|Apple Development/ { print $2; exit }')}"
# Notarization needs Apple's secure timestamp; every other build skips the network round trip.
TIMESTAMP=--timestamp=none
[[ "${IDENTITY:-}" == "Developer ID Application"* ]] && TIMESTAMP=--timestamp
codesign --force --options runtime "$TIMESTAMP" \
    --entitlements Resources/Sendpoint.entitlements --sign "${IDENTITY:--}" "$APP"
scripts/check-app.sh "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"
