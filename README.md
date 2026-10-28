# ☕ Keep Awake — anti-AFK cursor nudger for macOS

Your Mac marks you **AFK / Away** as soon as the mouse stops moving, and so do
Teams, Slack, Zoom and most corporate presence or monitoring agents. They all
read the same thing: *"how many seconds since the last mouse or keyboard
event?"*

This tool answers that question by nudging the cursor a few pixels on a timer,
so the idle counter never grows. You stay "Available" without touching the
mouse.

Two versions are included — pick one:

| | **Python / terminal** | **Menu-bar app (Swift)** |
|---|---|---|
| Files | `keep_awake.py` | `menubar/KeepAwake.swift` |
| Install | nothing to compile | compiles in ~10 s with `swiftc` |
| Control | command-line flags | click the ☕ icon |
| Start at login | LaunchAgent | "Start at login" checkbox |
| Good for | quick use, SSH, scripts | everyday use |

Works on macOS 11 Big Sur through macOS 27 Golden Gate, on both Apple Silicon
and Intel. No third-party packages needed for the Swift version; the Python
version uses `pyobjc-framework-Quartz`, which Apple's own Python ships with.

---

## 0. The easiest way — the installer .dmg

`Keep-Awake-1.4.1.dmg` (one level up from this folder) is a standard Apple Disk
Image. Double-click it, then double-click **Install Keep Awake**:

- If Apple's free Command Line Tools are present it compiles and installs the
  menu-bar app into `/Applications` and launches it (☕ icon).
- If not, it installs the background agent instead (works immediately) and
  offers to fetch the tools so you can get the menu-bar version later.

If Gatekeeper complains (the dmg is not App-Store signed):
right-click the installer → **Open**, or in Terminal:

```bash
bash "/Volumes/Keep Awake/Install Keep Awake.app/Contents/MacOS/installer"
```

`Extras/uninstall.sh` on the volume removes everything again.

---

## 1. The quick way (terminal)

```bash
cd keep-awake
./setup.sh            # checks Python, does a self-test, prints your options
```

Then run it:

```bash
python3 keep_awake.py
```

Leave that terminal open. `Ctrl+C` stops it. You should see:

```
  [14:02:11] you're active (idle 0s) — skipping
  [14:02:41] nudge #1 -> 731.0,412.0
```

### Useful flags

```bash
python3 keep_awake.py --interval 20            # nudge every 20 s (default 30)
python3 keep_awake.py --mode wiggle --distance 15   # visibly shake the pointer
python3 keep_awake.py --mode circle             # tiny orbit, barely visible
python3 keep_awake.py --mode roam               # drift around the screen
python3 keep_awake.py --always                  # nudge even while you're using the mouse
python3 keep_awake.py --stop-after 4h           # auto-quit after 4 hours
python3 keep_awake.py --once                    # single nudge, to test
python3 keep_awake.py --help                    # everything
```

**Movement modes**

All movement modes in v1.4.1 feature **Universal Anti-AFK Protection**: every nudge performs hardware cursor motion, micro-scroll visual refresh (resets ScreenCaptureKit video change heuristics), and harmless non-character typing (virtual F15, resetting keyboard activity telemetry) tagged with `kCGEventSourceStateHIDSystemState`.

- `slide` *(default)* — smooth, elegant visible glide across the screen and back home.
- `wiggle` — energetic multi-cycle left-right shake, then back home.
- `circle` — smooth orbit around the current position.
- `roam` — smoothly glides the cursor to a different part of the screen each time.
- `jitter` — 1-point hop left/right. Invisible; for when you must not see any pointer motion.
- `warp` — silent cursor reposition.
- `scroll` — turns the mouse wheel once per interval (a real `CGEventScrollWheelEvent`, identical to your middle button), N lines per tick: `--mode scroll --scroll-lines 5`.

**Auto-click (defeats watchers that ignore movement)**

Some corporate agents ignore synthetic mouse *movement* but count *clicks*.
Add a real left click on its own timer:

```bash
python3 keep_awake.py --auto-click                      # click every 5 s at the cursor
python3 keep_awake.py --auto-click --click-interval 2   # every 2 s
python3 keep_awake.py --auto-click --click-point 60,900 # click a FIXED safe point
```

