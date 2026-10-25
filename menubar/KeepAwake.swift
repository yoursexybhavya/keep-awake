//
//  KeepAwake.swift — menu-bar anti-AFK cursor nudger for macOS.
//
//  Single-file Swift app. No Xcode project, no dependencies, no App Store.
//  Build:  ./menubar/build.sh        (or see README)
//
//  Lives in your menu bar as a cup icon. Moves the cursor a tiny amount on a
//  timer so presence / idle watchers (Teams, Slack, Zoom, corporate agents)
//  never mark you AFK. Pauses automatically while you are actually using the
//  Mac, so it never fights your own mouse.
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
    }

    @objc dynamic var enabled: Bool = true { didSet { save() } }
    @objc dynamic var interval: Double = 30 { didSet { save() } }
    @objc dynamic var onlyWhenIdle: Bool = true { didSet { save() } }
    @objc dynamic var idleThreshold: Double = 5 { didSet { save() } }
    @objc dynamic var distance: Double = 1 { didSet { save() } }
    @objc dynamic var launchAtLogin: Bool = false { didSet { applyLaunchAtLogin(); save() } }
    @objc dynamic var modeRaw: String = Mode.jitter.rawValue { didSet { save() } }

    var mode: Mode { Mode(rawValue: modeRaw) ?? .jitter }

    private let defaults = UserDefaults.standard

    private init() { load() }

    private func load() {
        if defaults.object(forKey: "enabled") != nil { enabled = defaults.bool(forKey: "enabled") }
        if defaults.object(forKey: "interval") != nil { interval = defaults.double(forKey: "interval") }
        if defaults.object(forKey: "onlyWhenIdle") != nil { onlyWhenIdle = defaults.bool(forKey: "onlyWhenIdle") }
        if defaults.object(forKey: "idleThreshold") != nil { idleThreshold = defaults.double(forKey: "idleThreshold") }
        if defaults.object(forKey: "distance") != nil { distance = defaults.double(forKey: "distance") }
        if defaults.object(forKey: "launchAtLogin") != nil { launchAtLogin = defaults.bool(forKey: "launchAtLogin") }
        if let raw = defaults.string(forKey: "mode"), Mode(rawValue: raw) != nil { modeRaw = raw }
    }

    private func save() {
        defaults.set(enabled, forKey: "enabled")
        defaults.set(interval, forKey: "interval")
        defaults.set(onlyWhenIdle, forKey: "onlyWhenIdle")
        defaults.set(idleThreshold, forKey: "idleThreshold")
        defaults.set(distance, forKey: "distance")
        defaults.set(launchAtLogin, forKey: "launchAtLogin")
        defaults.set(modeRaw, forKey: "mode")
    }

    private func applyLaunchAtLogin() {
        // Uses SMAppService on macOS 13+. Falls back to a plain LaunchAgent.
        if #available(macOS 13.0, *) {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("KeepAwake: login-item toggle failed: \(error)")
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

    func screenSize() -> CGSize {
        CGDisplayBounds(CGMainDisplayID()).size
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
}

// MARK: - Menu bar controller

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var nudgeCount = 0
    private var lastNudgeAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "cup.and.saucer.fill",
                                 accessibilityDescription: "Keep Awake") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "☕️"
            }
            button.toolTip = "Keep Awake — anti-AFK cursor nudger"
        }
        rebuildMenu()
        startTimer()
    }

    // MARK: Menu

    private func rebuildMenu() {
        let s = Settings.shared
        let menu = NSMenu()

        let header = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: s.enabled ? "Pause nudging" : "Resume nudging",
                                action: #selector(toggleEnabled), keyEquivalent: "p")
        toggle.target = self
        toggle.state = s.enabled ? .on : .off
        menu.addItem(toggle)

        menu.addItem(.separator())

        // Interval submenu
        let intervalItem = NSMenuItem(title: "Interval", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()
        for secs: Double in [10, 15, 20, 30, 45, 60, 120] {
            let mi = NSMenuItem(title: "\(Int(secs)) seconds",
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

        // Only-when-idle
        let idleItem = NSMenuItem(title: "Only when I'm idle",
                                  action: #selector(toggleIdleOnly), keyEquivalent: "")
        idleItem.target = self
        idleItem.state = s.onlyWhenIdle ? .on : .off
        menu.addItem(idleItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Start at login",
                                   action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = s.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem(title: "Nudge now", action: #selector(nudgeNow), keyEquivalent: "n"))
        menu.items.last?.target = self

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Keep Awake", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        menu.delegate = self
    }

    private func statusLine() -> String {
        let s = Settings.shared
        if !s.enabled { return "Keep Awake — paused" }
        let idle = CursorNudger.shared.secondsSinceInput()
        let count = nudgeCount
        let last = lastNudgeAt.map { fmt($0) } ?? "—"
        return "Keep Awake — active\nidle \(Int(idle))s · \(count) nudges · last \(last)"
    }

    private func fmt(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    // MARK: Timer

    private func startTimer() {
        timer?.invalidate()
        let iv = max(1.0, Settings.shared.interval)
        let t = Timer(timeInterval: iv, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 1.0
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let s = Settings.shared
        guard s.enabled else { return }
        if s.onlyWhenIdle {
            let idle = CursorNudger.shared.secondsSinceInput()
            guard idle >= s.idleThreshold else { return }   // user is active, don't interfere
        }
        CursorNudger.shared.nudge()
        nudgeCount += 1
        lastNudgeAt = Date()
    }

    // MARK: Actions

    @objc private func toggleEnabled() {
        Settings.shared.enabled.toggle()
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
        rebuildMenu()
    }

    @objc private func toggleIdleOnly() {
        Settings.shared.onlyWhenIdle.toggle()
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        Settings.shared.launchAtLogin.toggle()
        rebuildMenu()
    }

    @objc private func nudgeNow() {
        CursorNudger.shared.nudge()
        nudgeCount += 1
        lastNudgeAt = Date()
        rebuildMenu()
    }

    @objc private func quit() {
        timer?.invalidate()
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
