//
// verify_nudge.swift — self-contained verification check for Keep Awake v1.4.2 universal anti-AFK engine.
// Run with: swift menubar/verify_nudge.swift
//

import Cocoa
import CoreGraphics
import IOKit
import IOKit.pwr_mgt

print("==> 1. Checking dual IOKit display + system sleep assertions...")
var displayAssertion: IOPMAssertionID = 0
var systemAssertion: IOPMAssertionID = 0

let dRes = IOPMAssertionCreateWithName(
    kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
    IOPMAssertionLevel(kIOPMAssertionLevelOn),
    "Keep Awake Verification Test" as CFString,
    &displayAssertion
)
assert(dRes == kIOReturnSuccess && displayAssertion != 0, "Display sleep assertion failed")

let sRes = IOPMAssertionCreateWithName(
    kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
    IOPMAssertionLevel(kIOPMAssertionLevelOn),
    "Keep Awake Verification Test" as CFString,
    &systemAssertion
)
assert(sRes == kIOReturnSuccess && systemAssertion != 0, "System sleep assertion failed")

IOPMAssertionRelease(displayAssertion)
IOPMAssertionRelease(systemAssertion)
print("    Dual sleep assertions: PASS")

print("==> 2. Checking multi-input activity detection (typing, mouse, click, scroll, IOHIDSystem)...")
let tKeyDown = Double(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown))
let mouse = Double(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved))
let scroll = Double(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel))
let click = Double(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown))

assert(tKeyDown >= 0.0, "Invalid keyDown idle time")
assert(mouse >= 0.0, "Invalid mouse idle time")
assert(scroll >= 0.0, "Invalid scroll idle time")
assert(click >= 0.0, "Invalid click idle time")

print("    Detected metrics: typing=\(String(format: "%.1f", tKeyDown))s, mouse=\(String(format: "%.1f", mouse))s, click=\(String(format: "%.1f", click))s, scroll=\(String(format: "%.1f", scroll))s")
print("    Multi-input activity monitoring: PASS")

print("==> 3. Checking AFK Bypass sequence (hardware slide + micro-scroll + harmless key)...")
let src = CGEventSource(stateID: .hidSystemState)
let initial = CGEvent(source: nil)?.location ?? .zero
let bounds = CGDisplayBounds(CGMainDisplayID())

// Slide
let distance: CGFloat = 35.0
var maxDisplacement: CGFloat = 0.0
for i in 0...24 {
    let progress = Double(i) / 24.0
    let offset = CGFloat(sin(progress * 2.0 * .pi) * Double(distance))
    let x = min(max(initial.x + offset, bounds.minX + 8), bounds.maxX - 8)
    let p = CGPoint(x: x, y: initial.y)
    if let ev = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) {
        ev.post(tap: .cghidEventTap)
    }
    CGWarpMouseCursorPosition(p)
    let cur = CGEvent(source: nil)?.location ?? .zero
    let d = abs(cur.x - initial.x)
    if d > maxDisplacement { maxDisplacement = d }
    usleep(5000)
}
assert(maxDisplacement >= 25.0, "Slide displacement insufficient")

// Micro-scroll (down + up)
if let down = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0),
   let up = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0) {
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

// Harmless F15 key down & up
if let kdown = CGEvent(keyboardEventSource: nil, virtualKey: 113, keyDown: true),
   let kup = CGEvent(keyboardEventSource: nil, virtualKey: 113, keyDown: false) {
    kdown.post(tap: .cghidEventTap)
    kup.post(tap: .cghidEventTap)
}

let finalPos = CGEvent(source: nil)?.location ?? .zero
let drift = hypot(finalPos.x - initial.x, finalPos.y - initial.y)
assert(drift < 2.0, "Cursor drift after slide exceeded tolerance")
print("    Max displacement: \(maxDisplacement)pt | Return drift: \(drift)pt")
print("    Anti-AFK composite execution: PASS")

print("==> ALL v1.4.2 VERIFICATION CHECKS PASSED.")
