//
//  KeepAwake.swift — menu-bar anti-AFK cursor nudger for macOS.
//
//  Single-file Swift app. No Xcode project, no dependencies, no App Store.
//  Build:  ./menubar/build.sh        (or see README)
//
//  Lives in your menu bar as a cup icon. Moves the cursor, turns the scroll
//  wheel, injects simulated typing/clicks, and prevents screen/system sleep
//  so presence & AFK detectors (Teams, Slack, Zoom, Kuro, Hubstaff, etc.)
//  never mark you Away.
//
//  v1.4.2: Strict "Only when I'm idle" honoring user activity (no forced nudges),
//          clean neutral menu options across all modes and intervals,
//          hardware-accurate CGEvent dispatch + warp order to defeat Kuro and OS idle timers.
//

import Cocoa
import CoreGraphics
import ServiceManagement
import IOKit
import IOKit.pwr_mgt

// MARK: - Activity Tracking

struct ActivitySnapshot {
    let idleSeconds: Double
    let lastActionKind: String
    let lastActionDescription: String
    let typingIdle: Double
    let mouseIdle: Double
    let clickIdle: Double
    let scrollIdle: Double
    let hardwareIdle: Double
}

func getIOHIDIdle() -> Double {
    var iter: io_iterator_t = 0
    let match = IOServiceMatching("IOHIDSystem")
    guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS else { return 999 }
    defer { IOObjectRelease(iter) }
    let entry = IOIteratorNext(iter)
    guard entry != 0 else { return 999 }
    defer { IOObjectRelease(entry) }
    var dict: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(entry, &dict, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let properties = dict?.takeRetainedValue() as? [String: Any],
          let nanoseconds = properties["HIDIdleTime"] as? Int64 else { return 999 }
    return Double(nanoseconds) / 1_000_000_000.0
}

// MARK: - Settings

final class Settings {
    static let shared = Settings()

    enum Mode: String, CaseIterable {
        case slide  = "Smooth slide (visible)"
        case wiggle = "Visible wiggle"
        case circle = "Tiny circle"
        case roam   = "Roam the screen"
        case jitter = "Jitter (invisible, 1 px)"
        case warp   = "Silent reposition (no event)"
        case scroll = "Scroll wheel down"
    }

    @objc dynamic var enabled: Bool = true { didSet { applySleepAssertion(); save() } }
    @objc dynamic var interval: Double = 15 { didSet { save() } }
    @objc dynamic var onlyWhenIdle: Bool = false { didSet { save() } }
    @objc dynamic var idleThreshold: Double = 5 { didSet { save() } }
    @objc dynamic var distance: Double = 35 { didSet { save() } }
    @objc dynamic var scrollLines: Int = 3 { didSet { save() } }
    @objc dynamic var humanJitter: Bool = true { didSet { save() } }
    @objc dynamic var launchAtLogin: Bool = false { didSet { applyLaunchAtLogin(); save() } }
    @objc dynamic var preventSleep: Bool = true { didSet { applySleepAssertion(); save() } }
    @objc dynamic var modeRaw: String = Mode.slide.rawValue { didSet { save() } }

    // Auto-click channel
    @objc dynamic var autoClick: Bool = false { didSet { save() } }
    @objc dynamic var clickInterval: Double = 5 { didSet { save() } }
    @objc dynamic var clickAtSavedPoint: Bool = false { didSet { save() } }
    @objc dynamic var hasClickPoint: Bool = false { didSet { save() } }
    @objc dynamic var clickPointX: Double = 0 { didSet { save() } }
    @objc dynamic var clickPointY: Double = 0 { didSet { save() } }

    var mode: Mode {
        if let m = Mode(rawValue: modeRaw) { return m }
        if modeRaw.contains("slide") { return .slide }
        if modeRaw.contains("wiggle") { return .wiggle }
        if modeRaw.contains("circle") { return .circle }
        if modeRaw.contains("roam") { return .roam }
        if modeRaw.contains("jitter") { return .jitter }
        if modeRaw.contains("warp") { return .warp }
        if modeRaw.contains("scroll") { return .scroll }
        return .slide
    }

    private let defaults = UserDefaults.standard
    private var displayAssertionID: IOPMAssertionID = 0
    private var systemAssertionID: IOPMAssertionID = 0

    private init() { load() }

    private func load() {
        if defaults.object(forKey: "enabled") != nil { enabled = defaults.bool(forKey: "enabled") }
        if defaults.object(forKey: "interval") != nil {
            let iv = defaults.double(forKey: "interval")
            interval = iv > 0 ? iv : 15
        }
        if defaults.object(forKey: "onlyWhenIdle") != nil { onlyWhenIdle = defaults.bool(forKey: "onlyWhenIdle") }
        if defaults.object(forKey: "idleThreshold") != nil { idleThreshold = defaults.double(forKey: "idleThreshold") }
        if defaults.object(forKey: "distance") != nil {
            let d = defaults.double(forKey: "distance")
            distance = d > 0 ? d : 35
        }
        if defaults.object(forKey: "scrollLines") != nil { scrollLines = defaults.integer(forKey: "scrollLines") }
        if defaults.object(forKey: "humanJitter") != nil { humanJitter = defaults.bool(forKey: "humanJitter") }
        if defaults.object(forKey: "launchAtLogin") != nil { launchAtLogin = defaults.bool(forKey: "launchAtLogin") }
        if defaults.object(forKey: "preventSleep") != nil { preventSleep = defaults.bool(forKey: "preventSleep") }
        if let raw = defaults.string(forKey: "mode") {
            if raw.contains("Bypass") || raw.contains("bypass") {
                modeRaw = Mode.slide.rawValue
            } else if Mode(rawValue: raw) != nil {
                modeRaw = raw
            }
        }
        if defaults.object(forKey: "autoClick") != nil { autoClick = defaults.bool(forKey: "autoClick") }
        if defaults.object(forKey: "clickInterval") != nil { clickInterval = defaults.double(forKey: "clickInterval") }
        if defaults.object(forKey: "clickAtSavedPoint") != nil { clickAtSavedPoint = defaults.bool(forKey: "clickAtSavedPoint") }
        if defaults.object(forKey: "hasClickPoint") != nil { hasClickPoint = defaults.bool(forKey: "hasClickPoint") }
        if defaults.object(forKey: "clickPointX") != nil { clickPointX = defaults.double(forKey: "clickPointX") }
        if defaults.object(forKey: "clickPointY") != nil { clickPointY = defaults.double(forKey: "clickPointY") }
    }

    private func save() {
        defaults.set(enabled, forKey: "enabled")
        defaults.set(interval, forKey: "interval")
        defaults.set(onlyWhenIdle, forKey: "onlyWhenIdle")
        defaults.set(idleThreshold, forKey: "idleThreshold")
        defaults.set(distance, forKey: "distance")
        defaults.set(scrollLines, forKey: "scrollLines")
        defaults.set(humanJitter, forKey: "humanJitter")
        defaults.set(launchAtLogin, forKey: "launchAtLogin")
        defaults.set(preventSleep, forKey: "preventSleep")
        defaults.set(modeRaw, forKey: "mode")
        defaults.set(autoClick, forKey: "autoClick")
        defaults.set(clickInterval, forKey: "clickInterval")
        defaults.set(clickAtSavedPoint, forKey: "clickAtSavedPoint")
        defaults.set(hasClickPoint, forKey: "hasClickPoint")
        defaults.set(clickPointX, forKey: "clickPointX")
        defaults.set(clickPointY, forKey: "clickPointY")
    }

    func resetToDefaults() {
        let keepLogin = launchAtLogin
        for k in ["enabled", "interval", "onlyWhenIdle", "idleThreshold", "distance",
                  "scrollLines", "humanJitter", "mode", "preventSleep", "autoClick",
                  "clickInterval", "clickAtSavedPoint", "hasClickPoint", "clickPointX", "clickPointY"] {
            defaults.removeObject(forKey: k)
        }
        enabled = true; interval = 15; onlyWhenIdle = false; idleThreshold = 5
        distance = 35; scrollLines = 3; humanJitter = true
        modeRaw = Mode.slide.rawValue
        preventSleep = true
        autoClick = false; clickInterval = 5; clickAtSavedPoint = false
        hasClickPoint = false; clickPointX = 0; clickPointY = 0
        launchAtLogin = keepLogin
        save()
        applySleepAssertion()
    }

    // MARK: display & system sleep prevention assertion

    func applySleepAssertion() {
        if enabled && preventSleep {
            if displayAssertionID == 0 {
                let success = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "Keep Awake Display Sleep Prevention" as CFString,
                    &displayAssertionID
                )
                if success != kIOReturnSuccess { displayAssertionID = 0 }
            }
            if systemAssertionID == 0 {
                let success = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "Keep Awake System Sleep Prevention" as CFString,
                    &systemAssertionID
                )
                if success != kIOReturnSuccess { systemAssertionID = 0 }
            }
        } else {
            if displayAssertionID != 0 {
                IOPMAssertionRelease(displayAssertionID)
                displayAssertionID = 0
            }
            if systemAssertionID != 0 {
                IOPMAssertionRelease(systemAssertionID)
                systemAssertionID = 0
            }
        }
    }

    // MARK: start at login

    static var launchAgentPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/local.keepawake.menubar.plist"
    }

    func applyLaunchAtLogin() {
        let fm = FileManager.default
        if #available(macOS 13.0, *) {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                try? fm.removeItem(atPath: Settings.launchAgentPath)
                return
            } catch {
                NSLog("KeepAwake: SMAppService failed (\(error)) — using LaunchAgent fallback")
            }
        }
        do {
            if launchAtLogin {
                let exe = Bundle.main.bundlePath + "/Contents/MacOS/KeepAwake"
                let plist = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>Label</key><string>local.keepawake.menubar</string>
                    <key>ProgramArguments</key><array><string>\(exe)</string></array>
                    <key>RunAtLoad</key><true/>
                    <key>LimitLoadToSessionType</key><string>Aqua</string>
                    <key>ProcessType</key><string>Interactive</string>
                </dict>
                </plist>
                """
                let dir = (Settings.launchAgentPath as NSString).deletingLastPathComponent
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try plist.write(toFile: Settings.launchAgentPath, atomically: true, encoding: .utf8)
            } else {
                try? fm.removeItem(atPath: Settings.launchAgentPath)
            }
        } catch {
            NSLog("KeepAwake: LaunchAgent fallback failed: \(error)")
        }
    }

    func loginItemInstalled() -> Bool {
        FileManager.default.fileExists(atPath: Settings.launchAgentPath)
    }
}

// MARK: - Logging

enum Log {
    static let path = NSHomeDirectory() + "/Library/Logs/KeepAwake.log"
    private static let queue = DispatchQueue(label: "keepawake.log")

    static func write(_ message: String) {
        queue.async {
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let line = "\(stamp.string(from: Date())) \(message)\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: path) {
                    if let h = FileHandle(forWritingAtPath: path) {
                        h.seekToEndOfFile()
                        h.write(data)
                        h.closeFile()
                        return
                    }
                }
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}

// MARK: - Cursor & Input Engine

final class CursorNudger {
    private var step = 0
    private var isAnimating = false
    private let animQueue = DispatchQueue(label: "local.keepawake.anim", qos: .userInteractive)
    private let hidSource = CGEventSource(stateID: .hidSystemState)

    static let shared = CursorNudger()

    func currentLocation() -> CGPoint {
        let ev = CGEvent(source: nil)
        return ev?.location ?? .zero
    }

    /// Evaluates all user input channels: keyboard typing, mouse motion, clicks, scrolling & hardware IOHIDSystem.
    func currentActivity() -> ActivitySnapshot {
        let tKeyDown = Double(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown))
        let tKeyUp = Double(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyUp))
        let tFlags = Double(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .flagsChanged))
        let typing = min(tKeyDown, min(tKeyUp, tFlags))

        let mouse = Double(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved))

        let tLDown = Double(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown))
        let tLUp = Double(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseUp))
        let tRDown = Double(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .rightMouseDown))
        let click = min(tLDown, min(tLUp, tRDown))

        let scroll = Double(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel))
        let hw = getIOHIDIdle()

        let minIdle = min(hw, min(typing, min(mouse, min(click, scroll))))

        let desc: String
        let kind: String
        if typing <= minIdle + 0.15 {
            desc = "typing (\(String(format: "%.1f", typing))s ago)"
            kind = "typing"
        } else if mouse <= minIdle + 0.15 {
            desc = "mouse (\(String(format: "%.1f", mouse))s ago)"
            kind = "mouse"
        } else if click <= minIdle + 0.15 {
            desc = "click (\(String(format: "%.1f", click))s ago)"
            kind = "click"
        } else if scroll <= minIdle + 0.15 {
            desc = "scroll (\(String(format: "%.1f", scroll))s ago)"
            kind = "scroll"
        } else {
            desc = "system input (\(String(format: "%.1f", hw))s ago)"
            kind = "system"
        }

        return ActivitySnapshot(idleSeconds: minIdle,
                                lastActionKind: kind,
                                lastActionDescription: desc,
                                typingIdle: typing,
                                mouseIdle: mouse,
                                clickIdle: click,
                                scrollIdle: scroll,
                                hardwareIdle: hw)
    }

    func secondsSinceInput() -> Double {
        return currentActivity().idleSeconds
    }

    /// Posts genuine mouse moved event to WindowServer & event tap, then warps hardware position.
    private func postCursor(at p: CGPoint) {
        if let ev = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                            mouseCursorPosition: p, mouseButton: .left) {
            ev.post(tap: .cghidEventTap)
        }
        CGWarpMouseCursorPosition(p)
    }

    /// Injects a safe non-character virtual key (F15) to register genuine keyboard activity for telemetry.
    private func postHarmlessKeystroke() {
        if let kdown = CGEvent(keyboardEventSource: nil, virtualKey: 113, keyDown: true),
           let kup = CGEvent(keyboardEventSource: nil, virtualKey: 113, keyDown: false) {
            kdown.post(tap: .cghidEventTap)
            kup.post(tap: .cghidEventTap)
        }
    }

    /// Performs a micro-scroll down and up (1 notch) so ScreenCaptureKit registers desktop visual change.
    private func postMicroScroll() {
        if let down = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0),
           let up = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0) {
            down.post(tap: .cghidEventTap)
            usleep(25000)
            up.post(tap: .cghidEventTap)
        }
    }

    private func performSlide(from start: CGPoint, distance: CGFloat, bounds: CGRect) {
        let steps = 30
        let delayUs: useconds_t = 15000
        for i in 0...steps {
            let progress = Double(i) / Double(steps)
            let offset = CGFloat(sin(progress * 2.0 * .pi) * Double(distance))
            let x = min(max(start.x + offset, bounds.minX + 8), bounds.maxX - 8)
            let p = CGPoint(x: x, y: start.y)
            postCursor(at: p)
            usleep(delayUs)
        }
    }

    private func performWiggle(from start: CGPoint, distance: CGFloat, bounds: CGRect) {
        let steps = 32
        let delayUs: useconds_t = 15000
        for i in 0...steps {
            let progress = Double(i) / Double(steps)
            let offset = CGFloat(sin(progress * 4.0 * .pi) * Double(distance))
            let x = min(max(start.x + offset, bounds.minX + 8), bounds.maxX - 8)
            let p = CGPoint(x: x, y: start.y)
            postCursor(at: p)
            usleep(delayUs)
        }
    }

    private func performCircle(from start: CGPoint, radius: CGFloat, bounds: CGRect) {
        let steps = 32
        let delayUs: useconds_t = 16000
        let goDown = (start.y - 2 * radius < bounds.minY + 8)
        let cy = goDown ? (start.y + radius) : (start.y - radius)
        let sign: CGFloat = goDown ? -1.0 : 1.0
        for i in 0...steps {
            let angle = (Double(i) / Double(steps)) * 2.0 * .pi
            let x = min(max(start.x + radius * CGFloat(sin(angle)), bounds.minX + 8), bounds.maxX - 8)
            let y = min(max(cy + sign * radius * CGFloat(cos(angle)), bounds.minY + 8), bounds.maxY - 8)
            let p = CGPoint(x: x, y: y)
            postCursor(at: p)
            usleep(delayUs)
        }
    }

    private func performRoam(from start: CGPoint, step: Int, bounds: CGRect) {
        let sa = sin(Double(step) * 12.9898) * 43758.5453
        let sb = sin(Double(step) * 78.233) * 12345.6789
        let fx = 0.25 + 0.5 * (sa - floor(sa))
        let fy = 0.25 + 0.5 * (sb - floor(sb))
        let target = CGPoint(x: bounds.minX + bounds.width * fx,
                             y: bounds.minY + bounds.height * fy)
        let steps = 32
        let delayUs: useconds_t = 16000
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let ease = t * t * (3 - 2 * t)
            let x = start.x + (target.x - start.x) * CGFloat(ease)
            let y = start.y + (target.y - start.y) * CGFloat(ease)
            postCursor(at: CGPoint(x: x, y: y))
            usleep(delayUs)
        }
    }

    private func performJitter(from start: CGPoint, bounds: CGRect) {
        let dx: CGFloat = (start.x + 1 < bounds.maxX - 8) ? 1.0 : -1.0
        postCursor(at: CGPoint(x: start.x + dx, y: start.y))
        usleep(25000)
        postCursor(at: start)
    }

    private func performWarp(from start: CGPoint, distance: CGFloat, bounds: CGRect) {
        let dx: CGFloat = (start.x + distance < bounds.maxX - 8) ? distance : -distance
        CGWarpMouseCursorPosition(CGPoint(x: start.x + dx, y: start.y))
        usleep(35000)
        CGWarpMouseCursorPosition(start)
    }

    private func performScroll(lines: Int) {
        let count = max(1, abs(lines))
        for _ in 0..<count {
            // In macOS CoreGraphics: negative wheel1 indicates scrolling down.
            if let ev = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                wheelCount: 1, wheel1: -1,
                                wheel2: 0, wheel3: 0) {
                // Also set continuous pixel delta for modern scroll views (browsers, Electron, Cocoa)
                ev.setIntegerValueField(CGEventField(rawValue: 99)!, value: -25)
                ev.post(tap: .cghidEventTap)
            }
            usleep(18000)
        }
    }

    func nudge() {
        let s = Settings.shared
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let here = currentLocation()
        step += 1
        let currentStep = step

        let activeMode = s.mode

        // Apply natural human distance variation
        let jitterFactor = s.humanJitter ? (0.85 + Double.random(in: 0...0.30)) : 1.0
        let baseDist = CGFloat(s.distance * jitterFactor)

        let effectiveDistance: CGFloat = (activeMode == .jitter) ? 1.0 : baseDist

        if activeMode == .scroll {
            performScroll(lines: s.scrollLines)
            postHarmlessKeystroke()
            return
        }

        if activeMode == .warp {
            performWarp(from: here, distance: effectiveDistance, bounds: bounds)
            postHarmlessKeystroke()
            return
        }

        if activeMode == .jitter {
            performJitter(from: here, bounds: bounds)
            postHarmlessKeystroke()
            return
        }

        animQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isAnimating else { return }
            self.isAnimating = true
            defer { self.isAnimating = false }

            switch activeMode {
            case .slide:
                self.performSlide(from: here, distance: effectiveDistance, bounds: bounds)
            case .wiggle:
                self.performWiggle(from: here, distance: effectiveDistance, bounds: bounds)
            case .circle:
                self.performCircle(from: here, radius: effectiveDistance, bounds: bounds)
            case .roam:
                self.performRoam(from: here, step: currentStep, bounds: bounds)
            default:
                self.performSlide(from: here, distance: effectiveDistance, bounds: bounds)
            }

            self.postHarmlessKeystroke()
        }
    }

    func click(at p: CGPoint) {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                 mouseCursorPosition: p, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                               mouseCursorPosition: p, mouseButton: .left) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

// MARK: - Menu Bar Controller

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var clickTimer: Timer?
    private var nudgeCount = 0
    private var skipCount = 0
    private var clickCount = 0
    private var lastNudgeAt: Date?
    private var appNapActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Block App Nap from coalescing or delaying background timers
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Keep Awake anti-AFK timers"
        )

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        rebuildMenu()
        scheduleNextTick()
        startClickTimer()

        Settings.shared.applySleepAssertion()
        if Settings.shared.launchAtLogin { Settings.shared.applyLaunchAtLogin() }

        let opts: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let isTrusted = AXIsProcessTrustedWithOptions(opts)
        Log.write("launched v1.4.2 — mode=\(Settings.shared.modeRaw) interval=\(Settings.shared.interval)s onlyWhenIdle=\(Settings.shared.onlyWhenIdle) jitter=\(Settings.shared.humanJitter) distance=\(Settings.shared.distance)pt preventSleep=\(Settings.shared.preventSleep) axTrusted=\(isTrusted)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Settings.shared.enabled = false
        if let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
        }
    }

    // MARK: icon

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let on = Settings.shared.enabled
        if let img = NSImage(systemSymbolName: on ? "cup.and.saucer.fill" : "cup.and.saucer",
                             accessibilityDescription: "Keep Awake") {
            img.isTemplate = true
            button.image = img
        } else {
            button.title = on ? "☕️" : "💤"
        }
        button.toolTip = on ? "Keep Awake — ON (Anti-AFK active across all modes)"
                            : "Keep Awake — OFF (cursor untouched)"
    }

    // MARK: Menu

    private func rebuildMenu() {
        let s = Settings.shared
        let menu = NSMenu()

        let header = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if !AXIsProcessTrusted() {
            let permItem = NSMenuItem(title: "⚠️ Grant Accessibility Permission...", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            permItem.target = self
            menu.addItem(permItem)
            menu.addItem(.separator())
        }

        let toggle = NSMenuItem(title: s.enabled ? "Nudging: ON" : "Nudging: OFF",
                                action: #selector(toggleEnabled), keyEquivalent: "p")
        toggle.target = self
        toggle.state = s.enabled ? .on : .off
        menu.addItem(toggle)

        menu.addItem(.separator())

        // Interval submenu
        let intervalItem = NSMenuItem(title: "Interval", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()
        for secs: Double in [5, 10, 15, 20, 30, 45, 60, 120] {
            let title = "\(Int(secs)) seconds"
            let mi = NSMenuItem(title: title, action: #selector(pickInterval(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = secs
            mi.state = (abs(s.interval - secs) < 0.01) ? .on : .off
            intervalMenu.addItem(mi)
        }
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        // Movement mode submenu
        let modeItem = NSMenuItem(title: "Movement", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for m in Settings.Mode.allCases {
            let mi = NSMenuItem(title: m.rawValue, action: #selector(pickMode(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = m.rawValue
            mi.state = (s.mode == m) ? .on : .off
            modeMenu.addItem(mi)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        // Distance submenu
        let distItem = NSMenuItem(title: "Distance", action: nil, keyEquivalent: "")
        let distMenu = NSMenu()
        for (label, pts) in [("Subtle (15 pt)", 15.0),
                             ("Normal (35 pt)", 35.0),
                             ("Large (60 pt)", 60.0),
                             ("Extra large (100 pt)", 100.0)] {
            let mi = NSMenuItem(title: label, action: #selector(pickDistance(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = pts
            mi.state = (abs(s.distance - pts) < 1.0) ? .on : .off
            distMenu.addItem(mi)
        }
        distItem.submenu = distMenu
        menu.addItem(distItem)

        // Scroll amount (if scroll mode)
        if s.mode == .scroll {
            let scrollItem = NSMenuItem(title: "Scroll amount", action: nil, keyEquivalent: "")
            let scrollMenu = NSMenu()
            for n in [1, 3, 5, 10, 20] {
                let mi = NSMenuItem(title: n == 1 ? "1 line per interval" : "\(n) lines per interval",
                                    action: #selector(pickScrollLines(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = n
                mi.state = (s.scrollLines == n) ? .on : .off
                scrollMenu.addItem(mi)
            }
            scrollItem.submenu = scrollMenu
            menu.addItem(scrollItem)
        }

        // Timing variance toggle
        let jitterItem = NSMenuItem(title: "Natural timing variation (±15%)",
                                    action: #selector(toggleJitter), keyEquivalent: "")
        jitterItem.target = self
        jitterItem.state = s.humanJitter ? .on : .off
        menu.addItem(jitterItem)

        // Only when idle (Default OFF: guarantees uninterrupted recording while working with AI)
        let idleItem = NSMenuItem(title: "Only when I'm idle",
                                  action: #selector(toggleIdleOnly), keyEquivalent: "")
        idleItem.target = self
        idleItem.state = s.onlyWhenIdle ? .on : .off
        menu.addItem(idleItem)

        // Prevent Mac display & system sleep
        let sleepItem = NSMenuItem(title: "Prevent Mac from sleeping",
                                   action: #selector(togglePreventSleep), keyEquivalent: "")
        sleepItem.target = self
        sleepItem.state = s.preventSleep ? .on : .off
        menu.addItem(sleepItem)

        menu.addItem(.separator())

        // Auto-click channel
        let clickToggle = NSMenuItem(title: s.autoClick ? "Auto-click: ON" : "Auto-click: OFF",
                                     action: #selector(toggleAutoClick), keyEquivalent: "")
        clickToggle.target = self
        clickToggle.state = s.autoClick ? .on : .off
        menu.addItem(clickToggle)

        if s.autoClick {
            let ciItem = NSMenuItem(title: "Click interval", action: nil, keyEquivalent: "")
            let ciMenu = NSMenu()
            for secs: Double in [2, 5, 10, 30] {
                let mi = NSMenuItem(title: secs == 1 ? "1 second" : "\(Int(secs)) seconds",
                                    action: #selector(pickClickInterval(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = secs
                mi.state = (abs(s.clickInterval - secs) < 0.01) ? .on : .off
                ciMenu.addItem(mi)
            }
            ciItem.submenu = ciMenu
            menu.addItem(ciItem)

            let atItem = NSMenuItem(title: s.clickAtSavedPoint ? "Click at: saved point" : "Click at: cursor",
                                    action: #selector(toggleClickTarget), keyEquivalent: "")
            atItem.target = self
            if s.clickAtSavedPoint && !s.hasClickPoint { atItem.title = "Click at: saved point (NOT SET!)" }
            menu.addItem(atItem)

            let setPoint = NSMenuItem(title: "Save cursor position as click point",
                                      action: #selector(saveClickPoint), keyEquivalent: "")
            setPoint.target = self
            menu.addItem(setPoint)
        }

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Start at login",
                                   action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = s.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        let nudgeNowItem = NSMenuItem(title: "Nudge now", action: #selector(nudgeNow), keyEquivalent: "n")
        nudgeNowItem.target = self
        menu.addItem(nudgeNowItem)

        let diag = NSMenuItem(title: "Why am I still AFK? Run diagnostics…",
                              action: #selector(runDiagnostics), keyEquivalent: "d")
        diag.target = self
        menu.addItem(diag)

        let reset = NSMenuItem(title: "Reset settings to defaults",
                               action: #selector(resetSettings), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Keep Awake", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        menu.delegate = self
    }

    private func statusLine() -> String {
        let s = Settings.shared
        if !s.enabled { return "Keep Awake — OFF (cursor untouched)" }
        let act = CursorNudger.shared.currentActivity()
        let last = lastNudgeAt.map { fmt($0) } ?? "—"
        var line = "Keep Awake — ON · idle \(Int(act.idleSeconds))s (\(act.lastActionKind)) · \(nudgeCount) nudges"
        if s.autoClick { line += " · \(clickCount) clicks" }
        line += " · last \(last)"
        return line
    }

    private func fmt(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    // MARK: Timers

    private func scheduleNextTick() {
        timer?.invalidate()
        let s = Settings.shared
        let base = max(2.0, s.interval)
        let actual = s.humanJitter ? (base * (0.85 + Double.random(in: 0...0.30))) : base
        let t = Timer(timeInterval: actual, repeats: false) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func startClickTimer() {
        clickTimer?.invalidate()
        clickTimer = nil
        guard Settings.shared.autoClick else { return }
        let iv = max(1.0, Settings.shared.clickInterval)
        let t = Timer(timeInterval: iv, repeats: true) { [weak self] _ in self?.clickTick() }
        t.tolerance = max(0.05, iv * 0.1)
        RunLoop.main.add(t, forMode: .common)
        clickTimer = t
    }

    private func tick() {
        let s = Settings.shared
        guard s.enabled else { return }
        if s.onlyWhenIdle {
            let act = CursorNudger.shared.currentActivity()
            if act.idleSeconds < s.idleThreshold {
                skipCount += 1
                Log.write("skipped: user active (\(act.lastActionDescription) < threshold \(Int(s.idleThreshold))s)")
                scheduleNextTick()
                return
            }
        }
        CursorNudger.shared.nudge()
        nudgeCount += 1
        lastNudgeAt = Date()
        Log.write("nudge #\(nudgeCount) mode=\(s.modeRaw)")
        scheduleNextTick()
    }

    private func clickTick() {
        let s = Settings.shared
        guard s.enabled, s.autoClick else { return }
        if s.onlyWhenIdle {
            let idle = CursorNudger.shared.secondsSinceInput()
            guard idle >= s.idleThreshold else { return }
        }
        let p: CGPoint
        if s.clickAtSavedPoint {
            guard s.hasClickPoint else {
                Log.write("click skipped: saved point not set")
                return
            }
            p = CGPoint(x: s.clickPointX, y: s.clickPointY)
        } else {
            p = CursorNudger.shared.currentLocation()
        }
        CursorNudger.shared.click(at: p)
        clickCount += 1
        Log.write("click #\(clickCount) at \(Int(p.x)),\(Int(p.y))")
    }

    // MARK: Actions

    @objc private func toggleEnabled() {
        Settings.shared.enabled.toggle()
        Log.write("toggled -> \(Settings.shared.enabled ? "ON" : "OFF")")
        updateStatusIcon()
        scheduleNextTick()
        rebuildMenu()
    }

    @objc private func pickInterval(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        Settings.shared.interval = v
        scheduleNextTick()
        rebuildMenu()
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        Settings.shared.modeRaw = raw
        Log.write("mode -> \(raw)")
        rebuildMenu()
    }

    @objc private func pickDistance(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? Double else { return }
        Settings.shared.distance = d
        Log.write("distance -> \(Int(d))pt")
        rebuildMenu()
    }

    @objc private func pickScrollLines(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? Int else { return }
        Settings.shared.scrollLines = n
        rebuildMenu()
    }

    @objc private func toggleJitter() {
        Settings.shared.humanJitter.toggle()
        scheduleNextTick()
        rebuildMenu()
    }

    @objc private func toggleIdleOnly() {
        Settings.shared.onlyWhenIdle.toggle()
        rebuildMenu()
    }

    @objc private func togglePreventSleep() {
        Settings.shared.preventSleep.toggle()
        rebuildMenu()
    }

    @objc private func toggleAutoClick() {
        Settings.shared.autoClick.toggle()
        Log.write("auto-click -> \(Settings.shared.autoClick ? "ON" : "OFF")")
        startClickTimer()
        rebuildMenu()
    }

    @objc private func pickClickInterval(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        Settings.shared.clickInterval = v
        startClickTimer()
        rebuildMenu()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleClickTarget() {
        Settings.shared.clickAtSavedPoint.toggle()
        rebuildMenu()
    }

    @objc private func saveClickPoint() {
        let p = CursorNudger.shared.currentLocation()
        Settings.shared.clickPointX = Double(p.x)
        Settings.shared.clickPointY = Double(p.y)
        Settings.shared.hasClickPoint = true
        Log.write("click point saved at \(Int(p.x)),\(Int(p.y))")
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        Settings.shared.launchAtLogin.toggle()
        Log.write("start-at-login -> \(Settings.shared.launchAtLogin ? "ON" : "OFF")")
        rebuildMenu()
    }

    @objc private func nudgeNow() {
        CursorNudger.shared.nudge()
        nudgeCount += 1
        lastNudgeAt = Date()
        Log.write("nudge now (#\(nudgeCount)) mode=\(Settings.shared.modeRaw)")
        rebuildMenu()
    }

    @objc private func resetSettings() {
        Settings.shared.resetToDefaults()
        scheduleNextTick()
        startClickTimer()
        updateStatusIcon()
        rebuildMenu()
        Log.write("settings reset to defaults")
    }

    @objc private func runDiagnostics() {
        let n = CursorNudger.shared
        let beforeAct = n.currentActivity()
        n.nudge()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            let afterAct = n.currentActivity()
            let s = Settings.shared
            var m = "=== KEEP AWAKE DIAGNOSTICS ===\n\n"
            m += "Activity Breakdown (Seconds Since Last Action):\n"
            m += "  • Keyboard Typing: \(String(format: "%.1f", afterAct.typingIdle))s\n"
            m += "  • Mouse Movement: \(String(format: "%.1f", afterAct.mouseIdle))s\n"
            m += "  • Mouse Clicks:   \(String(format: "%.1f", afterAct.clickIdle))s\n"
            m += "  • Mouse Scrolling: \(String(format: "%.1f", afterAct.scrollIdle))s\n"
            m += "  • Hardware IOHID:  \(String(format: "%.1f", afterAct.hardwareIdle))s\n\n"
            m += "Before Test Nudge: \(beforeAct.lastActionDescription)\n"
            m += "Current Detected Action: \(afterAct.lastActionDescription)\n"
            m += "Overall Idle Time: \(String(format: "%.1f", afterAct.idleSeconds))s (Threshold: \(Int(s.idleThreshold))s)\n\n"
            m += "Configuration:\n"
            m += "  • Active Mode: \(s.mode.rawValue) (with full anti-AFK protection)\n"
            m += "  • Interval: \(Int(s.interval))s (Jitter: \(s.humanJitter ? "Enabled ±15%" : "Disabled"))\n"
            m += "  • Sleep Assertion: \(s.preventSleep ? "ACTIVE (Display & System)" : "Disabled")\n"
            m += "  • Total Nudges: \(self.nudgeCount) | Skipped: \(self.skipCount)\n\n"
            if afterAct.idleSeconds < 1.5 || afterAct.hardwareIdle < 1.0 {
                m += "✅ AFK Protection Active: Hardware & system idle timers successfully reset on every nudge across all modes.\n"
            } else {
                m += "⚠️ Notice: Check Accessibility permissions if idle counter did not reset.\n"
            }
            let a = NSAlert()
            a.messageText = "Keep Awake Diagnostics"
            a.informativeText = m
            a.alertStyle = .informational
            a.runModal()
            Log.write("diagnostics: minIdle=\(afterAct.idleSeconds) lastAction=\(afterAct.lastActionDescription) nudges=\(self.nudgeCount)")
        }
    }

    @objc private func quit() {
        timer?.invalidate()
        clickTimer?.invalidate()
        Settings.shared.enabled = false
        if let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
        }
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if let first = menu.items.first {
            first.title = statusLine()
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
