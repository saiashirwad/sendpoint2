#!/bin/bash
# Build dist/Sendpoint-VERSION.dmg and its .sha256 from the current checkout.
#
#   scripts/package.sh 2.0.0
#
# With no Developer ID the app is ad-hoc signed and macOS asks users to approve it.
# To ship a notarized build, set all of:
#   DEVELOPER_ID_P12           base64 of a "Developer ID Application" certificate + key (.p12)
#   DEVELOPER_ID_P12_PASSWORD  the .p12's password
#   NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD (an app-specific password from appleid.apple.com)
# The GitHub workflows pass these from repository secrets of the same names.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/package.sh VERSION}"
APP="dist/Sendpoint.app"
DMG="dist/Sendpoint-${VERSION}.dmg"

NOTARIZE=false
if [ -n "${DEVELOPER_ID_P12:-}" ]; then
    # A throwaway keychain, so CI never touches a login keychain.
    TEMP="${RUNNER_TEMP:-$(mktemp -d)}"
    KEYCHAIN="$TEMP/signing.keychain-db"
    KEYCHAIN_PASSWORD=$(uuidgen)
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security set-keychain-settings -lut 21600 "$KEYCHAIN"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    echo "$DEVELOPER_ID_P12" | base64 --decode > "$TEMP/developer-id.p12"
    security import "$TEMP/developer-id.p12" -k "$KEYCHAIN" -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign
    rm "$TEMP/developer-id.p12"
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
    security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
    export CODESIGN_IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN" \
        | awk -F '"' '/Developer ID Application/ { print $2; exit }')
    NOTARIZE=true
else
    export CODESIGN_IDENTITY=-   # never ship this Mac's Apple Development certificate
fi

VERSION="$VERSION" ./build.sh release

if [ "$NOTARIZE" = true ]; then
    echo "==> Notarizing"
    ditto -c -k --keepParent "$APP" dist/notarize.zip
    xcrun notarytool submit dist/notarize.zip --wait \
        --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD"
    rm dist/notarize.zip
    xcrun stapler staple "$APP"
    spctl -a -t exec -vv "$APP"
fi

echo "==> Creating $DMG"
ROOT=$(mktemp -d)
ditto "$APP" "$ROOT/Sendpoint.app"
ln -s /Applications "$ROOT/Applications"
hdiutil create -volname Sendpoint -srcfolder "$ROOT" -ov -format UDZO "$DMG"
rm -rf "$ROOT"
(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "notarized=$NOTARIZE" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "Ready: $DMG"
