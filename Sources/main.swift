// Stay Awake: a menu-bar toggle that keeps a Mac awake and unlocked through a
// closed lid, a KVM switch and idle time. README.md says what it is for and
// how to install it; these comments say why the code is shaped this way.
//
// Being "on" takes three mechanisms, because each one leaves a gap:
//   • `pmset -a disablesleep 1` is the only setting that stops clamshell
//     sleep, the sleep a Mac enters when its lid closes with no display
//     attached. It needs root: see setSleepDisabled.
//   • `caffeinate -dimsu -w <our pid>` holds off idle, display, disk and
//     system sleep. -w ties it to this process, so a relaunch (KeepAlive, a
//     rebuild) can never leave an orphan behind.
//   • IOPMAssertionDeclareUserActivity every 60 s. caffeinate keeps the
//     DISPLAY awake, but the screen saver and the lock screen run on the idle
//     timer, which only user activity resets. This is the unlocked half.
//
// The state lives in pmset's own SleepDisabled flag, never in a copy held
// here, and is re-read every 30 s, after every click and on wake. So this app
// restarting re-attaches caffeinate and the activity timer when it finds the
// flag on, a flag set from a terminal shows up here, and cancelling the
// password dialog changes nothing.

import AppKit
import IOKit.pwr_mgt

