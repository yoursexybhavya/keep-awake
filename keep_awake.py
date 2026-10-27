#!/usr/bin/env python3
"""
keep_awake.py — anti-AFK cursor nudger for macOS.

Moves the mouse cursor by a tiny amount on a timer so that apps which track
"idle time" (Teams, Slack, Zoom, corporate presence/monitoring agents, screen
recorders, etc.) never see you go AFK.

It also stops the display and the Mac itself from sleeping, because a real
mouse event is injected into the event stream.

Usage:
    python3 keep_awake.py                     # nudge every 30s, only when idle
    python3 keep_awake.py --interval 45       # nudge every 45s
    python3 keep_awake.py --mode wiggle       # visibly wiggle the pointer
    python3 keep_awake.py --always            # nudge even while you use the Mac
    python3 keep_awake.py --stop-after 4h     # auto-exit after 4 hours
    python3 keep_awake.py --once              # single nudge (test it works)

Stop with Ctrl+C.

Requires: macOS + PyObjC (preinstalled with Apple's system Python 3, or
`pip3 install pyobjc-framework-Quartz`).
"""

from __future__ import annotations

import argparse
import math
import signal
import sys
import time

# ---------------------------------------------------------------------------
# macOS / CoreGraphics bindings
# ---------------------------------------------------------------------------

try:
    from Quartz import (
        CGDisplayBounds,
        CGEventCreateMouseEvent,
        CGEventCreateScrollWheelEvent,
        CGEventPost,
        CGEventSourceSecondsSinceLastEventType,
        CGMainDisplayID,
        CGWarpMouseCursorPosition,
        CGPointMake,
        kCGAnyInputEventType,
        kCGEventMouseMoved,
        kCGEventLeftMouseDown,
        kCGEventLeftMouseUp,
        kCGHIDEventTap,
        kCGMouseButtonLeft,
        kCGNullEventSource,
        kCGScrollEventUnitLine,
    )
    try:
        # Only present when ScreenTime/DisplayServices are available; optional.
        from Quartz import CGAssociateMouseAndMouseCursorPosition  # noqa: F401
    except ImportError:
        pass
except ImportError as exc:  # pragma: no cover - platform specific
    sys.exit(
        "\n  Could not import Quartz (PyObjC). This script only runs on macOS.\n"
        "  Install the binding with:\n\n"
        "      pip3 install pyobjc-framework-Quartz\n\n"
        f"  (import error was: {exc})\n"
    )


def screen_rect():
    """Bounds of the main display, in global points."""
    return CGDisplayBounds(CGMainDisplayID())


def seconds_since_any_input() -> float:
    """How long since the user last touched mouse / keyboard / trackpad."""
    try:
        return float(
            CGEventSourceSecondsSinceLastEventType(kCGNullEventSource, kCGAnyInputEventType)
        )
    except Exception:
        return float("inf")


def post_move(x: float, y: float) -> None:
    """Inject a real mouse-moved event at (x, y)."""
    event = CGEventCreateMouseEvent(
        kCGNullEventSource, kCGEventMouseMoved, CGPointMake(x, y), kCGMouseButtonLeft
    )
    if event is None:
        raise RuntimeError("CGEventCreateMouseEvent returned NULL")
    CGEventPost(kCGHIDEventTap, event)


def post_scroll(lines: int) -> None:
    """Inject a real scroll-wheel event — identical to turning the middle
    button's wheel by `lines` notches. Positive = down, negative = up."""
    event = CGEventCreateScrollWheelEvent(
        kCGNullEventSource, kCGScrollEventUnitLine, 1, lines
    )
    if event is None:
        raise RuntimeError("CGEventCreateScrollWheelEvent returned NULL")
    CGEventPost(kCGHIDEventTap, event)


def post_click(x: float, y: float) -> None:
    """Inject a real left-button press+release at (x, y) — identical to a
    physical click. Beware: it clicks whatever is under the point."""
    down = CGEventCreateMouseEvent(
        kCGNullEventSource, kCGEventLeftMouseDown, CGPointMake(x, y), kCGMouseButtonLeft
    )
    up = CGEventCreateMouseEvent(
        kCGNullEventSource, kCGEventLeftMouseUp, CGPointMake(x, y), kCGMouseButtonLeft
    )
    if down is None or up is None:
        raise RuntimeError("CGEventCreateMouseEvent returned NULL")
    CGEventPost(kCGHIDEventTap, down)
    CGEventPost(kCGHIDEventTap, up)


def warp(x: float, y: float) -> None:
    """Reposition the cursor without generating an event (silent)."""
    CGWarpMouseCursorPosition(CGPointMake(x, y))


def current_position():
    """Current cursor location — read from the event we build, cheaply."""
    from Quartz import CGEventCreate, CGEventGetLocation

    loc = CGEventGetLocation(CGEventCreate(kCGNullEventSource))
    return loc.x, loc.y


