#!/usr/bin/env bash
# Build Stay Awake into /Applications and register its LaunchAgent, so it
# starts at login and is restarted if it is ever killed. --uninstall reverses
# both steps. This is the only script here that writes ~/Library/LaunchAgents;
# build.sh only writes the app bundle.
#
# Usage: install.sh [--force]     build (see build.sh --force) and (re-)register
#        install.sh --uninstall   unregister and remove the app

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.ayushsharma.stay-awake"
PLIST_TEMPLATE="$DIR/launchd/$LABEL.plist.template"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_DIR="${APP_DIR:-/Applications}"
APP_PATH="$APP_DIR/${APP_NAME:-Stay Awake}.app"
GUI_DOMAIN="gui/$(id -u)"

UNINSTALL=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --uninstall) UNINSTALL=1 ;;
    --force) FORCE=1 ;;
    -h|--help) echo "Usage: install.sh [--force] | --uninstall"; exit 0 ;;
    *) echo "install.sh: unknown argument: $arg" >&2; exit 1 ;;
  esac
done

say() { printf '%s\n' "$*"; }

if [ "$UNINSTALL" -eq 1 ]; then
  # `launchctl bootout` ends the app with SIGTERM, which never reaches the
  # menu's Quit -- main.swift turns sleep back on only from its @objc quit()
  # path (applicationWillTerminate checks a flag that only that path sets).
  # Once the app is deleted, nothing is left that could turn sleep back on,
  # so read the system flag and clear it here, before removing anything.
  SLEEP_DISABLED="$(pmset -g | awk '/SleepDisabled/{print $2}')"
  if [ "$SLEEP_DISABLED" = "1" ]; then
    say "Sleep is currently disabled system-wide (pmset SleepDisabled=1); clearing it..."
    sudo pmset -a disablesleep 0 || say "FAILED. Run: sudo pmset -a disablesleep 0"
  fi
  say "Stopping and removing the $LABEL launch agent..."
  launchctl bootout "$GUI_DOMAIN/$LABEL" >/dev/null 2>&1 || true
  rm -f "$PLIST_PATH"
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
# decision to its caller), so a missing binary is not something `set -e` will
# catch here. Registering an agent for a bundle with no executable would print
# "Installed" and leave a broken LaunchAgent behind.
[ -x "$APP_PATH/Contents/MacOS/StayAwake" ] \
  || { say "build produced no app (see above) — aborting"; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents"
# A plist this script did not write belongs to something else: a nix-darwin
# switch writes agents into ~/Library/LaunchAgents as read-only files (mode
# 444; measured 2026-09-13 on a flake-managed Mac), home-manager links them
# from the read-only Nix store. Writing over either fails as "Permission
# denied" after the build and, made writable, would silently take the agent
# away from its owner. This script's own plists are 644. Say so and stop;
# that Mac gets the app from its flake.
if [ -e "$PLIST_PATH" ] && { [ -L "$PLIST_PATH" ] || [ ! -w "$PLIST_PATH" ]; }; then
  say "$PLIST_PATH is read-only or a symlink, so another tool manages this agent (a Nix flake?);"
  say "not touching it. Uninstall that first, or leave Stay Awake to it."
  exit 1
fi

# Render the template by plain string replacement rather than with sed: $HOME
# or $APP_PATH can contain a character sed treats specially in replacement
# text (& re-inserts the whole match; the delimiter itself would need
# escaping), and the plist would be silently corrupt. __APP__ carries the
# actual install location, because the LaunchAgent has to find the app under
# APP_DIR rather than a hardcoded /Applications.
#
# Bash 5.2 gave ${var//search/replace} sed's own & pitfall, better hidden:
# with patsub_replacement on (its default) an unescaped & in the REPLACEMENT
# means the matched text, so a path containing & (measured with one under
# Sources/ during review) renders a plist that still PASSES plutil -lint --
# the & is replaced by the search pattern's own text instead of surviving as
# invalid raw XML, so the corruption is silent rather than caught. Off, $HOME
# and $APP_PATH are inserted byte for byte. Bash 3.2 (macOS's own /bin/bash,
# which `#!/usr/bin/env bash` may resolve to without Nix or Homebrew) has
# never heard of the option and exits non-zero on the bare `shopt`, which
# `set -e` would otherwise abort on; it predates the behaviour this undoes.
# Keep this above EVERY ${var//...} in the file: the failure it prevents
# passes plutil -lint, so a substitution added above it would lose the guard
# silently.
shopt -u patsub_replacement 2>/dev/null || true
TEMPLATE="$(cat "$PLIST_TEMPLATE")"
RENDERED="${TEMPLATE//__HOME__/$HOME}"
RENDERED="${RENDERED//__APP__/$APP_PATH}"
printf '%s' "$RENDERED" > "$PLIST_PATH"
plutil -lint "$PLIST_PATH" >/dev/null \
  || { say "rendered LaunchAgent plist is invalid — aborting"; rm -f "$PLIST_PATH"; exit 1; }

say "Registering the launch agent..."
launchctl bootout "$GUI_DOMAIN/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "$GUI_DOMAIN" "$PLIST_PATH"
launchctl enable "$GUI_DOMAIN/$LABEL" >/dev/null 2>&1 || true

say "Installed. The cup should appear in the menu bar within a few seconds"
say "(or run: open \"$APP_PATH\")."
say ""
say "Without the optional sudoers rule, every click on the cup pops an"
say "administrator-password dialog. The rule to paste, and what it allows,"
say "are in README.md under \"Install\"."