⚠️ A click activates whatever is under it. Prefer `--click-point` parked over
empty desktop, or accept the risk of clicking at the cursor.

### Run it in the background

```bash
nohup python3 keep_awake.py --quiet > ~/Library/Logs/keep_awake.log 2>&1 &
```

Stop it later:

```bash
pkill -f keep_awake.py
```

### Start it at every login

```bash
./setup.sh --autostart     # installs ~/Library/LaunchAgents/com.local.keepawake.plist
./setup.sh --remove        # removes it again
```

Manage it manually with:

```bash
launchctl print gui/$(id -u)/com.local.keepawake     # status
launchctl kickstart -k gui/$(id -u)/com.local.keepawake   # restart now
tail -f ~/Library/Logs/keep_awake.log                # watch the log
```

---

## 2. The nice way (menu-bar app)

Compiles a real `Keep Awake.app` with a ☕ icon in your menu bar.

```bash
cd keep-awake
./menubar/build.sh          # builds "Keep Awake.app" (needs Xcode Command Line Tools)
./menubar/install-app.sh    # copies it to /Applications and launches it
```

If `swiftc` is missing, the build script triggers
`xcode-select --install` — approve the dialog, wait, then run `build.sh` again.

**In the menu you get:**

- **Nudging: ON / OFF** — the power switch. One click flips it; the menu-bar
  cup also changes (filled = ON, outline = OFF) so you can see the state
  without opening the menu. `⌘P`
- **Interval** — 5 / 10 / 15 / 20 / 30 / 45 / 60 / 120 seconds
- **Movement** — Smooth slide (default) · Visible wiggle · Tiny circle · Roam the screen · Jitter · Silent reposition (warp) · **Scroll wheel down** (with a *Scroll amount* submenu: 1–20 lines per interval). All movement modes automatically carry full anti-AFK countermeasures (mouse movement, visual micro-scroll, and harmless F15 typing).
- **Distance** — Subtle (15 pt) · Normal (35 pt) · Large (60 pt) · Extra large (100 pt)
- **Natural timing variation (±15%)** — breaks static periodicity to defeat bot and jiggler detectors
- **Only when I'm idle** — off by default to guarantee continuous recording while reading/waiting for AI responses; when enabled, includes a 15-second safety floor so 30-second AFK timers never trip.
- **Prevent Mac from sleeping** — on by default, keeps both display and system awake with dual IOKit power assertions
- **Auto-click: ON / OFF** — injects a real left click on its own timer
  (default every 5 s), with *Click interval* (2/5/10/30 s) and *Click at:
  cursor / saved point* plus *Save cursor position as click point*. Use the
  saved point parked over empty desktop so clicks hit nothing important.
- **Start at login** — survives reboots. Uses Apple's SMAppService and, if
  that refuses (common for ad-hoc-signed apps), automatically falls back to a
  user LaunchAgent at `~/Library/LaunchAgents/local.keepawake.menubar.plist`.
- **Nudge now** — test it on demand immediately (`⌘N`).
- **Why am I still AFK? Run diagnostics…** — `⌘D`. Displays real-time breakdown
  of typing, mouse, click, scroll, and hardware idle times, verifies anti-AFK status, and reports exact detector status.
- **Reset settings to defaults** — one click back to sane v1.4.1 defaults
  (Smooth slide mode, 35 pt, 15 s, jitter enabled, sleep prevention active, continuous recording).
- A live status line showing ON/OFF, idle seconds, detected action (typing/mouse/click/scroll), and nudge counts.
- Everything is also logged with detected user actions to `~/Library/Logs/KeepAwake.log`

Settings are stored in `UserDefaults`, so they persist between launches.

---

## How it works (and why `caffeinate` alone isn't enough)

```swift
// the whole trick, in three lines
let p = CGEvent(source: nil)!.location                       // where the cursor is
let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: p.x + 1, y: p.y),
                mouseButton: .left)!
e.post(tap: .cghidEventTap)                                  // inject it as real input
```

