//
//  KeepAwake.swift — menu-bar anti-AFK cursor nudger for macOS.
//
//  Single-file Swift app. No Xcode project, no dependencies, no App Store.
//  Build:  ./menubar/build.sh        (or see README)
//
//  Lives in your menu bar as a cup icon. Moves the cursor, turns the scroll
//  wheel and/or clicks on a timer so presence / idle watchers (Teams, Slack,
//  Zoom, corporate agents) never mark you AFK. Pauses automatically while you
//  are actually using the Mac, so it never fights your own mouse.
//
//  v1.3.1: smooth animated slide & wiggle, hardware cursor warping,
//          display sleep prevention assertion, App Nap blocker,
//          movement distance selector, on-disk log, AFK diagnostics.
//

import Cocoa
import CoreGraphics
import ServiceManagement
import IOKit.pwr_mgt

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
    @objc dynamic var interval: Double = 30 { didSet { save() } }
    @objc dynamic var onlyWhenIdle: Bool = true { didSet { save() } }
    @objc dynamic var idleThreshold: Double = 5 { didSet { save() } }
    @objc dynamic var distance: Double = 35 { didSet { save() } }
    @objc dynamic var scrollLines: Int = 3 { didSet { save() } }
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
    private var sleepAssertionID: IOPMAssertionID = 0

    private init() { load() }

    private func load() {
        if defaults.object(forKey: "enabled") != nil { enabled = defaults.bool(forKey: "enabled") }
        if defaults.object(forKey: "interval") != nil { interval = defaults.double(forKey: "interval") }
        if defaults.object(forKey: "onlyWhenIdle") != nil { onlyWhenIdle = defaults.bool(forKey: "onlyWhenIdle") }
        if defaults.object(forKey: "idleThreshold") != nil { idleThreshold = defaults.double(forKey: "idleThreshold") }
        if defaults.object(forKey: "distance") != nil {
            let d = defaults.double(forKey: "distance")
            distance = d > 0 ? d : 35
        }
        if defaults.object(forKey: "scrollLines") != nil { scrollLines = defaults.integer(forKey: "scrollLines") }
        if defaults.object(forKey: "launchAtLogin") != nil { launchAtLogin = defaults.bool(forKey: "launchAtLogin") }
        if defaults.object(forKey: "preventSleep") != nil { preventSleep = defaults.bool(forKey: "preventSleep") }
        if let raw = defaults.string(forKey: "mode") {
            modeRaw = raw
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
                  "scrollLines", "mode", "preventSleep", "autoClick", "clickInterval",
                  "clickAtSavedPoint", "hasClickPoint", "clickPointX", "clickPointY"] {
            defaults.removeObject(forKey: k)
        }
        enabled = true; interval = 30; onlyWhenIdle = true; idleThreshold = 5
        distance = 35; scrollLines = 3; modeRaw = Mode.slide.rawValue
        preventSleep = true
        autoClick = false; clickInterval = 5; clickAtSavedPoint = false
        hasClickPoint = false; clickPointX = 0; clickPointY = 0
        launchAtLogin = keepLogin
        save()
        applySleepAssertion()
    }

    // MARK: display / system sleep prevention assertion

    func applySleepAssertion() {
        if enabled && preventSleep {
            if sleepAssertionID == 0 {
                let success = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "Keep Awake Display Sleep Prevention" as CFString,
                    &sleepAssertionID
                )
                if success == kIOReturnSuccess {
                    Log.write("display sleep prevention acquired (ID: \(sleepAssertionID))")
                } else {
                    sleepAssertionID = 0
                }
            }
        } else {
            if sleepAssertionID != 0 {
                IOPMAssertionRelease(sleepAssertionID)
                Log.write("display sleep prevention released (ID: \(sleepAssertionID))")
                sleepAssertionID = 0
            }
        }
    }

    // MARK: start at login — SMAppService first, LaunchAgent as a fallback
    // that works even for ad-hoc-signed bundles.

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

    /// True when either mechanism is actually in place.
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

