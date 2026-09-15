#!/usr/bin/env bash
# Build "Stay Awake.app" from Sources/ and install it into /Applications.
#
# Usage: build.sh [--force]
#   --force          rebuild even when nothing under Sources/ has changed
#   APP_DIR=<dir>    build into <dir> instead of /Applications. Such a scratch
#                    build does not restart the installed app.
#   APP_NAME=<name>  name the bundle "<name>.app" instead of "Stay Awake.app"
#
# One swiftc call, no Xcode project, ad-hoc signed. The icon is drawn by
# Sources/icon.swift at build time, so no binary asset lives in the repo.
#
# install.sh and other tooling run this script directly, so keep its
# interface: the arguments above, /Applications as the default, exit 0 when
# swiftc is missing, and a non-zero exit when the compile fails.

set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/Sources" && pwd)"
DEFAULT_APP_DIR="/Applications"
APP_DIR="${APP_DIR:-$DEFAULT_APP_DIR}"
APP_NAME="${APP_NAME:-Stay Awake}"
APP_PATH="$APP_DIR/$APP_NAME.app"
BIN="$APP_PATH/Contents/MacOS/StayAwake"
RESOURCES="$APP_PATH/Contents/Resources"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
LABEL="com.ayushsharma.stay-awake"   # the LaunchAgent install.sh registers
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

say() { printf '  %s\n' "$*"; }

# show_log_tail <log> <lines>: the tail of a log, indented under the message
# that points at it.
show_log_tail() { tail -n "$2" "$1" | sed 's/^/      /'; }

# /usr/bin/swiftc is a shim that exists on every Mac and fails until the Xcode
# Command Line Tools are installed, so the check has to run it rather than
# look for the path. Exit 0 either way: the caller decides what a missing
# toolchain means for it.
SWIFTC="$(command -v swiftc 2>/dev/null || xcrun --find swiftc 2>/dev/null)"
if ! { [ -n "$SWIFTC" ] && "$SWIFTC" --version >/dev/null 2>&1; }; then
  say "swiftc not usable — install the Xcode Command Line Tools (xcode-select --install)"
  exit 0
fi

# Skip when no file under Sources/ is newer than the installed binary. Every
# file there counts, not just main.swift, or an edit to icon.swift would never
# reach the installed app. Files outside Sources/ (this script included) do
# not count; use --force after changing them. Dot-files are ignored because
# this script writes Sources/.build.log and Finder writes .DS_Store. A bundle
# with no icon is rebuilt, so a run that failed while drawing it retries.
if [ "$FORCE" -eq 0 ] && [ -x "$BIN" ] \
   && [ -f "$RESOURCES/AppIcon.icns" ] \
   && [ -z "$(find "$SRC_DIR" -type f ! -name '.*' -newer "$BIN" -print -quit)" ]; then
  say "Stay Awake up to date"
  exit 0
fi

mkdir -p "$APP_PATH/Contents/MacOS" "$RESOURCES"
cat >"$INFO_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Stay Awake</string>
  <key>CFBundleDisplayName</key><string>Stay Awake</string>
  <key>CFBundleIdentifier</key><string>local.ayushsharma.stay-awake</string>
  <key>CFBundleExecutable</key><string>StayAwake</string>
  <!-- CFBundleIconFile is the pre-macOS-26 path (Resources/AppIcon.icns).
       CFBundleIconName, which points at the appearance-aware icon inside
       Assets.car, is added below only when actool actually produced one. -->
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Menu-bar only: no Dock tile, no app menu. Matches setActivationPolicy(.accessory). -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

say "compiling"
# Compile beside the target and rename it into place: a same-volume rename
# gives the new binary a fresh inode, so the running app keeps its own pages
# until it exits.
if ! "$SWIFTC" -O -whole-module-optimization \
      -framework AppKit -framework IOKit \
      -o "$BIN.new" "$SRC_DIR/main.swift" 2>"$SRC_DIR/.build.log"; then
  say "BUILD FAILED — see $SRC_DIR/.build.log"
  show_log_tail "$SRC_DIR/.build.log" 15
  rm -f "$BIN.new"
  exit 1
fi
chmod +x "$BIN.new"
mv -f "$BIN.new" "$BIN"
rm -f "$SRC_DIR/.build.log"

# ── App icon ─────────────────────────────────────────────────────────────────
# Two products from one source. An Icon Composer .icon package, which actool
# compiles into an Assets.car with separate light and dark artwork (.icns has
# no notion of appearance, so this is the only way to get a dark variant), and
# a legacy AppIcon.icns for macOS before 26. actool ships inside Xcode.app, not
# with the Command Line Tools, so a Mac that has only the CLT gets the .icns
# alone; iconutil does ship with them.

