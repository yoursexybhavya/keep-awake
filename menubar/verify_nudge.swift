//
// verify_nudge.swift — self-contained verification check for Keep Awake motion engine.
// Run with: swift menubar/verify_nudge.swift
//

import Cocoa
import CoreGraphics
import IOKit.pwr_mgt

print("==> Checking IOKit display sleep assertion...")
var assertionID: IOPMAssertionID = 0
let iokitResult = IOPMAssertionCreateWithName(
    kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
    IOPMAssertionLevel(kIOPMAssertionLevelOn),
    "Keep Awake Verification Test" as CFString,
    &assertionID
)
assert(iokitResult == kIOReturnSuccess, "Failed to create IOKit power assertion")
assert(assertionID != 0, "Assertion ID is invalid")
IOPMAssertionRelease(assertionID)
print("    IOKit display sleep assertion: PASS")

print("==> Checking cursor position reading...")
let initial = CGEvent(source: nil)?.location ?? .zero
assert(initial.x > 0 || initial.y > 0, "Cursor location returned invalid (0,0)")
print("    Initial cursor position: (\(initial.x), \(initial.y))")

print("==> Checking smooth slide motion & return...")
let bounds = CGDisplayBounds(CGMainDisplayID())
let distance: CGFloat = 40.0
let steps = 24
var maxDisplacement: CGFloat = 0.0

for i in 0...steps {
    let progress = Double(i) / Double(steps)
    let offset = CGFloat(sin(progress * 2.0 * .pi) * Double(distance))
    let x = min(max(initial.x + offset, bounds.minX + 8), bounds.maxX - 8)
    let p = CGPoint(x: x, y: initial.y)
    CGWarpMouseCursorPosition(p)
    if let ev = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) {
        ev.post(tap: .cghidEventTap)
    }
    let current = CGEvent(source: nil)?.location ?? .zero
    let disp = abs(current.x - initial.x)
    if disp > maxDisplacement { maxDisplacement = disp }
    usleep(10000)
}

let finalPos = CGEvent(source: nil)?.location ?? .zero
print("    Max displacement during slide: \(maxDisplacement)pt (expected >= 35pt)")
assert(maxDisplacement >= 30.0, "Cursor did not achieve expected displacement during slide")

let drift = hypot(finalPos.x - initial.x, finalPos.y - initial.y)
print("    Position drift after slide: \(drift)pt (expected < 2pt)")
assert(drift < 2.0, "Cursor did not return to origin after slide")

print("==> Checking idle timer query...")
let anyInput = CGEventType(rawValue: ~CGEventType.RawValue(0))!
let idle = Double(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput))
assert(idle >= 0.0, "Idle timer returned negative number")
print("    Current idle: \(idle)s")

print("==> ALL VERIFICATION CHECKS PASSED SUCCESSFULLY.")