// MARK: - Cursor engine

final class CursorNudger {
    private var step = 0
    private var isAnimating = false
    private let animQueue = DispatchQueue(label: "local.keepawake.anim", qos: .userInteractive)

    static let shared = CursorNudger()

    func currentLocation() -> CGPoint {
        let ev = CGEvent(source: nil)
        return ev?.location ?? .zero
    }

    func secondsSinceInput() -> Double {
        // kCGAnyInputEventType == every bit set. Seconds since ANY mouse/keyboard
        // input for the combined session — this is the number presence apps read.
        let anyInput = CGEventType(rawValue: ~CGEventType.RawValue(0))!
        return Double(CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                              eventType: anyInput))
    }

    /// Forcefully updates the hardware cursor position and injects HID mouse-moved event.
    private func postCursor(at p: CGPoint) {
        CGWarpMouseCursorPosition(p)
        if let ev = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                            mouseCursorPosition: p, mouseButton: .left) {
            ev.post(tap: .cghidEventTap)
        }
    }

    /// Smooth horizontal slide that glides right, crosses center to left, and glides back to start.
    private func performSlide(from start: CGPoint, distance: CGFloat, bounds: CGRect) {
        let steps = 24
        let delayUs: useconds_t = 16000 // ~60 fps
        for i in 0...steps {
            let progress = Double(i) / Double(steps)
            let offset = CGFloat(sin(progress * 2.0 * .pi) * Double(distance))
            let x = min(max(start.x + offset, bounds.minX + 8), bounds.maxX - 8)
            let p = CGPoint(x: x, y: start.y)
            postCursor(at: p)
            usleep(delayUs)
        }
    }

    /// Energetic multi-cycle shake animation.
    private func performWiggle(from start: CGPoint, distance: CGFloat, bounds: CGRect) {
        let steps = 16
        let delayUs: useconds_t = 14000
        for i in 0...steps {
            let progress = Double(i) / Double(steps)
            let offset = CGFloat(sin(progress * 4.0 * .pi) * Double(distance))
            let x = min(max(start.x + offset, bounds.minX + 8), bounds.maxX - 8)
            let p = CGPoint(x: x, y: start.y)
            postCursor(at: p)
            usleep(delayUs)
        }
    }

    /// Smooth circular orbit tangent to the starting position.
    private func performCircle(from start: CGPoint, radius: CGFloat, bounds: CGRect) {
        let steps = 24
        let delayUs: useconds_t = 16000
        for i in 0...steps {
            let progress = Double(i) / Double(steps)
            let angle = progress * 2.0 * .pi
            let x = min(max(start.x + radius * CGFloat(sin(angle)), bounds.minX + 8), bounds.maxX - 8)
            let y = min(max(start.y - radius * CGFloat(1 - cos(angle)), bounds.minY + 8), bounds.maxY - 8)
            let p = CGPoint(x: x, y: y)
            postCursor(at: p)
            usleep(delayUs)
        }
    }

    /// Smoothly glides the cursor to a pseudo-random location on screen using smoothstep.
    private func performRoam(from start: CGPoint, step: Int, bounds: CGRect) {
        let sa = sin(Double(step) * 12.9898) * 43758.5453
        let sb = sin(Double(step) * 78.233) * 12345.6789
        let fx = 0.25 + 0.5 * (sa - floor(sa))
        let fy = 0.25 + 0.5 * (sb - floor(sb))
        let target = CGPoint(x: bounds.minX + bounds.width * fx,
                             y: bounds.minY + bounds.height * fy)
        let steps = 24
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

    /// Instantaneous 1-pixel hop.
    private func performJitter(from start: CGPoint, distance: CGFloat, step: Int, bounds: CGRect) {
        let dx = (step % 2 == 0) ? distance : -distance
        let p = CGPoint(x: min(max(start.x + dx, bounds.minX + 8), bounds.maxX - 8), y: start.y)
        postCursor(at: p)
    }

    /// Silent hardware warp without posting HID event.
    private func performWarp(from start: CGPoint, distance: CGFloat, step: Int, bounds: CGRect) {
        let dx = (step % 2 == 0) ? distance : -distance
        let p = CGPoint(x: min(max(start.x + dx, bounds.minX + 8), bounds.maxX - 8), y: start.y)
        CGWarpMouseCursorPosition(p)
    }

    /// Genuine scroll-wheel event.
    private func performScroll(lines: Int) {
        if let ev = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                            wheelCount: 1, wheel1: Int32(lines),
                            wheel2: 0, wheel3: 0) {
            ev.post(tap: .cghidEventTap)
        }
    }

    func nudge(forceVisible: Bool = false) {
        let s = Settings.shared
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let here = currentLocation()
        step += 1
        let currentStep = step

        let activeMode: Settings.Mode
        if forceVisible {
            activeMode = (s.mode == .scroll || s.mode == .jitter || s.mode == .warp) ? .slide : s.mode
        } else {
            activeMode = s.mode
        }

        let baseDist = CGFloat(s.distance)
        let effectiveDistance: CGFloat
        switch activeMode {
        case .slide:
            effectiveDistance = max(baseDist, 35)
        case .wiggle:
            effectiveDistance = max(baseDist, 20)
        case .circle:
            effectiveDistance = max(baseDist, 25)
        case .jitter:
            effectiveDistance = 1
        default:
            effectiveDistance = baseDist
        }

        if activeMode == .scroll {
            performScroll(lines: s.scrollLines)
            return
        }

        if activeMode == .warp {
            performWarp(from: here, distance: effectiveDistance, step: currentStep, bounds: bounds)
            return
        }

        if activeMode == .jitter {
            performJitter(from: here, distance: effectiveDistance, step: currentStep, bounds: bounds)
            return
        }

        // Smooth animated modes run on animQueue so main thread and UI remain 100% responsive
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
                break
            }
        }
    }

    /// Left button down+up at p — identical to a physical click.
    func click(at p: CGPoint) {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                 mouseCursorPosition: p, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                               mouseCursorPosition: p, mouseButton: .left) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

