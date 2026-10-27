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
//  v1.3: visible-by-default movement, auto-click channel, scroll channel,
//        start-at-login LaunchAgent fallback, on-disk log, AFK diagnostics.
//

import Cocoa
import CoreGraphics
import ServiceManagement

// MARK: - Settings

final class Settings {
    static let shared = Settings()

    enum Mode: String, CaseIterable {
        case jitter = "Jitter (invisible, 1 px)"
        case circle = "Tiny circle"
        case wiggle = "Visible wiggle"
        case roam   = "Roam the screen"
        case warp   = "Silent reposition (no event)"
        case scroll = "Scroll wheel down"
    }

    @objc dynamic var enabled: Bool = true { didSet { save() } }
    @objc dynamic var interval: Double = 30 { didSet { save() } }
    @objc dynamic var onlyWhenIdle: Bool = true { didSet { save() } }
    @objc dynamic var idleThreshold: Double = 5 { didSet { save() } }
    @objc dynamic var distance: Double = 12 { didSet { save() } }
    @objc dynamic var scrollLines: Int = 3 { didSet { save() } }
    @objc dynamic var launchAtLogin: Bool = false { didSet { applyLaunchAtLogin(); save() } }
    @objc dynamic var modeRaw: String = Mode.wiggle.rawValue { didSet { save() } }

    // Auto-click channel
    @objc dynamic var autoClick: Bool = false { didSet { save() } }
    @objc dynamic var clickInterval: Double = 5 { didSet { save() } }
    @objc dynamic var clickAtSavedPoint: Bool = false { didSet { save() } }
    @objc dynamic var hasClickPoint: Bool = false { didSet { save() } }
    @objc dynamic var clickPointX: Double = 0 { didSet { save() } }
    @objc dynamic var clickPointY: Double = 0 { didSet { save() } }

    var mode: Mode { Mode(rawValue: modeRaw) ?? .wiggle }

    private let defaults = UserDefaults.standard

    private init() { load() }

    private func load() {
        if defaults.object(forKey: "enabled") != nil { enabled = defaults.bool(forKey: "enabled") }
        if defaults.object(forKey: "interval") != nil { interval = defaults.double(forKey: "interval") }
        if defaults.object(forKey: "onlyWhenIdle") != nil { onlyWhenIdle = defaults.bool(forKey: "onlyWhenIdle") }
        if defaults.object(forKey: "idleThreshold") != nil { idleThreshold = defaults.double(forKey: "idleThreshold") }
        if defaults.object(forKey: "distance") != nil { distance = defaults.double(forKey: "distance") }
        if defaults.object(forKey: "scrollLines") != nil { scrollLines = defaults.integer(forKey: "scrollLines") }
        if defaults.object(forKey: "launchAtLogin") != nil { launchAtLogin = defaults.bool(forKey: "launchAtLogin") }
        if let raw = defaults.string(forKey: "mode"), Mode(rawValue: raw) != nil { modeRaw = raw }
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
                  "scrollLines", "mode", "autoClick", "clickInterval",
                  "clickAtSavedPoint", "hasClickPoint", "clickPointX", "clickPointY"] {
            defaults.removeObject(forKey: k)
        }
        enabled = true; interval = 30; onlyWhenIdle = true; idleThreshold = 5
        distance = 12; scrollLines = 3; modeRaw = Mode.wiggle.rawValue
        autoClick = false; clickInterval = 5; clickAtSavedPoint = false
        hasClickPoint = false; clickPointX = 0; clickPointY = 0
        launchAtLogin = keepLogin
        save()
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
    private var origin: CGPoint?

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

