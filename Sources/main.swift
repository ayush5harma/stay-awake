// Stay Awake — a one-click menu-bar toggle for a Mac that must not sleep.
//
// THE OBJECTIVE. A common case this was built for: two Macs sharing one
// display through a KVM switch, each in clamshell mode with the lid closed;
// the host left behind sees "lid closed, no display", sleeps, and kills
// whatever was running while the lock screen engages. ONE CLICK on the cup
// turns this on (2026-09-07; a menu with a toggle item before), and the host
// then stays up AND unlocked through lid, KVM and idle by three means:
//   • `pmset -a disablesleep 1` -- the only thing that stops clamshell sleep
//     itself. Needs root, and sudoers/stay-awake.example in this repo is a
//     NOPASSWD rule for exactly these two command lines, so `sudo -n` runs
//     them silently once that rule is installed (see README.md); without it,
//     -n is REFUSED (not hung) and the administrator-password dialog takes
//     over.
//   • `caffeinate -dimsu -w <our pid>` -- tied to this process by -w, so a
//     relaunch (KeepAlive, a rebuild) can never leave an orphan.
//   • IOPMAssertionDeclareUserActivity every 60 s -- caffeinate keeps the
//     DISPLAY awake, but the screen saver and the lock screen run on the idle
//     timer, which only user activity resets. This is the unlocked half.
//
// THE TRUTH IS pmset's OWN SleepDisabled FLAG, read every 30 s tick and after
// every click: it survives this app restarting (caffeinate and the timer are
// re-attached when the flag is found on), a flag set from a terminal shows
// here, and cancelling the password dialog changes nothing.
//
// One swiftc over one file, ad-hoc signed, run as a KeepAlive LaunchAgent.

import AppKit
import IOKit.pwr_mgt

