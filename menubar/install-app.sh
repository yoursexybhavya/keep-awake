#!/bin/bash
# install-app.sh — put "Keep Awake.app" in /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE="Keep Awake.app"

if [ ! -d "$BUNDLE" ]; then
  echo "==> $BUNDLE not built yet — building first..."
  ./build.sh
fi

DEST="/Applications/$BUNDLE"
echo "==> Stopping running instance..."
pkill -x KeepAwake 2>/dev/null || true
sleep 0.5

echo "==> Installing to $DEST"
rm -rf "$DEST"
cp -R "$BUNDLE" "$DEST"

# Strip the "downloaded from the internet" flag so it opens without a warning.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "==> Launching..."
open "$DEST"

echo
echo "Done. Look for the coffee-cup icon in your menu bar."
echo "Tip: tick 'Start at login' inside the menu so it survives reboots."
