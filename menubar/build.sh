#!/bin/bash
# build.sh — compile the Keep Awake menu-bar app into a real .app bundle.
# Run from anywhere:  ./menubar/build.sh
# Requires: macOS + Xcode Command Line Tools (xcode-select --install)

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Keep Awake"
BUNDLE="$APP_NAME.app"
SWIFT_SRC="KeepAwake.swift"

echo "==> Checking for the Swift compiler..."
if ! command -v swiftc >/dev/null 2>&1; then
  echo "    swiftc not found. Installing Xcode Command Line Tools..."
  xcode-select --install || true
  echo "    Approve the dialog, wait for it to finish, then run this script again."
  exit 1
fi

echo "==> Building $BUNDLE ..."
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

swiftc -O -whole-module-optimization \
  -framework Cocoa -framework CoreGraphics -framework ServiceManagement -framework IOKit \
  -o "$BUNDLE/Contents/MacOS/KeepAwake" \
  "$SWIFT_SRC"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>        <string>KeepAwake</string>
  <key>CFBundleIdentifier</key>        <string>local.keepawake.menubar</string>
  <key>CFBundleShortVersionString</key><string>1.4.2</string>
  <key>CFBundleVersion</key>           <string>1.4.2</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>LSMinimumSystemVersion</key>    <string>11.0</string>
  <key>LSUIElement</key>               <true/>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSSupportsAppNap</key>          <false/>
  <key>NSHumanReadableCopyright</key>  <string>Personal use.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so Gatekeeper doesn't complain about an unsigned local binary.
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$BUNDLE" 2>/dev/null || true
fi

echo "==> Done."
echo
echo "    Start it now        : open \"$PWD/$BUNDLE\""
echo "    Install to /Apps    : ./install-app.sh"
echo