// Must match CFBundleIdentifier in build.sh's Info.plist: it is how a second
// copy of the app finds the first. README.md, "Changing the bundle id and
// label", lists every place it appears.
let bundleID = "local.ayushsharma.stay-awake"

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var isOn = false
    private var onSince: Date?
    private var lastError: String?
    private var caffeinateProcess: Process?
    private var activityTimer: Timer?
    // Set only by the menu's Quit. A KeepAlive relaunch, a rebuild and another
    // copy's single-instance sweep all end this process too, and none of them
    // should turn sleep back on.
    private var isQuittingFromMenu = false

    func applicationDidFinishLaunching(_: Notification) {
        terminateOtherCopies()
        makeStatusItem()
        updateIcon()
        poll()
        repeatingTimer(every: 30) { [weak self] in self?.poll() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.poll() }
    }

    // `pmset -a disablesleep` is a persistent system setting, so a quit that
    // left it on would keep the Mac from sleeping with no cup left in the menu
    // bar to say so. Only the menu's Quit undoes it; a relaunch keeps the flag,
    // which is what makes the state survive this app.
    func applicationWillTerminate(_: Notification) {
        if isQuittingFromMenu && isOn { _ = setSleepDisabled(false, allowDialog: false) }
        stopCaffeinate()
        stopActivityTimer()
    }

    // MARK: Launch

    // A second copy would put a second cup in the menu bar.
    private func terminateOtherCopies() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where other.processIdentifier != ownPID { other.terminate() }
    }

    // No menu is attached to the item: with one attached, every click opens it.
    // The button reports both mouse buttons and statusItemClicked tells them
    // apart.
    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: The sleep flag

    // The password-free path first, the administrator dialog second. False
    // when neither set the flag, which includes the person cancelling.
    private func setSleepDisabled(_ disabled: Bool, allowDialog: Bool = true) -> Bool {
        let value = disabled ? "1" : "0"
        if runPmsetWithSudo(value) { lastError = nil; return true }
        return allowDialog && runPmsetWithAdminDialog(value)
    }

    // The NOPASSWD rule in sudoers/stay-awake.example covers exactly these two
    // command lines and nothing else, so the arguments below must stay as they
    // are. -n makes a missing rule a refusal rather than a hang on a password
    // prompt nobody can see.
    private func runPmsetWithSudo(_ value: String) -> Bool {
        let sudo = makeProcess("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", value])
        sudo.standardInput = FileHandle.nullDevice
        guard (try? sudo.run()) != nil else { return false }
        sudo.waitUntilExit()
        return sudo.terminationStatus == 0
    }

    // AppleScript reports a cancelled prompt as error -128: the person chose
    // not to, which is not an error to report in the menu.
    private func runPmsetWithAdminDialog(_ value: String) -> Bool {
        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(value)\" with administrator privileges"
        var scriptError: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&scriptError)
        guard let scriptError else { lastError = nil; return true }
        let code = (scriptError[NSAppleScript.errorNumber] as? Int) ?? 0
        lastError = code == -128 ? nil : ((scriptError[NSAppleScript.errorMessage] as? String) ?? "pmset failed")
        return false
    }

    // MARK: Awake and unlocked

    private func startCaffeinate() {
        guard caffeinateProcess == nil else { return }
        let caffeinate = makeProcess("/usr/bin/caffeinate",
                                     ["-dimsu", "-w", String(ProcessInfo.processInfo.processIdentifier)])
        // If caffeinate dies on its own, forget it; the next poll starts a new one.
        caffeinate.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.caffeinateProcess = nil }
        }
        do {
            try caffeinate.run()
            caffeinateProcess = caffeinate
        } catch {
            lastError = "caffeinate: \(error.localizedDescription)"
        }
    }

    private func stopCaffeinate() {
        // Drop the handler first, or its late hop to the main queue could clear
        // the reference to a caffeinate started after this one.
        caffeinateProcess?.terminationHandler = nil
        caffeinateProcess?.terminate()
        caffeinateProcess = nil
    }

    private func startActivityTimer() {
        guard activityTimer == nil else { return }
        declareUserActivity()
        activityTimer = repeatingTimer(every: 60) { [weak self] in self?.declareUserActivity() }
    }

    private func stopActivityTimer() {
        activityTimer?.invalidate()
        activityTimer = nil
    }

    private func declareUserActivity() {
        var assertionID: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Stay Awake" as CFString, kIOPMUserActiveLocal, &assertionID)
    }

    // MARK: State

    // Brings the app in line with the flag it has just read.
    private func apply(sleepDisabled: Bool) {
        isOn = sleepDisabled
        if isOn {
            startCaffeinate()
            startActivityTimer()
        } else {
            stopCaffeinate()
            stopActivityTimer()
            onSince = nil
        }
        updateIcon()
    }

    // Off the main thread: reading the flag spawns pmset, and this runs on
    // every tick.
    private func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let sleepDisabled = readSleepDisabled()
            DispatchQueue.main.async { self?.apply(sleepDisabled: sleepDisabled) }
        }
    }

    private func toggle() {
        let turningOn = !isOn
        if setSleepDisabled(turningOn) { onSince = turningOn ? Date() : nil }
        // The flag is the truth, whatever the command reported.
        apply(sleepDisabled: readSleepDisabled())
    }

    // MARK: Menu bar

    // Left click toggles; right click, or a click holding Control or Option,
    // opens the menu.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let modifiers = event?.modifierFlags ?? []
        if event?.type == .rightMouseUp || modifiers.contains(.control) || modifiers.contains(.option) {
            showMenu()
        } else {
            toggle()
        }
    }

    // The menu is attached only for as long as it is open: performClick tracks
    // it synchronously, and with it left on the item the next left click would
    // open it instead of toggling.
    private func showMenu() {
        populateMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        // A steaming cup when on, an empty cup and saucer when off. The
        // steaming glyph is SF Symbols 5 (macOS 14); the filled cup stands in
        // on the macOS 13 floor the bundle declares.
        let image = isOn
            ? (NSImage(systemSymbolName: "cup.and.heat.waves.fill", accessibilityDescription: "Staying awake")
               ?? NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Staying awake"))
            : NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: "Sleep allowed")
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !isOn
        button.toolTip = isOn
            ? "Stay Awake: on (sleep disabled, caffeinate running, lock held off) — click to allow sleep"
            : "Stay Awake: off — click to stay awake through lid, KVM and idle"
    }

    private func populateMenu() {
        buildMenuItems(into: menu, state: MenuState(
            isOn: isOn,
            onSince: onSince,
            caffeinateRunning: caffeinateProcess != nil,
            lastError: lastError
        ), quitTarget: self, quitAction: #selector(quitFromMenu))
    }

    @objc private func quitFromMenu() {
        isQuittingFromMenu = true
        NSApp.terminate(nil)
    }
}

// 2026-10-14: shared menu construction keeps the sample preview consistent
// with the running app without invoking power-management side effects.
struct MenuState {
    let isOn: Bool
    let onSince: Date?
    let caffeinateRunning: Bool
    let lastError: String?
}

func buildMenuItems(into menu: NSMenu, state: MenuState, quitTarget: AnyObject? = nil, quitAction: Selector? = nil) {
    menu.removeAllItems()
    addMenuLabel("Stay Awake", to: menu, font: .systemFont(ofSize: 12.5, weight: .semibold), color: .labelColor)
    if state.isOn {
        let age = state.onSince.map { " for \(ageText(Int(Date().timeIntervalSince($0))))" } ?? ""
        let caffeinateState = state.caffeinateRunning ? "running" : "NOT running"
        addMenuLabel("On\(age) · sleep disabled · caffeinate \(caffeinateState) · lock held off",
                     to: menu, font: .systemFont(ofSize: 11.5), color: .systemBlue)
        addMenuLabel("Click the cup to allow sleep again", to: menu,
                     font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor)
    } else {
        addMenuLabel("Off · sleeping and locking normally", to: menu,
                     font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor)
        addMenuLabel("Click the cup to stay awake through lid, KVM and idle", to: menu,
                     font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor)
    }
    if let error = state.lastError {
        addMenuLabel(error, to: menu, font: .systemFont(ofSize: 11.5), color: .systemOrange)
    }
    menu.addItem(.separator())
    let quit = NSMenuItem(title: "Quit Stay Awake", action: quitAction, keyEquivalent: "q")
    quit.target = quitTarget
    menu.addItem(quit)
}