let bundleID = "local.ayushsharma.stay-awake"

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let menu = NSMenu()
    private var caffeinate: Process?
    private var activity: Timer?
    private var poller: Timer?
    private var since: Date?
    private var on = false
    private var quitting = false   // set by the menu's Quit; a KeepAlive relaunch or the single-instance sweep is not a quit
    private var lastError: String?

    func applicationDidFinishLaunching(_: Notification) {
        // SINGLE INSTANCE: a second copy would put a second cup in the bar.
        let me = ProcessInfo.processInfo.processIdentifier
        for a in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where a.processIdentifier != me { a.terminate() }

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // No menu on the item: with one set, every click opens it. The button
        // gets both mouse buttons and the handler tells them apart.
        if let b = item.button {
            b.target = self
            b.action = #selector(clicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        render()
        poll()
        // .common mode, or the timer freezes exactly while the menu is open.
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common); poller = t
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.poll() }
    }

    // Quit from the menu allows sleep again: `pmset -a disablesleep` is a
    // persistent setting, and a quit that left it on would keep the Mac from
    // sleeping with no cup left in the bar to say so. A relaunch (KeepAlive, a
    // rebuild) keeps the flag, so the state survives the app.
    func applicationWillTerminate(_: Notification) {
        if quitting && on { _ = setSleepDisabled(false, dialog: false) }
        stopCaffeinate(); stopActivity()
    }

    // MARK: pmset

    private func readSleepDisabled() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["-g"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled" { return parts[1] == "1" }
        }
        return false
    }

    // `sudo -n` first: the NOPASSWD rule in sudoers/stay-awake.example (once
    // installed) covers exactly these two command lines and nothing else, and
    // -n makes a missing rule a refusal instead of a hang on a password
    // nobody can type. The administrator dialog is the fallback. False when
    // neither happened -- which includes the person cancelling the dialog
    // (AppleScript -128, not an error).
    private func setSleepDisabled(_ flag: Bool, dialog: Bool = true) -> Bool {
        let arg = flag ? "1" : "0"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", arg]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            if p.terminationStatus == 0 { lastError = nil; return true }
        }
        if !dialog { return false }
        let src = "do shell script \"/usr/bin/pmset -a disablesleep \(arg)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let e = err {
            let code = (e[NSAppleScript.errorNumber] as? Int) ?? 0
            lastError = code == -128 ? nil : ((e[NSAppleScript.errorMessage] as? String) ?? "pmset failed")
            return false
        }
        lastError = nil
        return true
    }

    // MARK: caffeinate + user activity

    private func startCaffeinate() {
        guard caffeinate == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-dimsu", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.caffeinate = nil; self?.render() }
        }
        do { try p.run(); caffeinate = p } catch { lastError = "caffeinate: \(error.localizedDescription)" }
    }

    private func stopCaffeinate() {
        caffeinate?.terminationHandler = nil
        caffeinate?.terminate()
        caffeinate = nil
    }

    private func declareActivity() {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Stay Awake" as CFString, kIOPMUserActiveLocal, &id)
    }

    private func startActivity() {
        guard activity == nil else { return }
        declareActivity()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.declareActivity() }
        RunLoop.main.add(t, forMode: .common); activity = t
    }

    private func stopActivity() { activity?.invalidate(); activity = nil }

    // MARK: state

    private func apply(_ flag: Bool) {
        on = flag
        if on { startCaffeinate(); startActivity() } else { stopCaffeinate(); stopActivity(); since = nil }
        render()
    }

    // Off the main thread: pmset is a process spawn and this runs every tick.
    private func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let flag = self?.readSleepDisabled() ?? false
            DispatchQueue.main.async { self?.apply(flag) }
        }
    }

    private func toggle() {
        let want = !on
        if setSleepDisabled(want) { since = want ? Date() : nil }
        // The flag is the truth, whatever the command reported.
        apply(readSleepDisabled())
    }

    // MARK: UI

    @objc private func clicked() {
        let ev = NSApp.currentEvent
        let mods = ev?.modifierFlags ?? []
        if ev?.type == .rightMouseUp || mods.contains(.control) || mods.contains(.option) {
            showMenu()
        } else {
            toggle()
        }
    }

    // The menu is attached only for as long as it is open: performClick tracks
    // it synchronously, and with it left on the item the next left click
    // would open it instead of toggling.
    private func showMenu() {
        build(menu)
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func render() {
        guard let b = item?.button else { return }
        // A steaming cup when on, an empty cup and saucer when off. The
        // steaming glyph is SF Symbols 5 (macOS 14); the filled cup stands in
        // on the macOS 13 floor the bundle declares.
        let img = on
            ? (NSImage(systemSymbolName: "cup.and.heat.waves.fill", accessibilityDescription: "Staying awake")
               ?? NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Staying awake"))
            : NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: "Sleep allowed")
        img?.isTemplate = true
        b.image = img
        b.appearsDisabled = !on
        b.toolTip = on ? "Stay Awake: on (sleep disabled, caffeinate running, lock held off) — click to allow sleep"
                       : "Stay Awake: off — click to stay awake through lid, KVM and idle"
    }

    private func build(_ m: NSMenu) {
        m.removeAllItems()
        header(m, "Stay Awake")
        if on {
            let age = since.map { " for \(ageText(Int(Date().timeIntervalSince($0))))" } ?? ""
            note(m, "On\(age) · sleep disabled · caffeinate \(caffeinate != nil ? "running" : "NOT running") · lock held off",
                 color: .systemBlue)
            note(m, "Click the cup to allow sleep again")
        } else {
            note(m, "Off · sleeping and locking normally")
            note(m, "Click the cup to stay awake through lid, KVM and idle")
        }
        if let e = lastError { note(m, e, color: .systemOrange) }
        m.addItem(.separator())
        let q = NSMenuItem(title: "Quit Stay Awake", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        m.addItem(q)
    }

    private func header(_ m: NSMenu, _ s: String) {
        let x = NSMenuItem(title: s, action: nil, keyEquivalent: ""); x.isEnabled = false
        x.attributedTitle = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        m.addItem(x)
    }

    private func note(_ m: NSMenu, _ s: String, color: NSColor = .secondaryLabelColor) {
        let x = NSMenuItem(title: s, action: nil, keyEquivalent: ""); x.isEnabled = false
        x.attributedTitle = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: color,
        ])
        m.addItem(x)
    }

    private func ageText(_ s: Int) -> String {
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return String(format: "%.1fh", Double(s) / 3600) }
        return "\(s / 86400)d"
    }

    @objc private func quit() { quitting = true; NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