# ---------------------------------------------------------------------------
# Movement strategies
# ---------------------------------------------------------------------------


def clamp_to_screen(x: float, y: float, rect) -> tuple[float, float]:
    """Keep the point inside the visible screen, with a small margin."""
    margin = 12.0
    min_x = rect.origin.x + margin
    min_y = rect.origin.y + margin
    max_x = rect.origin.x + rect.size.width - margin
    max_y = rect.origin.y + rect.size.height - margin
    return (
        min(max(x, min_x), max_x),
        min(max(y, min_y), max_y),
    )


class Nudger:
    """Decides where the cursor goes on each tick."""

    def __init__(self, mode: str, distance: float):
        self.mode = mode
        self.distance = distance
        self.step = 0
        self.origin: tuple[float, float] | None = None

    def next_point(self, rect):
        x, y = current_position()
        self.step += 1

        if self.mode == "jitter":
            # Sub-pixel / 1px hop that alternates direction.
            # Effectively invisible, but still registers as input.
            dx = self.distance if self.step % 2 == 0 else -self.distance
            target = (x + dx, y)

        elif self.mode == "circle":
            # Tiny circle around wherever the cursor already is.
            if self.origin is None:
                self.origin = (x, y)
            angle = (self.step % 36) * (2 * math.pi / 36)
            target = (
                self.origin[0] + self.distance * math.cos(angle),
                self.origin[1] + self.distance * math.sin(angle),
            )

        elif self.mode == "wiggle":
            # Visible left-right wiggle, then return home.
            if self.origin is None:
                self.origin = (x, y)
            phase = self.step % 3  # 0 -> right, 1 -> left, 2 -> home
            dx = {0: self.distance, 1: -self.distance, 2: 0.0}[phase]
            target = (self.origin[0] + dx, self.origin[1])

        elif self.mode == "roam":
            # Wander to a random-ish point in the middle of the screen.
            w, h = rect.size.width, rect.size.height
            seed_a = math.sin(self.step * 12.9898) * 43758.5453
            seed_b = math.sin(self.step * 78.233) * 12345.6789
            fx = 0.25 + 0.5 * (seed_a - math.floor(seed_a))
            fy = 0.25 + 0.5 * (seed_b - math.floor(seed_b))
            target = (rect.origin.x + w * fx, rect.origin.y + h * fy)

        elif self.mode == "warp":
            # Silent reposition, no event at all. Use only if your AFK watcher
            # reads the cursor position instead of the idle timer.
            dx = self.distance if self.step % 2 == 0 else -self.distance
            target = (x + dx, y)

        else:
            raise ValueError(f"unknown mode: {self.mode}")

        if self.mode == "wiggle" and self.step % 3 == 2:
            # returning home — reset the remembered origin so it follows the user
            self.origin = None

        return clamp_to_screen(target[0], target[1], rect)


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------


def parse_duration(text: str) -> float:
    """'90' -> 90s, '5m' -> 300s, '2h' -> 7200s, '0' -> forever."""
    text = text.strip().lower()
    if not text:
        return 0.0
    mult = 1.0
    if text[-1] in "smhd":
        mult = {"s": 1, "m": 60, "h": 3600, "d": 86400}[text[-1]]
        text = text[:-1]
    return float(text) * mult


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="keep_awake.py",
        description="Anti-AFK: nudges the macOS cursor so you never show as idle.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument(
        "--interval",
        type=float,
        default=30.0,
        help="seconds between nudges (most AFK timers use 30-60s)",
    )
    p.add_argument(
        "--mode",
        choices=["jitter", "circle", "wiggle", "roam", "warp", "scroll"],
        default="wiggle",
        help="wiggle=visible shake (default), jitter=invisible 1px hop, "
        "circle=tiny orbit, roam=drift around screen, warp=silent reposition "
        "(no event), scroll=turn the mouse wheel down every interval",
    )
    p.add_argument(
        "--distance",
        type=float,
        default=12.0,
        help="how far the cursor moves per nudge, in points (visible >= ~6)",
    )
    p.add_argument(
        "--scroll-lines",
        type=int,
        default=3,
        help="with --mode scroll: wheel notches (lines) scrolled per interval; "
        "negative scrolls up",
    )
    p.add_argument(
        "--auto-click",
        action="store_true",
        help="also inject a real left click on its own timer (defeats watchers "
        "that ignore movement but count clicks)",
    )
    p.add_argument(
        "--click-interval",
        type=float,
        default=5.0,
        help="seconds between auto-clicks (default 5)",
    )
    p.add_argument(
        "--click-point",
        default=None,
        metavar="X,Y",
        help="click at this fixed screen point instead of the cursor position "
        "(safer: park it over empty desktop)",
    )
    p.add_argument(
        "--always",
        action="store_true",
        help="nudge even while you are actively using the mouse",
    )
    p.add_argument(
        "--min-idle",
        type=float,
        default=5.0,
        help="only nudge after this many seconds of no user input (ignored with --always)",
    )
    p.add_argument(
        "--stop-after",
        default="0",
        help="auto-exit after a duration, e.g. 30m / 4h / 1d (0 = run forever)",
    )
    p.add_argument("--quiet", action="store_true", help="suppress per-nudge logging")
    p.add_argument("--once", action="store_true", help="perform a single nudge and exit")
    return p