// Disabled items are menu text, not commands. The action item stays enabled.
func addMenuLabel(_ text: String, to menu: NSMenu, font: NSFont, color: NSColor) {
    let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
    item.isEnabled = false
    item.attributedTitle = NSAttributedString(string: text, attributes: [
        .font: font,
        .foregroundColor: color,
    ])
    menu.addItem(item)
}

// MARK: - Helpers that hold no state

// The SleepDisabled setting from `pmset -g`; false when pmset cannot be run.
func readSleepDisabled() -> Bool {
    let pmset = makeProcess("/usr/bin/pmset", ["-g"])
    let output = Pipe()
    pmset.standardOutput = output
    guard (try? pmset.run()) != nil else { return false }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    pmset.waitUntilExit()
    // One setting per line, name then value: " SleepDisabled\t\t1".
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if fields.count >= 2, fields[0] == "SleepDisabled" { return fields[1] == "1" }
    }
    return false
}

// Output goes nowhere unless the caller redirects it, so a child's chatter
// never reaches the LaunchAgent's log: without the sudoers rule, `sudo -n`
// would write a refusal there on every click.
func makeProcess(_ path: String, _ arguments: [String]) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    return process
}

// .common mode, or the timer freezes exactly while the menu is open.
@discardableResult
func repeatingTimer(every seconds: TimeInterval, _ action: @escaping () -> Void) -> Timer {
    let timer = Timer(timeInterval: seconds, repeats: true) { _ in action() }
    RunLoop.main.add(timer, forMode: .common)
    return timer
}

// Short enough for one line of the menu: 45s, 12m, 2.5h, 3d.
func ageText(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86400 { return String(format: "%.1fh", Double(seconds) / 3600) }
    return "\(seconds / 86400)d"
}

// This renders the live menu's NSMenuItem content with fixed sample state. It
// stays above NSApplication setup so the preview cannot affect pmset,
// caffeinate, timers, or a LaunchAgent.
func renderScreenshotFixture(to path: String) throws {
    let size = NSSize(width: 640, height: 270)
    let image = NSImage(size: size)
    NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
    image.lockFocus()
    NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    let menuRect = NSRect(x: 24, y: 22, width: 592, height: 190)
    NSColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 1).setFill()
    NSBezierPath(roundedRect: menuRect, xRadius: 14, yRadius: 14).fill()
    let caption = NSAttributedString(string: "Sample menu content preview", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor.secondaryLabelColor,
    ])
    caption.draw(at: NSPoint(x: menuRect.minX, y: 240))
    let menu = NSMenu()
    buildMenuItems(into: menu, state: MenuState(
        isOn: true,
        onSince: Date().addingTimeInterval(-42 * 60),
        caffeinateRunning: true,
        lastError: nil
    ))
    var y = menuRect.maxY - 34
    for item in menu.items {
        if item.isSeparatorItem {
            NSColor.separatorColor.setFill()
            NSRect(x: menuRect.minX + 26, y: y + 8, width: menuRect.width - 52, height: 1).fill()
            y -= 32
            continue
        }
        let title = item.attributedTitle ?? NSAttributedString(string: item.title, attributes: [
            .font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
        ])
        title.draw(in: NSRect(x: menuRect.minX + 34, y: y, width: menuRect.width - 68, height: 28))
        y -= 28
    }
    image.unlockFocus()
    }
    guard let data = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "StayAwake", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not encode fixture"])
    }
    try png.write(to: URL(fileURLWithPath: path))
}

if let fixtureIndex = CommandLine.arguments.firstIndex(of: "--screenshot-fixture") {
    guard CommandLine.arguments.indices.contains(fixtureIndex + 1) else {
        FileHandle.standardError.write(Data("--screenshot-fixture needs an output path\n".utf8))
        exit(2)
    }
    do { try renderScreenshotFixture(to: CommandLine.arguments[fixtureIndex + 1]) }
    catch { FileHandle.standardError.write(Data("screenshot fixture failed: \(error)\n".utf8)); exit(1) }
    exit(0)
}

// NSApplication holds its delegate weakly, so this global is what keeps it
// alive. .accessory is the menu-bar-only policy, matching LSUIElement in the
// Info.plist build.sh writes.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