    func nudge() {
        let s = Settings.shared
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let here = currentLocation()
        step += 1

        var target = here

        switch s.mode {
        case .jitter:
            let dx = (step % 2 == 0) ? s.distance : -s.distance
            target = CGPoint(x: here.x + dx, y: here.y)

        case .circle:
            if origin == nil { origin = here }
            let o = origin!
            let a = Double(step % 36) * (2 * .pi / 36)
            target = CGPoint(x: o.x + s.distance * cos(a), y: o.y + s.distance * sin(a))

        case .wiggle:
            if origin == nil { origin = here }
            let o = origin!
            let phase = step % 3
            let dx: Double = phase == 0 ? s.distance : (phase == 1 ? -s.distance : 0)
            target = CGPoint(x: o.x + dx, y: o.y)
            if phase == 2 { origin = nil }

        case .roam:
            let sa = sin(Double(step) * 12.9898) * 43758.5453
            let sb = sin(Double(step) * 78.233) * 12345.6789
            let fx = 0.25 + 0.5 * (sa - floor(sa))
            let fy = 0.25 + 0.5 * (sb - floor(sb))
            target = CGPoint(x: bounds.minX + bounds.width * fx,
                             y: bounds.minY + bounds.height * fy)

        case .warp:
            let dx = (step % 2 == 0) ? s.distance : -s.distance
            CGWarpMouseCursorPosition(CGPoint(x: here.x + dx, y: here.y))
            return

        case .scroll:
            // A genuine wheel event — exactly what the middle button produces.
            // Scrolls whatever window is under the cursor, once per interval.
            if let ev = CGEvent(scrollWheelEventSource: nil, units: .line,
                                wheelCount: 1, wheel1: Int32(s.scrollLines),
                                wheel2: 0, wheel3: 0) {
                ev.post(tap: .cghidEventTap)
            }
            return
        }

        // Keep it on screen with a small margin.
        let m: CGFloat = 12
        target.x = min(max(target.x, bounds.minX + m), bounds.maxX - m)
        target.y = min(max(target.y, bounds.minY + m), bounds.maxY - m)

        if let ev = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                            mouseCursorPosition: target, mouseButton: .left) {
            ev.post(tap: .cghidEventTap)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        rebuildMenu()
        startTimer()
        startClickTimer()

        // Re-assert the login item in case a macOS update dropped it.
        if Settings.shared.launchAtLogin { Settings.shared.applyLaunchAtLogin() }

        Log.write("launched v1.3 — mode=\(Settings.shared.modeRaw) interval=\(Settings.shared.interval)s autoClick=\(Settings.shared.autoClick)")
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

        // Mode submenu
        let modeItem = NSMenuItem(title: "Movement", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for m in Settings.Mode.allCases {
            let mi = NSMenuItem(title: m.rawValue, action: #selector(pickMode(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = m.rawValue
            mi.state = (s.modeRaw == m.rawValue) ? .on : .off
            modeMenu.addItem(mi)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

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

        // Only-when-idle
        let idleItem = NSMenuItem(title: "Only when I'm idle",
                                  action: #selector(toggleIdleOnly), keyEquivalent: "")
        idleItem.target = self
        idleItem.state = s.onlyWhenIdle ? .on : .off
        menu.addItem(idleItem)

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

        menu.addItem(NSMenuItem(title: "Nudge now", action: #selector(nudgeNow), keyEquivalent: "n"))
        menu.items.last?.target = self

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

    @objc private func pickScrollLines(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? Int else { return }
        Settings.shared.scrollLines = n
        rebuildMenu()
    }

    @objc private func toggleIdleOnly() {
        Settings.shared.onlyWhenIdle.toggle()
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
        CursorNudger.shared.nudge()
        nudgeCount += 1
        lastNudgeAt = Date()
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
        n.nudge()                                   // force one real nudge
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            let after = n.secondsSinceInput()
            let s = Settings.shared
            var m = "Nudges posted: \(self.nudgeCount)   Skipped (you were active): \(self.skipCount)\n"
            m += "Auto-clicks posted: \(self.clickCount)\n"
            m += "System idle BEFORE test nudge: \(String(format: "%.1f", before))s\n"
            m += "System idle 0.6s AFTER test nudge: \(String(format: "%.1f", after))s\n\n"
            if after < before || after < 1.0 {
                m += "✅ macOS accepts the injected input — the system idle timer resets.\n"
            } else {
                m += "❌ The idle timer did NOT reset — something on this Mac blocks synthetic input.\n"
            }
            m += "Movement: \(s.mode.rawValue) · distance \(Int(s.distance))pt · interval \(Int(s.interval))s\n"
            m += "Auto-click: \(s.autoClick ? "ON every \(Int(s.clickInterval))s" : "OFF")\n\n"
            m += "If your AFK app STILL says away while this dialog shows ✅, that app ignores synthetic events (anti-spoofing). Turn ON Auto-click and/or pick Scroll wheel movement — some watchers only accept clicks or wheel input. If it still says away, it tracks screenshots / keystroke content / window focus, which no cursor tool can reset."
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
