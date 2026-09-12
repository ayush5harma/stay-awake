#!/usr/bin/env bash
# Build Stay Awake into /Applications and register its LaunchAgent, so it
# starts at login and is restarted if it is ever killed. --uninstall reverses
# both steps. This is the one script in this repo that touches
# ~/Library/LaunchAgents and /Applications; build.sh and the sudoers example
# do not.
#
# Usage: install.sh [--force]     build (see build.sh --force) and (re-)register
#        install.sh --uninstall   unregister and remove the app

set -euo pipefail
# Bash 5.2+ defaults `patsub_replacement` ON, which makes an UNESCAPED & in a
# ${var//search/replace} REPLACEMENT mean "the matched text" -- exactly sed's
# own `&` pitfall, just better hidden: a path containing "&" (measured with
# one under Sources/ during review) renders a plist that still PASSES
# plutil -lint, because the literal "&" is replaced by the search pattern's
# own text instead of surviving as invalid raw XML, so the corruption is
# silent rather than caught. Off entirely, $HOME/$APP_PATH are inserted
# byte-for-byte. Bash 3.2 (macOS's own /bin/bash, `#!/usr/bin/env bash` may
# resolve there without Nix/Homebrew) has never heard of this option and
# exits nonzero on the bare `shopt`, which `set -e` would otherwise abort
# the whole script on -- harmless there anyway, since that bash predates the
# behaviour this undoes.
shopt -u patsub_replacement 2>/dev/null || true

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.ayushsharma.stay-awake"
PLIST_SRC="$DIR/launchd/$LABEL.plist.template"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_DIR="${APP_DIR:-/Applications}"
APP_PATH="$APP_DIR/${APP_NAME:-Stay Awake}.app"
UID_DOMAIN="gui/$(id -u)"

UNINSTALL=0
FORCE=0
for a in "$@"; do
  case "$a" in
    --uninstall) UNINSTALL=1 ;;
    --force) FORCE=1 ;;
    -h|--help) echo "Usage: install.sh [--force] | --uninstall"; exit 0 ;;
    *) echo "install.sh: unknown argument: $a" >&2; exit 1 ;;
  esac
done

say() { printf '%s\n' "$*"; }

if [ "$UNINSTALL" -eq 1 ]; then
  # `launchctl bootout` is a SIGTERM, not the menu's Quit -- main.swift only
  # resets disablesleep from its @objc quit() path (applicationWillTerminate
  # checks a `quitting` flag that only that path sets), so a bootout never
  # reaches it. Left unhandled, an uninstall while sleep is disabled would
  # leave the Mac unable to sleep FOREVER: the only thing that could turn it
  # back off is the app this just deleted. So check the actual system flag
  # directly and clear it here, before anything is removed.
  CURRENT="$(pmset -g | awk '/SleepDisabled/{print $2}')"
  if [ "$CURRENT" = "1" ]; then
    say "Sleep is currently disabled system-wide (pmset SleepDisabled=1); clearing it..."
    sudo pmset -a disablesleep 0 || say "FAILED. Run: sudo pmset -a disablesleep 0"
  fi
  say "Stopping and removing the $LABEL launch agent..."
  launchctl bootout "$UID_DOMAIN/$LABEL" >/dev/null 2>&1 || true
  rm -f "$PLIST_DST"
  if [ -d "$APP_PATH" ]; then
    say "Removing $APP_PATH"
    rm -rf "$APP_PATH"
  fi
  say "The sudoers rule, if you installed one, is untouched — remove it with:"
  say "  sudo rm /etc/sudoers.d/stay-awake"
  exit 0
fi

say "Building Stay Awake into $APP_DIR..."
if [ "$FORCE" -eq 1 ]; then
  APP_DIR="$APP_DIR" bash "$DIR/build.sh" --force
else
  APP_DIR="$APP_DIR" bash "$DIR/build.sh"
fi

# build.sh exits 0 even when swiftc is unusable (it says so and leaves the
# job to the caller, since it has no "pending setup" report of its own here)
# -- so a missing binary is not a build.sh failure this script can rely on
# `set -e` to catch. Registering an agent for a bundle with no executable
# would print "Installed" and leave a broken LaunchAgent behind.
[ -x "$APP_PATH/Contents/MacOS/StayAwake" ] \
  || { say "build produced no app (see above) — aborting"; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents"
# Plain string replacement, not sed: $HOME or $APP_PATH could contain a
# character sed's replacement text treats specially (& re-inserts the whole
# match; the delimiter itself, whatever it is, would need escaping) and
# silently corrupt the plist. Bash's ${var//search/replace} treats both
# sides literally. __APP__ carries the actual install location, since the
# LaunchAgent must find the app under APP_DIR, not a hardcoded /Applications.
TEMPLATE="$(cat "$PLIST_SRC")"
RENDERED="${TEMPLATE//__HOME__/$HOME}"
RENDERED="${RENDERED//__APP__/$APP_PATH}"
printf '%s' "$RENDERED" > "$PLIST_DST"
plutil -lint "$PLIST_DST" >/dev/null \
  || { say "rendered LaunchAgent plist is invalid — aborting"; rm -f "$PLIST_DST"; exit 1; }

say "Registering the launch agent..."
launchctl bootout "$UID_DOMAIN/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "$UID_DOMAIN" "$PLIST_DST"
launchctl enable "$UID_DOMAIN/$LABEL" >/dev/null 2>&1 || true

say "Installed. The cup should appear in the menu bar within a few seconds"
say "(or run: open \"$APP_PATH\")."
say ""
say "Without the optional sudoers rule, every click on the cup pops an"
say "administrator-password dialog. See README.md, \"The optional"
say "password-free sudoers rule\", to remove that prompt."