def main() -> int:
    args = build_arg_parser().parse_args()

    if sys.platform != "darwin":
        sys.exit("  This tool only runs on macOS.")

    interval = max(1.0, args.interval)
    run_for = parse_duration(args.stop_after)
    nudger = Nudger(args.mode, args.distance)
    rect = screen_rect()

    stop = {"flag": False}

    def handle_sig(signum, frame):
        stop["flag"] = True

    signal.signal(signal.SIGINT, handle_sig)
    signal.signal(signal.SIGTERM, handle_sig)

    def nudge() -> str:
        nonlocal rect
        rect = screen_rect()  # display arrangement can change
        if args.mode == "scroll":
            post_scroll(args.scroll_lines)
            return f"wheel {args.scroll_lines:+d} lines"
        x, y = nudger.next_point(rect)
        if args.mode == "warp":
            warp(x, y)
            return "warped"
        post_move(x, y)
        return f"{x:.1f},{y:.1f}"

    if args.once:
        where = nudge()
        print(f"  nudged once ({where}). Idle seconds now: {seconds_since_any_input():.1f}")
        return 0

    started = time.time()
    if not args.quiet:
        mins = "forever" if run_for == 0 else f"{run_for / 60:.0f} min"
        print("=" * 62)
        print("  KEEP AWAKE — anti-AFK cursor nudger")
        print("=" * 62)
        if args.mode == "scroll":
            print(f"  mode      : scroll (wheel {args.scroll_lines:+d} lines per tick)")
        else:
            print(f"  mode      : {args.mode} ({args.distance:g} pt per nudge)")
        print(f"  interval  : every {interval:g}s")
        if args.auto_click:
            at = args.click_point or "cursor position"
            print(f"  auto-click: every {args.click_interval:g}s at {at}")
        print(f"  trigger   : {'always' if args.always else f'only after {args.min_idle:g}s idle'}")
        print(f"  duration  : {mins}")
        print(f"  screen    : {rect.size.width:.0f}x{rect.size.height:.0f}")
        print("  press Ctrl+C to stop")
        print("-" * 62)

    nudges = skipped = clicks = 0
    next_tick = time.time()
    do_click = args.auto_click
    click_iv = max(1.0, args.click_interval)
    next_click = time.time() + click_iv
    click_pt = None
    if args.click_point:
        cx, cy = args.click_point.replace(" ", "").split(",")
        click_pt = (float(cx), float(cy))

    def do_auto_click() -> None:
        nonlocal clicks
        pt = click_pt or current_position()
        post_click(pt[0], pt[1])
        clicks += 1
        if not args.quiet:
            print(f"  [{time.strftime('%H:%M:%S')}] click #{clicks} at {pt[0]:.0f},{pt[1]:.0f}")

    while not stop["flag"]:
        now = time.time()
        wake = min(next_tick, next_click) if do_click else next_tick
        if now < wake:
            time.sleep(min(0.25, wake - now))
            continue

        if run_for and (now - started) >= run_for:
            if not args.quiet:
                print(f"\n  Reached the {run_for / 60:.0f} min limit — stopping.")
            break

        idle = None if args.always else seconds_since_any_input()
        user_active = idle is not None and idle < args.min_idle

        if now >= next_tick:
            next_tick = now + interval
            if user_active:
                skipped += 1
                if not args.quiet:
                    print(f"  [{time.strftime('%H:%M:%S')}] you're active (idle {idle:.0f}s) — skipping")
            else:
                try:
                    where = nudge()
                except Exception as exc:
                    print(f"  nudge failed: {exc}", file=sys.stderr)
                    time.sleep(5)
                    where = None
                if where is not None:
                    nudges += 1
                    if not args.quiet:
                        print(f"  [{time.strftime('%H:%M:%S')}] nudge #{nudges} -> {where}")

        if do_click and now >= next_click:
            next_click = now + click_iv
            if user_active:
                if not args.quiet:
                    print(f"  [{time.strftime('%H:%M:%S')}] click skipped — you're active")
            else:
                try:
                    do_auto_click()
                except Exception as exc:
                    print(f"  click failed: {exc}", file=sys.stderr)

    if not args.quiet:
        elapsed = time.time() - started
        print("-" * 62)
        print(f"  Stopped after {elapsed / 60:.1f} min — {nudges} nudges, "
              f"{clicks} clicks, {skipped} skipped.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\n  Stopped.")
        raise SystemExit(0)
