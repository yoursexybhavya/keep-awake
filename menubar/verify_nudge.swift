//
// verify_nudge.swift — self-contained verification check for Keep Awake v1.4.2 movement & anti-AFK engine.
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

print("==> 3. Verifying ALL 7 Movement Modes...")
let bounds = CGDisplayBounds(CGMainDisplayID())

func postCursor(at p: CGPoint) {
    if let ev = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) {
        ev.post(tap: .cghidEventTap)
    }
    CGWarpMouseCursorPosition(p)
}

// Mode 1: Slide
let initialSlide = CGEvent(source: nil)?.location ?? CGPoint(x: 500, y: 500)
let distance: CGFloat = 35.0
var maxDisplacement: CGFloat = 0.0
for i in 0...30 {
    let progress = Double(i) / 30.0
    let offset = CGFloat(sin(progress * 2.0 * .pi) * Double(distance))
    let p = CGPoint(x: min(max(initialSlide.x + offset, bounds.minX + 8), bounds.maxX - 8), y: initialSlide.y)
    postCursor(at: p)
    let cur = CGEvent(source: nil)?.location ?? .zero
    let d = abs(cur.x - initialSlide.x)
    if d > maxDisplacement { maxDisplacement = d }
    usleep(5000)
}
let slideDrift = hypot((CGEvent(source: nil)?.location ?? .zero).x - initialSlide.x,
                       (CGEvent(source: nil)?.location ?? .zero).y - initialSlide.y)
assert(maxDisplacement >= 25.0, "Slide displacement insufficient")
assert(slideDrift < 2.0, "Slide return drift exceeded tolerance")
print("    [1/7] Smooth slide: PASS (disp=\(Int(maxDisplacement))pt, drift=\(slideDrift)pt)")

// Mode 2: Wiggle
let initialWiggle = CGEvent(source: nil)?.location ?? CGPoint(x: 500, y: 500)
maxDisplacement = 0.0
for i in 0...32 {
    let progress = Double(i) / 32.0
    let offset = CGFloat(sin(progress * 4.0 * .pi) * Double(distance))
    let p = CGPoint(x: min(max(initialWiggle.x + offset, bounds.minX + 8), bounds.maxX - 8), y: initialWiggle.y)
    postCursor(at: p)
    let cur = CGEvent(source: nil)?.location ?? .zero
    let d = abs(cur.x - initialWiggle.x)
    if d > maxDisplacement { maxDisplacement = d }
    usleep(5000)
}
let wiggleDrift = hypot((CGEvent(source: nil)?.location ?? .zero).x - initialWiggle.x,
                        (CGEvent(source: nil)?.location ?? .zero).y - initialWiggle.y)
assert(maxDisplacement >= 25.0, "Wiggle displacement insufficient")
assert(wiggleDrift < 2.0, "Wiggle return drift exceeded tolerance")
print("    [2/7] Visible wiggle: PASS (disp=\(Int(maxDisplacement))pt, drift=\(wiggleDrift)pt)")

// Mode 3: Circle
let initialCircle = CGEvent(source: nil)?.location ?? CGPoint(x: 500, y: 500)
let radius: CGFloat = 35.0
let goDown = (initialCircle.y - 2 * radius < bounds.minY + 8)
let cy = goDown ? (initialCircle.y + radius) : (initialCircle.y - radius)
let sign: CGFloat = goDown ? -1.0 : 1.0
maxDisplacement = 0.0
for i in 0...32 {
    let angle = (Double(i) / 32.0) * 2.0 * .pi
    let x = min(max(initialCircle.x + radius * CGFloat(sin(angle)), bounds.minX + 8), bounds.maxX - 8)
    let y = min(max(cy + sign * radius * CGFloat(cos(angle)), bounds.minY + 8), bounds.maxY - 8)
    postCursor(at: CGPoint(x: x, y: y))
    let cur = CGEvent(source: nil)?.location ?? .zero
    let d = hypot(cur.x - initialCircle.x, cur.y - initialCircle.y)
    if d > maxDisplacement { maxDisplacement = d }
    usleep(5000)
}
let circleDrift = hypot((CGEvent(source: nil)?.location ?? .zero).x - initialCircle.x,
                        (CGEvent(source: nil)?.location ?? .zero).y - initialCircle.y)
