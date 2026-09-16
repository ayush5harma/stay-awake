# Stay Awake

Stay Awake is a macOS menu-bar app that keeps a Mac awake and unlocked, even
with the lid closed and no display attached. It was written for two Macs
sharing one monitor through a KVM switch, where the Mac you switch away from
otherwise sleeps and stops whatever it was running.

Click the cup in the menu bar to turn it on, click it again to turn it off.

## Install

You need macOS 14 or later, and the Xcode Command Line Tools
(`xcode-select --install`), which provide the Swift compiler. It also runs on
macOS 13, with a plain cup in place of the steaming one; see
[macOS versions and the icons](#macos-versions-and-the-icons).

```sh
git clone https://github.com/ayush5harma/stay-awake.git
cd stay-awake
./install.sh
```

That builds `Stay Awake.app` into `/Applications` and registers a LaunchAgent
at `~/Library/LaunchAgents/com.ayushsharma.stay-awake.plist`, so the app
starts at login and is restarted if it is ever killed. A cup appears in the
menu bar within a few seconds.

One optional step. Without a sudoers rule, every click asks for your
administrator password; to make clicks silent, run

```sh
sudo visudo -f /etc/sudoers.d/stay-awake
```

and paste this line, replacing `<username>` with your macOS short username
(`id -un`):

```
<username> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
```

`visudo` checks the syntax before saving and sets the file's permissions
itself. [How it works](#how-it-works) explains exactly what the rule allows,
and `sudoers/stay-awake.example` is the same line with a variant that
validates a scratch copy first. Remove the rule at any time with
`sudo rm /etc/sudoers.d/stay-awake`; the app keeps working, with the password
dialog back.

To uninstall:

```sh
./install.sh --uninstall
```

That clears the system `SleepDisabled` flag if it is set, whatever set it
(which may ask for your password), unregisters the LaunchAgent and deletes the app from
`/Applications`, or from `APP_DIR` if you set one. It leaves the sudoers rule
alone.

## Use

- Click the cup to turn Stay Awake on. It fills and steams, and the Mac stays
  awake and unlocked through a closed lid, a KVM switch and idle time.
- Click it again to turn it off and let the Mac sleep and lock normally.
- Right-click the cup, or Control-click or Option-click it, for a menu showing
  whether it is on, how long it has been on, the last error if there was one,
  and Quit.

Being on is a system setting rather than something the app holds, so it
survives a reboot, a logout, and the app being killed or crashing. Four things
turn it off: the cup, the menu's Quit, `./install.sh --uninstall`, and running
`sudo pmset -a disablesleep 0` yourself. Quit turns sleep back on before the
app exits, so the Mac is never left unable to sleep with no cup to say so; the
LaunchAgent restarting the app is not a quit and leaves the setting alone.

## How it works

Stay Awake is a small AppKit app with one piece of state, on or off, and no
Dock icon or windows. Turning it on does three things, because each one leaves
a gap the next covers, and turning it off undoes all three:

1. `pmset -a disablesleep 1`. The only setting that stops a Mac sleeping when
   its lid is closed and no display is attached.
2. `caffeinate -dimsu -w <the app's pid>`. Prevents idle, display, disk and
   system sleep. `-w` ties it to the app's process, so it can never outlive
   the app as an orphan.
3. `IOPMAssertionDeclareUserActivity`, every 60 seconds. `caffeinate` keeps
   the display awake, but the screen saver and the login-window lock run on
   macOS's idle timer, which only real user activity resets. This is what
   keeps the Mac unlocked rather than merely awake.

The app does not trust its own memory for the state. It reads the
`SleepDisabled` value out of `pmset -g` every 30 seconds, after every click
and after the Mac wakes, and shows that. So a change made from a terminal
appears here, a cancelled password dialog correctly leaves the cup off, and an
app restarted while the setting is on re-attaches `caffeinate` and the
activity timer by itself.

### The sudoers rule, and why it is needed

`pmset -a disablesleep` has to run as root. The app first tries
`sudo -n /usr/bin/pmset -a disablesleep 1` (or `0`). `-n` tells sudo never to
prompt, so without a rule it fails immediately rather than hanging, and the
app falls back to the standard macOS administrator-password dialog
(AppleScript's `do shell script ... with administrator privileges`).

The rule under [Install](#install) makes exactly those two command lines
password-free. sudo matches a NOPASSWD rule's command line verbatim,
arguments included, so this is not "run pmset as root without a password" and
certainly not "run anything as root": it is those two invocations and nothing
else. What the rule adds, in full, is that a process running as you can turn
clamshell sleep off and on without a password. It cannot read files, run other
commands, or reach anything further through this rule.

## Build from source

`build.sh` compiles `Sources/main.swift` with a single `swiftc` call (there is
no Xcode project), draws the app icon from `Sources/icon.swift`, and ad-hoc
signs the bundle.

```sh
bash build.sh                        # build into /Applications
bash build.sh --force                # rebuild even when nothing changed
APP_DIR=/tmp/scratch bash build.sh   # build /tmp/scratch/Stay Awake.app instead
```

It skips the work when the app is already built, still has its icon, and no
file under `Sources/` is newer than it, so re-running it costs a handful of
`find` and `stat` calls. Changes to `build.sh` itself are not part of that
check; use `--force` after editing it. Compiler errors go to
`Sources/.build.log`.

`build.sh` never registers the LaunchAgent; only `install.sh` does. A build
into `/Applications` does restart the running app through that agent, if the
agent is loaded, so the new build is the one in the menu bar. A build anywhere
else leaves the installed app alone.

## Licence

MIT; see [LICENSE](LICENSE).

## Details

### What is in the repo

| Path | What it is |
| --- | --- |
| `Sources/main.swift` | the app: the menu-bar item, the three mechanisms, the menu |
| `Sources/icon.swift` | draws the app icon at build time, so no image file is checked in |
| `build.sh` | compiles, draws the icon, signs the bundle |
| `install.sh` | build plus LaunchAgent registration, and `--uninstall` |
| `launchd/com.ayushsharma.stay-awake.plist.template` | the LaunchAgent, with `__HOME__` and `__APP__` filled in by `install.sh` |
| `sudoers/stay-awake.example` | the optional NOPASSWD rule, with installation notes |

### Troubleshooting

- **Every click pops a password dialog.** Expected without the sudoers rule
  above; install it to make the toggle silent.
- **Cancelling the password dialog does something strange.** It should not:
  AppleScript reports a cancelled administrator prompt as error `-128`, which
  the app treats as "nothing happened" rather than as a failure to report.
- **The cup does not match reality.** The app re-reads the `SleepDisabled`
  flag every 30 seconds and after every click, and trusts that flag over its
  own last command. If something else on the Mac changed `disablesleep`,
  expect up to a 30-second lag before the cup catches up.
- **The app did not restart after a rebuild.** The LaunchAgent uses
  `KeepAlive`, and `build.sh` also restarts the agent itself after a
  successful build, but only for a build into `/Applications` and only if the
  agent is already loaded, which means `install.sh` has run at least once.
- **`install.sh` says another tool manages this agent.** The LaunchAgent plist
  is read-only or a symlink, which is how nix-darwin and home-manager install
  agents. `install.sh` stops rather than taking the agent away from whatever
  owns it.
- **Nothing in Console.app explains a failure.** Look at
  `~/Library/Logs/stay-awake.log` first; it is the `StandardErrorPath` in the
  rendered LaunchAgent plist.

### macOS versions and the icons

The app's `Info.plist` declares macOS 13 as its floor and it does run there,
but the steaming cup (`cup.and.heat.waves.fill`) is an SF Symbols 5 glyph
introduced in macOS 14. On macOS 13 the "on" cup is a plain filled cup with
no steam.

The app icon is drawn at build time in two forms: an Icon Composer package
that `actool` compiles into light and dark artwork, and a legacy `.icns` for
older macOS. `actool` ships with Xcode, not with the standalone Command Line
Tools, so with only the Command Line Tools installed you get a working icon
in light appearance only. That is cosmetic; the app is the same.

### Changing the bundle id and label

The bundle identifier (`local.ayushsharma.stay-awake`) and the LaunchAgent
label (`com.ayushsharma.stay-awake`) are left as they are rather than
genericised, since renaming them is one search-and-replace and doing it for
you would only leave a different set of placeholders to replace. To use your
own:

1. Pick a reverse-DNS id, for example `com.example.stay-awake`.
2. Replace `local.ayushsharma.stay-awake` in `Sources/main.swift` (the
   `bundleID` constant) and in `build.sh`'s `Info.plist` heredoc
   (`CFBundleIdentifier`).
3. Replace `com.ayushsharma.stay-awake` in `build.sh` and `install.sh` (both
   call it `LABEL`) and in
   `launchd/com.ayushsharma.stay-awake.plist.template` (`Label`), and rename
   that template file to match.
4. Nothing in the sudoers rule changes: it names `pmset`, not this app.
