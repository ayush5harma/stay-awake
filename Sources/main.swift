// Stay Awake — a one-click menu-bar toggle for a Mac that must not sleep.
//
// THE OBJECTIVE. A common case this was built for: two Macs sharing one
// display through a KVM switch, each in clamshell mode with the lid closed;
// the host left behind sees "lid closed, no display", sleeps, and kills
// whatever was running while the lock screen engages. ONE CLICK on the cup
// turns this on, and the host then stays up AND unlocked through lid, KVM
// and idle by three means:
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
    private var since: Date?
    private var on = false
    private var quitting = false   // set by the menu's Quit; a KeepAlive relaunch or the single-instance sweep is not a quit
    private var lastError: String?

    func applicationDidFinishLaunching(_: Notification) {
        terminateOtherCopies()
        makeStatusItem()
        render()
        poll()
        repeatingTimer(every: 30) { [weak self] in self?.poll() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.poll() }
    }

    // Quit from the menu allows sleep again: `pmset -a disablesleep` is a
    // persistent setting, and a quit that left it on would keep the Mac from
    // sleeping with no cup left in the bar to say so. A relaunch (KeepAlive, a
    // rebuild) keeps the flag, so the state survives the app.
    func applicationWillTerminate(_: Notification) {
        if quitting && on { setSleepDisabled(false, dialog: false) }
        stopCaffeinate(); stopActivity()
    }

    // MARK: launch

    // SINGLE INSTANCE: a second copy would put a second cup in the bar.
    private func terminateOtherCopies() {
        let me = ProcessInfo.processInfo.processIdentifier
        for a in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where a.processIdentifier != me { a.terminate() }
    }

    // No menu on the item: with one set, every click opens it. The button
    // gets both mouse buttons and the handler tells them apart.
    private func makeStatusItem() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let b = item.button else { return }
        b.target = self
        b.action = #selector(clicked)
        b.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: pmset

    // `sudo -n` first, the administrator dialog second. False when neither
    // happened -- which includes the person cancelling the dialog.
    @discardableResult
    private func setSleepDisabled(_ flag: Bool, dialog: Bool = true) -> Bool {
        let arg = flag ? "1" : "0"
        if runPmsetWithSudo(arg) { lastError = nil; return true }
        return dialog && runPmsetWithAdminDialog(arg)
    }

    // The NOPASSWD rule in sudoers/stay-awake.example (once installed) covers
    // exactly these two command lines and nothing else, and -n makes a missing
    // rule a refusal instead of a hang on a password nobody can type.
    private func runPmsetWithSudo(_ arg: String) -> Bool {
        let p = makeProcess("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", arg])
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // AppleScript reports a cancelled prompt as error -128: the person chose
    // not to, which is not an error to report in the menu.
    private func runPmsetWithAdminDialog(_ arg: String) -> Bool {
        let src = "do shell script \"/usr/bin/pmset -a disablesleep \(arg)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        guard let e = err else { lastError = nil; return true }
        let code = (e[NSAppleScript.errorNumber] as? Int) ?? 0
        lastError = code == -128 ? nil : ((e[NSAppleScript.errorMessage] as? String) ?? "pmset failed")
        return false
    }

    // MARK: caffeinate + user activity

    private func startCaffeinate() {
        guard caffeinate == nil else { return }
        let p = makeProcess("/usr/bin/caffeinate",
                            ["-dimsu", "-w", String(ProcessInfo.processInfo.processIdentifier)])
        // If caffeinate dies on its own, forget it; the next poll starts a new one.
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.caffeinate = nil }
        }
        do { try p.run(); caffeinate = p } catch { lastError = "caffeinate: \(error.localizedDescription)" }
    }

    private func stopCaffeinate() {
        // Drop the handler first, or its late hop to the main queue could clear
        // the reference to a caffeinate started after this one.
        caffeinate?.terminationHandler = nil
        caffeinate?.terminate()
        caffeinate = nil
    }

    private func startActivity() {
        guard activity == nil else { return }
        declareActivity()
        activity = repeatingTimer(every: 60) { [weak self] in self?.declareActivity() }
    }

    private func stopActivity() { activity?.invalidate(); activity = nil }

    private func declareActivity() {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Stay Awake" as CFString, kIOPMUserActiveLocal, &id)
    }

    // MARK: state

    private func apply(_ flag: Bool) {
        on = flag
        if on { startCaffeinate(); startActivity() } else { stopCaffeinate(); stopActivity(); since = nil }
        render()
    }

    // Off the main thread: pmset is a process spawn and this runs every tick.
    private func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let flag = readSleepDisabled()
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
        label(m, "Stay Awake", font: .systemFont(ofSize: 12.5, weight: .semibold), color: .labelColor)
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

    private func note(_ m: NSMenu, _ s: String, color: NSColor = .secondaryLabelColor) {
        label(m, s, font: .systemFont(ofSize: 11.5), color: color)
    }

    // Disabled, so it reads as menu text rather than as a command.
    private func label(_ m: NSMenu, _ s: String, font: NSFont, color: NSColor) {
        let x = NSMenuItem(title: s, action: nil, keyEquivalent: ""); x.isEnabled = false
        x.attributedTitle = NSAttributedString(string: s, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
        m.addItem(x)
    }

    @objc private func quit() { quitting = true; NSApp.terminate(nil) }
}

// MARK: - Helpers that hold no state

// The SleepDisabled setting from `pmset -g`; false when pmset cannot be run.
func readSleepDisabled() -> Bool {
    let p = makeProcess("/usr/bin/pmset", ["-g"])
    let pipe = Pipe(); p.standardOutput = pipe
    guard (try? p.run()) != nil else { return false }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    // One setting per line, name then value: " SleepDisabled\t\t1".
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if parts.count >= 2, parts[0] == "SleepDisabled" { return parts[1] == "1" }
    }
    return false
}

// Output goes nowhere unless the caller redirects it, so a child's chatter
// never reaches the LaunchAgent's log: without the sudoers rule, `sudo -n`
// would write a refusal there on every click.
func makeProcess(_ path: String, _ arguments: [String]) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    return p
}

// .common mode, or the timer freezes exactly while the menu is open.
@discardableResult
func repeatingTimer(every seconds: TimeInterval, _ action: @escaping () -> Void) -> Timer {
    let t = Timer(timeInterval: seconds, repeats: true) { _ in action() }
    RunLoop.main.add(t, forMode: .common)
    return t
}

func ageText(_ s: Int) -> String {
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return String(format: "%.1fh", Double(s) / 3600) }
    return "\(s / 86400)d"
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
