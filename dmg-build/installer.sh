#!/bin/bash
#
# Keep Awake installer — this is the executable inside "Install Keep Awake.app"
# on the DMG. Double-click that app and this runs.
#
# Strategy, in order:
#   1. If swiftc is available  -> build the native menu-bar app, install to /Applications.
#   2. Otherwise               -> offer to install Xcode Command Line Tools, or
#                                 fall back to the Python agent + LaunchAgent.
#
# Everything is user-level: no sudo, no root, nothing outside
# /Applications, ~/Applications, ~/Library/LaunchAgents and ~/Library/Logs.

set -uo pipefail

# --- locate our own resources -------------------------------------------------
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
CONTENTS="$(cd "$(dirname "$SELF")/.." && pwd)"          # .../Contents
APP="$(cd "$CONTENTS/.." && pwd)"                        # .../Install Keep Awake.app
RES="$CONTENTS/Resources"

# If launched from the read-only DMG, copy the payload somewhere writable first.
WORK="$HOME/Library/Application Support/KeepAwake/payload"
if [ -d "$RES" ]; then
  mkdir -p "$WORK"
  cp -R "$RES/." "$WORK/" 2>/dev/null || true
  chmod -R u+w "$WORK" 2>/dev/null || true
fi
[ -d "$WORK/menubar" ] && RES="$WORK"

SWIFT_SRC="$RES/menubar/KeepAwake.swift"
PY_SRC="$RES/keep_awake.py"
PLIST_SRC="$RES/launchagent/com.local.keepawake.plist"
LOGDIR="$HOME/Library/Logs"
LOGFILE="$LOGDIR/keep_awake.log"
LABEL="com.local.keepawake"
UID_N="$(id -u)"

mkdir -p "$LOGDIR"

say()  { printf '%s\n' "$*"; }
hr()   { printf '%s\n' "--------------------------------------------------------------"; }

alert() {  # alert "title" "message"
  osascript - "$1" "$2" <<'AS' 2>/dev/null
on run argv
  display alert (item 1 of argv) message (item 2 of argv) as informational
  giving up after 300
end run
AS
}

dialog_choice() {  # dialog_choice "title" "text" "btn1" "btn2" -> prints button
  osascript - "$1" "$2" "$3" "$4" <<'AS' 2>/dev/null
on run argv
  set r to display dialog (item 2 of argv) with title (item 1 of argv) ¬
    buttons {(item 3 of argv), (item 4 of argv)} default button (item 4 of argv) ¬
    with icon note giving up after 300
  button returned of r
end run
AS
}

# --- sanity -------------------------------------------------------------------
if [ "$(uname -s)" != "Darwin" ]; then
  echo "This installer only runs on macOS."; exit 1
fi

exec > >(tee -a "$LOGDIR/KeepAwake-install.log") 2>&1
say ""
say "=============================================================="
say " KEEP AWAKE — installer"
say " $(date '+%Y-%m-%d %H:%M:%S')"
say "=============================================================="
say "Payload : $RES"
say "Log     : $LOGDIR/KeepAwake-install.log"

# --- pick an install target ---------------------------------------------------
if [ -w /Applications ]; then APPDIR="/Applications"; else APPDIR="$HOME/Applications"; mkdir -p "$APPDIR"; fi
say "Target  : $APPDIR"

