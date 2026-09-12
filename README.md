# Stay Awake

A one-click menu-bar toggle that keeps a Mac from sleeping — built for the
clamshell-mode-plus-KVM-switch case, where the machine you are not looking at
right now sees "lid closed, no external display" and sleeps, taking down
whatever was running on it.

Click the cup in the menu bar: it fills and starts steaming, and the Mac
stays up and unlocked through a closed lid, a KVM switch and idle time.
Click it again to let the Mac sleep normally.

## What it does

Stay Awake is a small `NSStatusItem` app (no Dock icon, no windows) with one
piece of state: on or off. Turning it on does three things, all of which stop
the moment you turn it off again:

1. **`pmset -a disablesleep 1`** — the only setting that actually prevents
   clamshell sleep (a closed lid with no external display attached). This
   needs root. Without further setup, the app requests it through
   AppleScript's `do shell script ... with administrator privileges`, which
   pops the standard macOS password dialog. See
   ["The optional password-free sudoers rule"](#the-optional-password-free-sudoers-rule)
   to make this silent. This flag lives in the system's own power settings,
   not in the app: it survives a reboot, a logout, and the app being killed
   or quit unexpectedly, and only the cup, the menu's Quit, or running
   `sudo pmset -a disablesleep 0` yourself clears it.
2. **`caffeinate -dimsu -w <the app's own pid>`** — prevents idle, display,
   disk and system sleep as a belt-and-braces measure, and is tied to the
   app's process by `-w`, so if the app is ever killed or replaced (a
   relaunch through the LaunchAgent's `KeepAlive`, a rebuild), the
   `caffeinate` child dies with it instead of running forever as an orphan.
3. **`IOPMAssertionDeclareUserActivity`, repeated every 60 seconds** — this is
   the half `caffeinate` cannot do. `caffeinate` keeps the *display* awake,
   but the screen saver and the login-window lock run on macOS's idle timer,
   which only real user activity resets. Declaring user activity on a timer
   is what keeps the Mac not just awake but *unlocked*.

The menu bar icon is not just a static state indicator — clicking it reads
`pmset -g`'s own `SleepDisabled` flag, both on a 30-second poll and right
after every click, and treats that flag as ground truth rather than trusting
whatever the last command reported. That means: if you set the flag from a
terminal, the app picks it up on its next poll; if you cancel the password
dialog, the toggle correctly reports itself as still off; and if the app
restarts while the flag is already on (a `KeepAlive` relaunch, a rebuild), it
re-attaches `caffeinate` and the activity timer without your having to click
anything.

Right-click (or Control/Option-click) the cup for a small menu: current
state, how long it has been on, and Quit. Quitting turns sleep back on first
(`pmset -a disablesleep` is a persistent system setting — quitting without
resetting it would leave the Mac unable to sleep with no icon left to say
so); a relaunch by the LaunchAgent is not a quit and leaves the flag alone.

## Requirements

- macOS 14 (Sonoma) or later. The app's `Info.plist` declares a floor of
  macOS 13, and it will run there, but the steaming-cup icon
  (`cup.and.heat.waves.fill`) is an SF Symbols 5 glyph introduced in macOS 14;
  on macOS 13 it falls back to a plain filled cup with no steam.
- Xcode Command Line Tools (`xcode-select --install`) — `build.sh` needs
  `swiftc`. A full Xcode install additionally lets the build produce a
  proper light/dark app icon via `actool`; without it you still get a
  working icon, just without the dark-mode variant (see `build.sh`'s
  comments for why).

## Install

```
git clone <this repo> stay-awake
cd stay-awake
./install.sh
```

This builds `Stay Awake.app` (via `build.sh`) into `/Applications`, then
registers a per-user LaunchAgent (`launchd/com.ayushsharma.stay-awake.plist.template`,
rendered to `~/Library/LaunchAgents/com.ayushsharma.stay-awake.plist`) so the
app starts at login and is relaunched if it is ever killed.

To build without installing the LaunchAgent, or to build into a different
place (for inspection, packaging, or CI), run `build.sh` directly:

```
APP_DIR=/tmp/scratch bash build.sh     # builds /tmp/scratch/Stay Awake.app
bash build.sh --force                  # rebuild even if nothing changed
```

`build.sh` is mtime-guarded: re-running it after `install.sh` has already
built and installed the app costs a handful of `find`/`stat` calls unless a
source file actually changed.

## The optional password-free sudoers rule

By default, every time you turn Stay Awake on or off, you'll see the
standard macOS "wants to make changes" administrator-password dialog, because
`pmset -a disablesleep` needs root. `sudoers/stay-awake.example` removes that
dialog for this app specifically, by granting your account passwordless
`sudo` for exactly two command lines:

```
<username> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
```

`sudo` matches a NOPASSWD rule's command **verbatim, arguments included** —
this is not "run pmset as root with no password" or "run any command as
root", it is exactly these two invocations and nothing else. That is the
entire security surface this rule adds: a local process running as your user
can flip the system's clamshell-sleep-disabled flag without a password
prompt. It cannot read files, run other commands, or escalate further through
this rule.

To install it:

```
sudo visudo -f /etc/sudoers.d/stay-awake
```

and paste in the line above with `<username>` replaced by your macOS short
username (`id -un`). `visudo` validates the syntax before saving and sets the
file's permissions itself. (`sudoers/stay-awake.example` has the same
instructions plus a validate-before-install variant using a scratch copy and
`visudo -c -f`.)

