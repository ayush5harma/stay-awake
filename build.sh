#!/usr/bin/env bash
# Build "Stay Awake.app" — the clamshell/KVM keep-awake toggle — from the two
# Swift files under Sources/, and install it to /Applications by default.
# One swiftc, no Xcode project, ad-hoc signed, mtime-guarded so re-running
# this script costs pennies when nothing under Sources/ changed. Its icon is
# drawn from Sources/icon.swift at build time (no binary asset in the repo).
# --force rebuilds unconditionally.
#
# Override the install location with APP_DIR (the app's parent directory,
# e.g. APP_DIR=/tmp/scratch for a throwaway build) and the bundle/app name
# with APP_NAME. When the output directory is not the default, the script
# does NOT restart the launchd agent — a scratch build must not take over
# the menu bar out from under the installed app.

set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/Sources" && pwd)"
APP_NAME="${APP_NAME:-Stay Awake}"
DEFAULT_OUT="/Applications"
OUT_DIR="${APP_DIR:-$DEFAULT_OUT}"
APP_DIR="$OUT_DIR/${APP_NAME}.app"
BIN="$APP_DIR/Contents/MacOS/StayAwake"
AGENT="com.ayushsharma.stay-awake"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

say() { printf '  %s\n' "$*"; }

# A path is not a compiler: /usr/bin/swiftc is a shim that exists on every
# Mac and fails until the Xcode Command Line Tools are installed, so the
# guard must run it rather than just check for the path. Exit 0 either way —
# the caller decides what a missing toolchain means for them.
SWIFTC="$(command -v swiftc 2>/dev/null || xcrun --find swiftc 2>/dev/null)"
[ -n "$SWIFTC" ] && "$SWIFTC" --version >/dev/null 2>&1 \
  || { say "swiftc not usable — install the Xcode Command Line Tools (xcode-select --install)"; exit 0; }

# Skip when nothing under Sources/ is newer than the installed binary. EVERY
# file counts, not just main.swift: a guard that watches only that one lets an
# edit to this script or to icon.swift compile locally and never reach
# /Applications. Dot-files are excluded because this script writes
# .build.log itself and Finder writes .DS_Store. A bundle with no icon also
# rebuilds, so a run that failed midway through the artwork retries.
if [ "$FORCE" -eq 0 ] && [ -x "$BIN" ] \
   && [ -f "$APP_DIR/Contents/Resources/AppIcon.icns" ] \
   && [ -z "$(find "$SRC_DIR" -type f ! -name '.*' -newer "$BIN" -print -quit)" ]; then
  say "Stay Awake up to date"
  exit 0
fi

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cat >"$APP_DIR/Contents/Info.plist" <<'PLIST'
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
# Compile beside the target and rename into place: a same-volume rename gives
# the new build a fresh inode, and the RUNNING app keeps its pages until exit.
if ! "$SWIFTC" -O -whole-module-optimization \
      -framework AppKit -framework IOKit \
      -o "$BIN.new" "$SRC_DIR/main.swift" 2>"$SRC_DIR/.build.log"; then
  say "BUILD FAILED — see $SRC_DIR/.build.log"
  tail -15 "$SRC_DIR/.build.log" | sed 's/^/      /'
  rm -f "$BIN.new"
  exit 1
fi
chmod +x "$BIN.new"
mv -f "$BIN.new" "$BIN"
rm -f "$SRC_DIR/.build.log"

# ── App icon ─────────────────────────────────────────────────────────────────
# Drawn from icon.swift at build time, so no binary asset lives in the repo.
# TWO products from that one source: an Icon Composer .icon package, which
# actool compiles into an Assets.car carrying separate light and dark artwork
# (the .icns format has no notion of appearance, so this is the only way to get
# a dark variant at all), and a legacy AppIcon.icns for everything before
# macOS 26. actool ships inside Xcode.app and NOT with the Command Line Tools,
# so a bootstrapping Mac that has only the CLT falls back to the icns alone —
# iconutil does ship with them.
build_icon() {
  local work res plist
  work="$1"
  res="$APP_DIR/Contents/Resources"
  plist="$APP_DIR/Contents/Info.plist"

  if ! "$SWIFTC" -O -framework AppKit -o "$work/iconrender" "$SRC_DIR/icon.swift" \
        2>"$work/icon.log"; then
    say "icon renderer FAILED to compile"
    sed 's/^/      /' "$work/icon.log" | tail -10
    return 1
  fi
  "$work/iconrender" "$work" || { say "icon renderer FAILED to draw"; return 1; }

  if xcrun --find actool >/dev/null 2>&1; then
    # actool refuses to create its own output directory ("The output directory
    # ... does not exist"), so make it first.
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
      cp -f "$work/car/Assets.car" "$res/Assets.car"
      cp -f "$work/car/AppIcon.icns" "$res/AppIcon.icns"
      /usr/bin/plutil -replace CFBundleIconName -string AppIcon "$plist" >/dev/null 2>&1
      say "icon: Assets.car (light + dark) and AppIcon.icns"
      return 0
    fi
    say "actool could not compile the .icon — using the legacy icns alone"
    sed 's/^/      /' "$work/actool.log" | tail -10
  fi

  # Legacy path. Drop any CFBundleIconName an earlier build left behind, or the
  # plist would point at an Assets.car that is no longer in the bundle.
  rm -f "$res/Assets.car"
  /usr/bin/plutil -remove CFBundleIconName "$plist" >/dev/null 2>&1 || true
  iconutil -c icns -o "$res/AppIcon.icns" "$work/AppIcon.iconset" \
    || { say "iconutil FAILED"; return 1; }
  say "icon: AppIcon.icns (no actool — light appearance only)"
}

ICON_WORK="$(mktemp -d "${TMPDIR:-/tmp}/stay-awake-icon.XXXXXX")"
build_icon "$ICON_WORK" || say "icon build failed — the bundle keeps the icon it had"
rm -rf "$ICON_WORK"

# Ad-hoc sign so macOS does not kill it for having no signature at all. It runs
# AFTER the icon lands: the signature covers Contents/Resources, so writing the
# icns or the car afterwards would invalidate it.
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true
/usr/bin/xattr -cr "$APP_DIR" 2>/dev/null || true
say "built $APP_DIR"

# Everything below only matters for the real installed copy, so it shares the
# scratch-build guard with the kickstart: mdimport would index a SECOND path
# under this same bundle's CFBundleIdentifier, which pollutes Spotlight and
# LaunchServices lookups for the id with an ephemeral scratch location that
# may not even exist a moment later, and a scratch build must not restart the
# installed app's agent either.
if [ "$OUT_DIR" = "$DEFAULT_OUT" ]; then
  # Bump the bundle's mtime and re-index it. LaunchServices caches an app's
  # icon against the bundle, and a Finder window already showing the old (or
  # blank) one keeps showing it until something invalidates that cache; these
  # two are what does it without asking anyone to killall Finder.
  touch "$APP_DIR"
  /usr/bin/mdimport "$APP_DIR" >/dev/null 2>&1 || true

  # The launchd agent (KeepAlive) is still running the OLD binary; kick it so
  # the menu bar shows this build now. Guarded: no agent yet (a fresh
  # machine, a first install) is not an error.
  if launchctl print "gui/$(id -u)/$AGENT" >/dev/null 2>&1; then
    launchctl kickstart -k "gui/$(id -u)/$AGENT" 2>/dev/null && say "restarted $AGENT" || true
  fi
fi
exit 0