Posting into `kCGHIDEventTap` puts the event at the **bottom** of the input
pipeline — the same place your trackpad and mouse feed into. macOS therefore
resets the system idle timer, the display-sleep timer, and anything that calls
`CGEventSourceSecondsSinceLastEventType` / `IOKit HID idle time`. That's the
value Teams, Slack, Zoom and monitoring agents read to decide you're AFK.

- **`caffeinate`** stops the Mac from sleeping, but it does **not** move the
  cursor and does **not** reset the idle timer that presence apps use. On its
  own it won't stop an AFK badge.
- **This tool** injects real movement, so both the sleep timer *and* the
  presence timer are satisfied. (It also means your screen won't dim.)

The Python and Swift versions do the same thing; Swift just adds a menu bar.

---

## Troubleshooting

**Nothing moves.**
Run `python3 keep_awake.py --once --mode wiggle --distance 40`. If the cursor
still doesn't jump, Quartz isn't available — `pip3 install pyobjc-framework-Quartz`.

**"You're active — skipping" every time.**
That's the `--min-idle 5` guard working as designed: it only nudges once you've
been hands-off for 5 s. Force it with `--always` if you want constant movement.

**Cursor keeps drifting to a screen edge.**
Positions are clamped 12 pt inside the display bounds, and `jitter` alternates
direction so the net drift is zero. If you use `roam`, switch to `jitter`.

**Nothing seems to move / "the app isn't working".**
Since v1.3 the default movement is a *visible* wiggle, so you should see the
cursor shake once per interval while you're hands-off. If you installed an
older version, its saved settings still say "invisible jitter" — use
**Reset settings to defaults** in the menu (or pick *Movement → Visible
wiggle*). The status line's nudge counter and `~/Library/Logs/KeepAwake.log`
prove what the app is doing every tick.

**A watcher still says I'm idle.**
Run **Why am I still AFK? Run diagnostics…** (`⌘D`). It tells you which of
three worlds you're in:

1. *Idle timer doesn't reset* — something blocks synthetic input entirely
   (rare; a security agent or MDM profile). No software jiggler can work.
2. *Idle timer resets but your app still says away* — that app ignores
   synthetic **movement**. Turn on **Auto-click** and/or **Scroll wheel**
   mode: many watchers only accept click or wheel input.
3. *Everything resets and it still says away* — the app tracks screenshots,
   keystroke content, or window focus (anti-spoofing). No cursor tool of any
   kind can satisfy it; only real interaction will.

For displacement-reading watchers, bigger jumps help:
`--mode wiggle --distance 25`, or `--mode roam`. A few read only keyboard
input — for those, see below.

**Multi-monitor / HiDPI weirdness.**
Bounds are re-read from `CGMainDisplayID()` on every tick, so hot-plugging a
display is handled. Coordinates are in points, not pixels.

**Screen lock / screensaver.**
Movement does not unlock a Mac and won't stop a *forced* lock from an MDM
policy. It only prevents the idle timer from tripping in the first place.

**Need keyboard activity too?**
Swap `kCGEventMouseMoved` for `kCGEventFlagsChanged` (a lone Shift press, no
characters typed) in `post_move()`. Tell me and I'll add a `--keys` flag.

**Permissions.**
Injecting a mouse-move into the HID tap does **not** require Accessibility
permission on current macOS. If a future update ever prompts for it, allow
Terminal (or `Keep Awake.app`) in
System Settings → Privacy & Security → Accessibility.

---

## Uninstall

```bash
./setup.sh --remove                      # remove the LaunchAgent
pkill -f keep_awake.py                   # stop a running copy
rm -rf "/Applications/Keep Awake.app"    # remove the menu-bar app
rm -rf keep-awake                        # remove the whole folder
```

Nothing else is written to your system — no daemons outside
`~/Library/LaunchAgents`, no config outside `UserDefaults`.

---

## One honest note

This keeps your machine looking active. If your employer's policy expects a
real presence, a nudge won't answer messages, join calls, or show up in
keystroke/attention analytics — it only defeats the *idle timer*. Fine for
long builds, downloads, reading, or a locked-down kiosk; not a substitute for
being there when it matters.