have_swiftc() { command -v swiftc >/dev/null 2>&1 && swiftc --version >/dev/null 2>&1; }
have_xcode_clt() { xcode-select -p >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# PATH A — native menu-bar app
# ---------------------------------------------------------------------------
build_native() {
  local BUNDLE="$APPDIR/Keep Awake.app"
  say ""
  say "==> Building the native menu-bar app with swiftc ..."
  if [ ! -f "$SWIFT_SRC" ]; then say "    ERROR: $SWIFT_SRC missing"; return 1; fi

  local STAGE="$HOME/Library/Application Support/KeepAwake/staging/Keep Awake.app"
  rm -rf "$(dirname "$STAGE")"; mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

  if ! swiftc -O -whole-module-optimization \
        -framework Cocoa -framework CoreGraphics -framework ServiceManagement \
        -o "$STAGE/Contents/MacOS/KeepAwake" "$SWIFT_SRC" ; then
    say "    swiftc failed."; return 1
  fi

  cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>               <string>Keep Awake</string>
  <key>CFBundleDisplayName</key>        <string>Keep Awake</string>
  <key>CFBundleExecutable</key>         <string>KeepAwake</string>
  <key>CFBundleIdentifier</key>         <string>local.keepawake.menubar</string>
  <key>CFBundleShortVersionString</key> <string>1.0</string>
  <key>CFBundleVersion</key>            <string>1</string>
  <key>CFBundlePackageType</key>        <string>APPL</string>
  <key>CFBundleIconFile</key>           <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>     <string>11.0</string>
  <key>LSUIElement</key>                <true/>
  <key>NSHighResolutionCapable</key>    <true/>
</dict>
</plist>
PLIST

  [ -f "$RES/AppIcon.icns" ] && cp "$RES/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"

  rm -rf "$BUNDLE"
  cp -R "$STAGE" "$BUNDLE" || { say "    copy to $BUNDLE failed."; return 1; }
  xattr -dr com.apple.quarantine "$BUNDLE" 2>/dev/null || true
  codesign --force --deep --sign - "$BUNDLE" 2>/dev/null || true
  say "    Built: $BUNDLE"
  return 0
}

launch_native() {
  open "$APPDIR/Keep Awake.app" && say "==> Launched. Look for the coffee cup in your menu bar."
}

# ---------------------------------------------------------------------------
# PATH B — Python agent + LaunchAgent (no compiler needed)
# ---------------------------------------------------------------------------
find_python() {
  local c
  for c in /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 "$(command -v python3 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && "$c" -c "import Quartz" >/dev/null 2>&1 && { echo "$c"; return 0; }
  done
  return 1
}

install_python_agent() {
  say ""
  say "==> Installing the Python agent (no compiler needed) ..."
  if [ ! -f "$PY_SRC" ]; then say "    ERROR: $PY_SRC missing"; return 1; fi

  local DEST="$HOME/Library/Application Support/KeepAwake"
  mkdir -p "$DEST"
  cp "$PY_SRC" "$DEST/keep_awake.py"
  chmod +x "$DEST/keep_awake.py"

  local PY; PY="$(find_python)"
  if [ -z "$PY" ]; then
    say "    No Python with PyObjC found. Trying pip install ..."
    PY="$(command -v python3 || echo /usr/bin/python3)"
    "$PY" -m pip install --user --quiet pyobjc-framework-Quartz 2>/dev/null \
      || "$PY" -m pip install --quiet --break-system-packages pyobjc-framework-Quartz 2>/dev/null
    "$PY" -c "import Quartz" >/dev/null 2>&1 || { say "    Could not get Quartz bindings."; return 1; }
  fi
  say "    Python: $PY"

  mkdir -p "$HOME/Library/LaunchAgents"
  local DST="$HOME/Library/LaunchAgents/$LABEL.plist"
  sed -e "s|__PYTHON__|$PY|g" \
      -e "s|__SCRIPT__|$DEST/keep_awake.py|g" \
      -e "s|__LOGDIR__|$LOGDIR|g" \
      "$PLIST_SRC" > "$DST"

  launchctl bootout "gui/$UID_N/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_N" "$DST" 2>/dev/null || launchctl load "$DST" 2>/dev/null || true

  sleep 1
  if launchctl print "gui/$UID_N/$LABEL" >/dev/null 2>&1; then
    say "    Running as LaunchAgent: $LABEL"
    say "    Log: $LOGFILE"
  else
    say "    WARNING: agent did not register. Start manually with:"
    say "      nohup \"$PY\" \"$DEST/keep_awake.py\" --quiet > \"$LOGFILE\" 2>&1 &"
  fi

  # Convenience: a terminal command the user can run too.
  cat > "$DEST/keep-awake" <<CMD
#!/bin/bash
exec "$PY" "$DEST/keep_awake.py" "\$@"
CMD
  chmod +x "$DEST/keep-awake"
  say "    Command-line helper: \"$DEST/keep-awake\" --help"
  return 0
}

# ---------------------------------------------------------------------------
# main flow
# ---------------------------------------------------------------------------
MODE=""
if have_swiftc; then
  MODE="native"
elif have_xcode_clt; then
  MODE="native"     # CLT present; swiftc should resolve, try anyway
fi

if [ "$MODE" = "native" ]; then
  if build_native; then
    launch_native
    alert "Keep Awake installed" \
"A coffee-cup icon is now in your menu bar.

Click it to pause/resume, change the interval, or pick a movement style.
It only nudges while you are idle, so it will not fight your mouse.

Tick \"Start at login\" in that menu to keep it across reboots."
    say ""; say "==> DONE (native menu-bar app)"; exit 0
  fi
  say "    Native build failed — falling back."
fi

# No working compiler: offer to install the Command Line Tools, else Python route.
if ! have_swiftc; then
  CHOICE="$(dialog_choice "Keep Awake — setup" \
"The menu-bar version needs Apple's free developer tools (about a 5 minute download).

Install them now, or use the background version that works immediately with no download?" \
"Use background version" "Install tools now")"
  say "User chose: ${CHOICE:-<none>}"

  if [ "$CHOICE" = "Install tools now" ]; then
    say "==> Triggering: xcode-select --install"
    xcode-select --install 2>/dev/null || true
    alert "Apple is installing the Command Line Tools" \
"Approve the Apple dialog and wait for it to finish (a few minutes).

When it is done, double-click \"Install Keep Awake\" again and you will get the menu-bar version.

Meanwhile the background version has been installed so you are covered right now."
  fi
fi

if install_python_agent; then
  alert "Keep Awake is running in the background" \
"Your cursor will now be nudged every 30 seconds whenever you are idle, so you will not show as AFK.

It starts automatically at every login.
Log: ~/Library/Logs/keep_awake.log

To stop it:  launchctl bootout gui/$(id -u)/com.local.keepawake
To remove:   delete ~/Library/LaunchAgents/com.local.keepawake.plist"
  say ""; say "==> DONE (background agent)"; exit 0
fi

alert "Keep Awake could not be installed" \
"Neither the Swift build nor the Python agent succeeded.

Details are in ~/Library/Logs/KeepAwake-install.log"
say ""; say "==> FAILED"; exit 1