// MARK: - Menu bar controller

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
        // Menu-bar-only app: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)

        // Disable App Nap so background timers are never coalesced or paused
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Keep Awake anti-AFK timers"
        )

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        rebuildMenu()
        startTimer()
        startClickTimer()

        // Apply display/system sleep prevention assertion
        Settings.shared.applySleepAssertion()

        // Re-assert the login item in case a macOS update dropped it.
        if Settings.shared.launchAtLogin { Settings.shared.applyLaunchAtLogin() }

        Log.write("launched v1.3.1 — mode=\(Settings.shared.modeRaw) interval=\(Settings.shared.interval)s distance=\(Settings.shared.distance)pt autoClick=\(Settings.shared.autoClick) preventSleep=\(Settings.shared.preventSleep)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Settings.shared.enabled = false
        if let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
        }
    }

    // MARK: icon

    /// Filled cup = ON, outline cup (or 💤) = OFF, so the state reads at a glance.
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
        button.toolTip = on ? "Keep Awake — ON (nudges while you're idle)"
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

        let toggle = NSMenuItem(title: s.enabled ? "Nudging: ON" : "Nudging: OFF",
                                action: #selector(toggleEnabled), keyEquivalent: "p")
        toggle.target = self
        toggle.state = s.enabled ? .on : .off
        menu.addItem(toggle)

        menu.addItem(.separator())

        // Interval submenu
        let intervalItem = NSMenuItem(title: "Interval", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()
        for secs: Double in [1, 2, 5, 10, 15, 20, 30, 45, 60, 120] {
            let mi = NSMenuItem(title: secs == 1 ? "1 second" : "\(Int(secs)) seconds",
                                action: #selector(pickInterval(_:)), keyEquivalent: "")
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

        // Movement distance submenu
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

        // Scroll amount — only relevant in scroll mode
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

        // Only-when-idle toggle
        let idleItem = NSMenuItem(title: "Only when I'm idle",
                                  action: #selector(toggleIdleOnly), keyEquivalent: "")
        idleItem.target = self
        idleItem.state = s.onlyWhenIdle ? .on : .off
        menu.addItem(idleItem)

        // Prevent Mac display sleep
        let sleepItem = NSMenuItem(title: "Prevent Mac from sleeping",
                                   action: #selector(togglePreventSleep), keyEquivalent: "")
        sleepItem.target = self
        sleepItem.state = s.preventSleep ? .on : .off
        menu.addItem(sleepItem)

        menu.addItem(.separator())

        // ---- Auto-click channel ----
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
        let idle = CursorNudger.shared.secondsSinceInput()
        let last = lastNudgeAt.map { fmt($0) } ?? "—"
        var line = "Keep Awake — ON · idle \(Int(idle))s · \(nudgeCount) nudges"
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

    private func startTimer() {
        timer?.invalidate()
        let iv = max(1.0, Settings.shared.interval)
        let t = Timer(timeInterval: iv, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = max(0.05, iv * 0.1)
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
            let idle = CursorNudger.shared.secondsSinceInput()
            guard idle >= s.idleThreshold else {
                skipCount += 1
                Log.write("skipped: user active (idle \(String(format: "%.1f", idle))s < threshold \(Int(s.idleThreshold))s)")
                return   // user is active, don't interfere
            }
        }
        CursorNudger.shared.nudge()
        nudgeCount += 1
        lastNudgeAt = Date()
        Log.write("nudge #\(nudgeCount) mode=\(s.modeRaw)")
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
        rebuildMenu()
    }

    @objc private func pickInterval(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        Settings.shared.interval = v
        startTimer()
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
        CursorNudger.shared.nudge(forceVisible: true)
        nudgeCount += 1
        lastNudgeAt = Date()
        Log.write("nudge now (#\(nudgeCount)) mode=\(Settings.shared.modeRaw)")
        rebuildMenu()
    }

    @objc private func resetSettings() {
        Settings.shared.resetToDefaults()
        startTimer()
        startClickTimer()
        updateStatusIcon()
        rebuildMenu()
        Log.write("settings reset to defaults")
    }

    @objc private func runDiagnostics() {
        let n = CursorNudger.shared
        let before = n.secondsSinceInput()
        n.nudge(forceVisible: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            let after = n.secondsSinceInput()
            let s = Settings.shared
            var m = "Nudges posted: \(self.nudgeCount)   Skipped (active): \(self.skipCount)\n"
            m += "Auto-clicks posted: \(self.clickCount)\n"
            m += "Display sleep prevention: \(s.preventSleep ? "Active" : "Disabled")\n"
            m += "System idle BEFORE test nudge: \(String(format: "%.1f", before))s\n"
            m += "System idle 0.6s AFTER test nudge: \(String(format: "%.1f", after))s\n\n"
            if after < before || after < 1.0 {
                m += "✅ macOS accepts the injected input — the system idle timer resets.\n"
            } else {
                m += "❌ The idle timer did NOT reset — something on this Mac blocks synthetic input.\n"
            }
            m += "Movement: \(s.mode.rawValue) · distance \(Int(s.distance))pt · interval \(Int(s.interval))s\n"
            m += "Auto-click: \(s.autoClick ? "ON every \(Int(s.clickInterval))s" : "OFF")\n\n"
            m += "Tip: When testing, check that 'Only when I\'m idle' isn\'t pausing movement while you touch the mouse, or use 'Nudge now' (⌘N) to test movement immediately."
            let a = NSAlert()
            a.messageText = "Keep Awake diagnostics"
            a.informativeText = m
            a.alertStyle = .informational
            a.runModal()
            Log.write("diagnostics: before=\(before) after=\(after) nudges=\(self.nudgeCount) skips=\(self.skipCount)")
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

// Keep the status line fresh while the menu is open.
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
