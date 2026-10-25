#!/bin/bash
# build_dmg.sh — assemble the "Keep Awake" installer volume and wrap it in a
# real UDZO .dmg (UDIF container), all on Linux.
set -euo pipefail
cd "$(dirname "$0")"

SRC=..                     # the app sources
STAGE=stage/"Keep Awake"     # staging root = volume root
OUT="${1:-../Keep-Awake-1.0.dmg}"
DMGTOOL="${DMGTOOL:-/tmp/dmgtool}"

rm -rf stage
mkdir -p "$STAGE/Install Keep Awake.app/Contents/MacOS" \
         "$STAGE/Install Keep Awake.app/Contents/Resources/menubar" \
         "$STAGE/Install Keep Awake.app/Contents/Resources/launchagent" \
         "$STAGE/Extras"

APP="$STAGE/Install Keep Awake.app"

# ---- payload ---------------------------------------------------------------
cp "$SRC/keep_awake.py"                              "$APP/Contents/Resources/"
cp "$SRC/menubar/KeepAwake.swift"                    "$APP/Contents/Resources/menubar/"
cp "$SRC/launchagent/com.local.keepawake.plist"      "$APP/Contents/Resources/launchagent/"
cp icon/AppIcon.icns                                 "$APP/Contents/Resources/"
cp installer.sh                                      "$APP/Contents/MacOS/installer"
chmod 755                                            "$APP/Contents/MacOS/installer"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>               <string>Install Keep Awake</string>
  <key>CFBundleDisplayName</key>        <string>Install Keep Awake</string>
  <key>CFBundleExecutable</key>         <string>installer</string>
  <key>CFBundleIdentifier</key>         <string>local.keepawake.installer</string>
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

# ---- double-click fallback that runs through Terminal -----------------------
cat > "$STAGE/Extras/install.command" <<'CMD'
#!/bin/bash
# Runs the installer through Terminal — bypasses Gatekeeper entirely.
D="/Volumes/Keep Awake/Install Keep Awake.app/Contents/MacOS/installer"
[ -f "$D" ] || D="$(cd "$(dirname "$0")/../Install Keep Awake.app/Contents/MacOS" 2>/dev/null && pwd)/installer"
[ -x "$D" ] || chmod +x "$D" 2>/dev/null || true
exec bash "$D"
CMD
chmod 755 "$STAGE/Extras/install.command"

# ---- uninstaller ------------------------------------------------------------
cat > "$STAGE/Extras/uninstall.sh" <<'UN'
#!/bin/bash
# Removes every trace of Keep Awake. Safe to run twice.
set -uo pipefail
echo "==> Stopping running copies..."
pkill -f keep_awake.py 2>/dev/null
pkill -f "Keep Awake.app" 2>/dev/null
launchctl bootout "gui/$(id -u)/com.local.keepawake" 2>/dev/null \
  || launchctl unload "$HOME/Library/LaunchAgents/com.local.keepawake.plist" 2>/dev/null
rm -f  "$HOME/Library/LaunchAgents/com.local.keepawake.plist"
rm -rf "/Applications/Keep Awake.app" "$HOME/Applications/Keep Awake.app"
rm -rf "$HOME/Library/Application Support/KeepAwake"
rm -f  "$HOME/Library/Logs/keep_awake.log" "$HOME/Library/Logs/KeepAwake-install.log"
echo "==> Keep Awake removed."
UN
chmod 755 "$STAGE/Extras/uninstall.sh"

# ---- start-here note ---------------------------------------------------------
cat > "$STAGE/README - Start Here.txt" <<'TXT'
KEEP AWAKE — anti-AFK cursor nudger for macOS
=============================================

WHAT THIS DOES
  Moves your cursor a pixel or two every 30 seconds (only while you are
  idle), so macOS, Teams, Slack, Zoom and monitoring agents never mark
  you AFK and your screen never sleeps.

INSTALL — pick any one:

  1. Double-click "Install Keep Awake".
     A dialog walks you through it. With Apple's free Command Line Tools
     present you get a coffee-cup icon in the menu bar; without them the
     installer silently falls back to a background agent and offers to
     install the tools for the menu-bar version later.

  2. If macOS says the app "cannot be opened" (Gatekeeper, because this
     dmg is not App-Store signed):
        right-click "Install Keep Awake" -> Open -> Open
     or double-click Extras/install.command
     or, bulletproof, in Terminal:
        bash "/Volumes/Keep Awake/Install Keep Awake.app/Contents/MacOS/installer"

  3. Terminal-only crowd: the whole tool also lives inside the installer
     bundle. Copy it out and run it directly:
        cp -R "/Volumes/Keep Awake/Install Keep Awake.app/Contents/Resources/keep_awake.py" ~/
        python3 ~/keep_awake.py --help

AFTER INSTALL
  Menu-bar version : click the cup icon for pause / interval / movement style.
  Background version: log at ~/Library/Logs/keep_awake.log,
        stop:  launchctl bootout gui/$(id -u)/com.local.keepawake

UNINSTALL
  Double-click Extras/uninstall.sh, or run it from Terminal:
        bash "/Volumes/Keep Awake/Extras/uninstall.sh"

NOTES
  - No sudo, no kernel extension, no Accessibility permission needed.
  - Nothing leaves your Mac. The installer compiles/builds locally.
  - Source of truth for all options: keep_awake.py --help
TXT

# ---- ISO9660 + Rock Ridge (preserves exec bits & long names) ----------------
genisoimage -V "Keep Awake" -R -J -rational-rock -quiet -o stage.iso "stage/Keep Awake"
echo "--- iso contents (Rock Ridge view) ---"
isoinfo -lR -i stage.iso | awk '{print $1, $NF}' | grep -v '^ *$' | head -30

# ---- wrap into a UDIF (UDZO) dmg ---------------------------------------------
"$DMGTOOL" dmg stage.iso "$OUT"

# ---- post-fix: libdmg leaves koly.fUDIFSectorCount at 0 for partition-less
#      inputs; hdiutil wants the real 512-byte sector count there.
python3 - "$OUT" "$(stat -c %s stage.iso)" <<'PYFIX'
import struct, sys
p = sys.argv[1]; iso = int(sys.argv[2]); sect = iso // 512
d = bytearray(open(p, 'rb').read())
k = len(d) - 512 + 0x1EC
assert d[-512:-508] == b'koly'
d[k:k+8] = struct.pack('>Q', sect)
open(p, 'wb').write(bytes(d))
print(f"patched koly.fUDIFSectorCount -> {sect}")
PYFIX
ls -la "$OUT"
echo "--- UDIF trailer check ---"
python3 - "$OUT" <<'PY'
import struct, sys, plistlib
p = sys.argv[1]
data = open(p, 'rb').read()
tail = data[-512:]
assert tail[:4] == b'koly', "no koly trailer!"
ver, hsz = struct.unpack('>II', tail[4:12])
xml_off, xml_len = struct.unpack('>QQ', tail[0xD8:0xE8])
sect = struct.unpack('>Q', tail[0x1EC:0x1F4])[0]
print(f"koly v{ver} header={hsz} xml@{xml_off}+{xml_len} sectors={sect}")
pl = plistlib.loads(data[xml_off:xml_off+xml_len])
for b in pl.get('blkx', []):
    print(f"  blkx: {b.get('ID-Name','?'):24s} cfork={b['CFName']!s:20s} "
          f"comp={b['DataLength']} blocks={b['SectorCount']}")
print("format:", pl.get('Info-Backed-Format') or pl.get('UDIF-Info', {}).get('format', '?'))
print("UDIF OK — this is a genuine Apple Disk Image container.")
PY