With the rule installed, the app's `sudo -n ...` call succeeds silently;
without it, `-n` fails immediately (not a hang) and the app falls back to the
password dialog.

Remove the rule at any time with `sudo rm /etc/sudoers.d/stay-awake` — the
app keeps working, just back to the password dialog.

## Uninstall

```
./install.sh --uninstall
```

Since `launchctl bootout` kills the app without going through its Quit
menu item, this checks the actual system flag first
(`pmset -g`'s `SleepDisabled`) and, if sleep is currently disabled, clears
it itself (`sudo pmset -a disablesleep 0` — this may prompt for a
password) before anything is removed: once the app is gone, it is the
only thing that could have turned this back off. It then unregisters the
LaunchAgent and removes `Stay Awake.app` from `/Applications` (or
wherever `APP_DIR` pointed it at). It does **not** remove the sudoers rule
(if you installed one) — do that with `sudo rm /etc/sudoers.d/stay-awake`.

## Troubleshooting

- **Every click pops a password dialog.** Expected without the sudoers rule
  above; install it to make the toggle silent.
- **Cancelling the password dialog does something weird.** It shouldn't —
  AppleScript reports a cancelled "administrator privileges" prompt as error
  `-128`, which the app treats as "nothing happened," not as a failure to
  report in its menu.
- **The cup doesn't reflect reality.** The app re-reads `pmset -g`'s
  `SleepDisabled` flag every 30 seconds and after every click, and treats
  that flag — not its own last command's exit status — as ground truth. If
  something else on the Mac has toggled `disablesleep`, expect up to a
  30-second lag before the icon catches up.
- **The app doesn't restart after a rebuild.** The LaunchAgent uses
  `KeepAlive`, and `build.sh` also directly `kickstart`s the running agent
  after a successful build, but only if the agent is already loaded (i.e.
  `install.sh` has run at least once).
- **Dark-mode icon looks wrong / missing.** The dark app-icon variant needs
  `actool`, which ships with Xcode, not the standalone Command Line Tools.
  With only the CLT installed, `build.sh` falls back to a legacy `.icns` in
  light appearance only — cosmetic, not a functional problem.
- **Nothing in `/var/log` or Console.app explains a failure.** Check
  `~/Library/Logs/stay-awake.log` first (`StandardErrorPath` in the rendered
  LaunchAgent plist).

## Changing the bundle id and label

The bundle identifier (`local.ayushsharma.stay-awake` in `Sources/main.swift`
and `build.sh`'s `Info.plist` heredoc) and the LaunchAgent label
(`com.ayushsharma.stay-awake`, in `build.sh`'s `$AGENT`,
`launchd/com.ayushsharma.stay-awake.plist.template`'s `Label`, and this repo's
filenames) are left as-is by default rather than genericised, since renaming
them is one search-and-replace and doing it for you would just be a
different set of placeholder names to replace. To use your own:

1. Pick a reverse-DNS id, e.g. `com.example.stay-awake`.
2. Replace `local.ayushsharma.stay-awake` in `Sources/main.swift` (the
   `bundleID` constant) and in `build.sh`'s `Info.plist` heredoc
   (`CFBundleIdentifier`).
3. Replace `com.ayushsharma.stay-awake` in `build.sh` (`AGENT=`), in
   `launchd/com.ayushsharma.stay-awake.plist.template` (`Label`), and rename
   that template file to match; update `install.sh`'s `LABEL=` too.
4. If you changed the sudoers rule's username placeholder into a real rule
   already, nothing there depends on the bundle id or label — it only names
   `pmset`.

## License

MIT — see [LICENSE](LICENSE).
