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
  say "Stopping and removing the $LABEL launch agent..."
  launchctl bootout "$UID_DOMAIN/$LABEL" >/dev/null 2>&1 || true
  rm -f "$PLIST_DST"
  if [ -d "$APP_PATH" ]; then
    say "Removing $APP_PATH"
    rm -rf "$APP_PATH"
  fi
  say "Done. If sleep is still disabled (check: pmset -g | grep SleepDisabled), run:"
  say "  sudo pmset -a disablesleep 0"
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

mkdir -p "$HOME/Library/LaunchAgents"
sed "s#__HOME__#$HOME#" "$PLIST_SRC" > "$PLIST_DST"

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