# Compile icon.swift and run it, leaving AppIcon.icon/ and AppIcon.iconset/
# in <work>.
draw_icon() {
  local work=$1
  if ! "$SWIFTC" -O -framework AppKit -o "$work/iconrender" "$SRC_DIR/icon.swift" \
        2>"$work/icon.log"; then
    say "icon renderer FAILED to compile"
    show_log_tail "$work/icon.log" 10
    return 1
  fi
  "$work/iconrender" "$work" || { say "icon renderer FAILED to draw"; return 1; }
}

# The light and dark icon. Fails, leaving the bundle as it was, when actool is
# absent or cannot compile the package.
install_icon_with_actool() {
  local work=$1
  xcrun --find actool >/dev/null 2>&1 || return 1
  # actool refuses to create its own output directory ("The output directory
  # ... does not exist").
  mkdir -p "$work/car"
  # --standalone-icon-behavior all is load-bearing: by default actool writes
  # an .icns holding only the 16 and 128 pt tiles, and Get Info, the Dock and
  # Finder's larger views all want the rest (measured 2026-09-07).
  if xcrun actool "$work/AppIcon.icon" --compile "$work/car" \
        --platform macosx --minimum-deployment-target 26.0 \
        --app-icon AppIcon --standalone-icon-behavior all \
        --output-partial-info-plist "$work/partial.plist" \
        --output-format human-readable-text --errors >"$work/actool.log" 2>&1 \
     && [ -s "$work/car/Assets.car" ] && [ -s "$work/car/AppIcon.icns" ]; then
    cp -f "$work/car/Assets.car" "$RESOURCES/Assets.car"
    cp -f "$work/car/AppIcon.icns" "$RESOURCES/AppIcon.icns"
    /usr/bin/plutil -replace CFBundleIconName -string AppIcon "$INFO_PLIST" >/dev/null 2>&1
    say "icon: Assets.car (light + dark) and AppIcon.icns"
    return 0
  fi
  say "actool could not compile the .icon — using the legacy icns alone"
  show_log_tail "$work/actool.log" 10
  return 1
}

# The light-only icon, for a Mac without actool.
install_icon_with_iconutil() {
  local work=$1
  # Drop any CFBundleIconName an earlier build left behind, or Info.plist
  # would point at an Assets.car that is no longer in the bundle.
  rm -f "$RESOURCES/Assets.car"
  /usr/bin/plutil -remove CFBundleIconName "$INFO_PLIST" >/dev/null 2>&1 || true
  iconutil -c icns -o "$RESOURCES/AppIcon.icns" "$work/AppIcon.iconset" \
    || { say "iconutil FAILED"; return 1; }
  say "icon: AppIcon.icns (no actool — light appearance only)"
}

build_icon() {
  local work=$1
  draw_icon "$work" || return 1
  install_icon_with_actool "$work" || install_icon_with_iconutil "$work"
}

ICON_WORK="$(mktemp -d "${TMPDIR:-/tmp}/stay-awake-icon.XXXXXX")"
build_icon "$ICON_WORK" || say "icon build failed — the bundle keeps the icon it had"
rm -rf "$ICON_WORK"

# Ad-hoc sign so macOS does not kill the app for having no signature at all.
# The signature covers Contents/Resources, so it has to come after the icon;
# writing the icns or the car afterwards would invalidate it.
codesign --force --sign - "$APP_PATH" >/dev/null 2>&1 || true
/usr/bin/xattr -cr "$APP_PATH" 2>/dev/null || true
say "built $APP_PATH"

# The rest is for the installed copy only. A scratch build must not restart
# the installed app's agent, and re-indexing it would register a second,
# possibly short-lived path for the same bundle id with Spotlight and
# LaunchServices.
if [ "$APP_DIR" = "$DEFAULT_APP_DIR" ]; then
  # LaunchServices caches an app's icon against the bundle, and a Finder
  # window showing the old (or blank) icon keeps it until something
  # invalidates that cache. Bumping the mtime and re-indexing does, without
  # restarting Finder.
  touch "$APP_PATH"
  /usr/bin/mdimport "$APP_PATH" >/dev/null 2>&1 || true

  # The LaunchAgent (KeepAlive) is still running the old binary; restart it
  # so the menu bar shows this build now. No agent yet (a first install) is
  # not an error.
  AGENT_TARGET="gui/$(id -u)/$LABEL"
  if launchctl print "$AGENT_TARGET" >/dev/null 2>&1; then
    if launchctl kickstart -k "$AGENT_TARGET" 2>/dev/null; then say "restarted $LABEL"; fi
  fi
fi
exit 0
