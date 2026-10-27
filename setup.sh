#!/bin/bash
# setup.sh — one-shot setup for the Python (terminal) version.
#
#   ./setup.sh              install deps, run a self-test, print next steps
#   ./setup.sh --autostart  also install a LaunchAgent so it starts at login
#   ./setup.sh --remove     remove the LaunchAgent
#
set -euo pipefail
cd "$(dirname "$0")"

SCRIPT_DIR="$(pwd)"
PLIST_SRC="$SCRIPT_DIR/launchagent/com.local.keepawake.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.local.keepawake.plist"
LABEL="com.local.keepawake"

# --------------------------------------------------------------------------
# Locate a Python 3 that can talk to CoreGraphics
# --------------------------------------------------------------------------
find_python() {
  for cand in python3 /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    if command -v "$cand" >/dev/null 2>&1; then
      if "$cand" -c "import Quartz" >/dev/null 2>&1; then
        echo "$cand"; return 0
      fi
    fi
  done
  return 1
}

remove_agent() {
  if [ -f "$PLIST_DST" ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null \
      || launchctl unload "$PLIST_DST" 2>/dev/null || true
    rm -f "$PLIST_DST"
    echo "Removed the auto-start agent."
  else
    echo "No auto-start agent installed."
  fi
}

case "${1:-}" in
  --remove|-r) remove_agent; exit 0 ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer is for macOS only."; exit 1
fi

echo "=============================================================="
echo " KEEP AWAKE — setup"
echo "=============================================================="

echo "==> Looking for Python 3 with PyObjC/Quartz..."
if PY="$(find_python)"; then
  PY_PATH="$(command -v "$PY")"
  echo "    OK: $PY_PATH"
else
  echo "    Not found — installing pyobjc-framework-Quartz..."
  PY_PATH="$(command -v python3 || echo /usr/bin/python3)"
  "$PY_PATH" -m pip install --user --quiet pyobjc-framework-Quartz \
    || "$PY_PATH" -m pip install --quiet --break-system-packages pyobjc-framework-Quartz \
    || { echo "    pip install failed. Try:  brew install pyobjc"; exit 1; }
  "$PY_PATH" -c "import Quartz" || { echo "    Still can't import Quartz."; exit 1; }
  echo "    OK: $PY_PATH (installed just now)"
fi

chmod +x "$SCRIPT_DIR/keep_awake.py"

echo "==> Self-test: one nudge..."
"$PY_PATH" "$SCRIPT_DIR/keep_awake.py" --once --mode wiggle --distance 12
echo

if [[ "${1:-}" == "--autostart" ]]; then
  echo "==> Installing LaunchAgent (starts at every login)..."
  mkdir -p "$HOME/Library/LaunchAgents"
  sed -e "s|__PYTHON__|$PY_PATH|g" \
      -e "s|__SCRIPT__|$SCRIPT_DIR/keep_awake.py|g" \
      -e "s|__LOGDIR__|$HOME/Library/Logs|g" \
      "$PLIST_SRC" > "$PLIST_DST"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST_DST" 2>/dev/null \
    || launchctl load "$PLIST_DST"
  echo "    Installed. Log file: $HOME/Library/Logs/keep_awake.log"
  echo
fi

cat <<EOF
--------------------------------------------------------------
 READY. Pick how you want to run it:

 1) Quick manual run (stops with Ctrl+C):
      $PY_PATH "$SCRIPT_DIR/keep_awake.py"

 2) Run it in the background right now:
      nohup $PY_PATH "$SCRIPT_DIR/keep_awake.py" --quiet \\
        > ~/Library/Logs/keep_awake.log 2>&1 &

 3) Start automatically at every login:
      ./setup.sh --autostart
    (remove it later with:  ./setup.sh --remove)

 4) Prefer a menu-bar icon with on/off switch? Build the app:
      ./menubar/build.sh && ./menubar/install-app.sh
--------------------------------------------------------------
EOF