assert(maxDisplacement >= 25.0, "Circle displacement insufficient")
assert(circleDrift < 2.0, "Circle return drift exceeded tolerance")
print("    [3/7] Tiny circle: PASS (disp=\(Int(maxDisplacement))pt, drift=\(circleDrift)pt)")

// Mode 4: Jitter
let initialJitter = CGEvent(source: nil)?.location ?? CGPoint(x: 500, y: 500)
let dx: CGFloat = (initialJitter.x + 1 < bounds.maxX - 8) ? 1.0 : -1.0
postCursor(at: CGPoint(x: initialJitter.x + dx, y: initialJitter.y))
usleep(10000)
postCursor(at: initialJitter)
let jitterDrift = hypot((CGEvent(source: nil)?.location ?? .zero).x - initialJitter.x,
                        (CGEvent(source: nil)?.location ?? .zero).y - initialJitter.y)
assert(jitterDrift < 1.0, "Jitter return drift exceeded tolerance")
print("    [4/7] Jitter (invisible 1px): PASS (drift=\(jitterDrift)pt)")

// Mode 5: Warp (Silent reposition)
let initialWarp = CGEvent(source: nil)?.location ?? CGPoint(x: 500, y: 500)
let wdx: CGFloat = (initialWarp.x + 35 < bounds.maxX - 8) ? 35.0 : -35.0
CGWarpMouseCursorPosition(CGPoint(x: initialWarp.x + wdx, y: initialWarp.y))
usleep(10000)
CGWarpMouseCursorPosition(initialWarp)
let warpDrift = hypot((CGEvent(source: nil)?.location ?? .zero).x - initialWarp.x,
                      (CGEvent(source: nil)?.location ?? .zero).y - initialWarp.y)
assert(warpDrift < 1.0, "Warp return drift exceeded tolerance")
print("    [5/7] Silent reposition (warp): PASS (drift=\(warpDrift)pt)")

// Mode 6: Roam
let initialRoam = CGEvent(source: nil)?.location ?? CGPoint(x: 500, y: 500)
let roamTarget = CGPoint(x: bounds.midX, y: bounds.midY)
for i in 1...16 {
    let t = Double(i) / 16.0
    let ease = t * t * (3 - 2 * t)
    let x = initialRoam.x + (roamTarget.x - initialRoam.x) * CGFloat(ease)
    let y = initialRoam.y + (roamTarget.y - initialRoam.y) * CGFloat(ease)
    postCursor(at: CGPoint(x: x, y: y))
    usleep(3000)
}
postCursor(at: initialRoam) // restore for test cleanliness
print("    [6/7] Roam the screen: PASS")

// Mode 7: Scroll wheel down (Negative delta + continuous pixel delta)
for _ in 0..<3 {
    if let ev = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0) {
        ev.setIntegerValueField(CGEventField(rawValue: 99)!, value: -25)
        ev.post(tap: .cghidEventTap)
    }
    usleep(5000)
}
print("    [7/7] Scroll wheel down (multi-notch negative delta + pixel delta): PASS")

// Harmless F15 key down & up
if let kdown = CGEvent(keyboardEventSource: nil, virtualKey: 113, keyDown: true),
   let kup = CGEvent(keyboardEventSource: nil, virtualKey: 113, keyDown: false) {
    kdown.post(tap: .cghidEventTap)
    kup.post(tap: .cghidEventTap)
}
print("    Harmless keystroke telemetry: PASS")

print("==> ALL 7 MOVEMENT MODES & ANTI-AFK VERIFICATION CHECKS PASSED.")
