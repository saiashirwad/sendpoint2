#!/bin/bash
set -euo pipefail

# Wipe the installed app and every first-run artifact so the next
# ./install.sh is a cold setup: permissions, notes, settings.

APP_NAME="Sendpoint"
BUNDLE_ID="app.sendpoint"
APP="/Applications/${APP_NAME}.app"
SUPPORT="${HOME}/Library/Application Support/${APP_NAME}"
CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/sendpoint"

remove() {
    local path="$1"
    if [ -e "$path" ] || [ -L "$path" ]; then
        echo "    $path"
        rm -rf "$path"
    fi
}

delete_defaults() {
    local domain="$1"
    if defaults read "$domain" >/dev/null 2>&1; then
        echo "    defaults ${domain}"
        defaults delete "$domain"
    fi
    remove "${HOME}/Library/Preferences/${domain}.plist"
    remove "${HOME}/Library/Preferences/${domain}.plist.lockfile"
}

echo "==> Quitting any running copy"
pkill -x "$APP_NAME" 2>/dev/null || true
for _ in $(seq 1 40); do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.1
done
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "    Existing copy did not quit; stopping it now"
    pkill -KILL -x "$APP_NAME"
fi

echo "==> Removing the installed app"
remove "$APP"

echo "==> Removing notes and settings"
remove "$SUPPORT"
remove "$CONFIG_DIR"
delete_defaults "$BUNDLE_ID"

echo "==> Resetting Accessibility and Microphone"
# Setup reads these; leaving a grant makes first-run look already finished.
tccutil reset All "$BUNDLE_ID" 2>/dev/null || {
    tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
    tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || true
}

echo "==> Removing caches"
remove "${HOME}/Library/Caches/${BUNDLE_ID}"
remove "${HOME}/Library/Saved Application State/${BUNDLE_ID}.savedState"

echo
echo "First-run state. Install with: ./install.sh"
echo "Sendpoint will ask for Accessibility and Microphone on first launch."
