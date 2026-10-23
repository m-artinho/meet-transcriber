#!/bin/bash
# Builds bin/meet-capture (the recorder) and bin/app.noindex/Meet Transcriber.app (the menu bar app),
# ad-hoc signed. Each target is skipped if it's newer than its sources (pass
# --force to rebuild both): macOS ties the recorder's mic/system-audio grants to
# its signature, so every rebuild of it can trigger the permission prompts again.
set -euo pipefail
cd "$(dirname "$0")"
FORCE=0; [ "${1:-}" = "--force" ] && FORCE=1
TARGET="$(uname -m)-apple-macos14.2"
mkdir -p bin

stale() { # output sources... -> true if output must be rebuilt
  local out=$1; shift
  [ "$FORCE" = 1 ] || [ ! -e "$out" ] && return 0
  for src in "$@"; do [ "$src" -nt "$out" ] && return 0; done
  return 1
}

# Recorder. Built next to the target and renamed into place, so a recorder
# that is currently running keeps its (still valid) binary.
if stale bin/meet-capture capture/main.swift capture/Info.plist; then
  swiftc -O -swift-version 5 -target "$TARGET" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker capture/Info.plist \
    -o bin/.meet-capture.new capture/main.swift
  codesign --force --sign - --identifier local.meet.capture bin/.meet-capture.new
  mv -f bin/.meet-capture.new bin/meet-capture
  echo "built bin/meet-capture"
else
  echo "bin/meet-capture is up to date"
fi

# Menu bar app. The path of this repo's `meet` script is baked into Info.plist.
APP_NAME="Meet Transcriber"
# *.noindex keeps this build copy out of Spotlight (only the installed one shows up)
APP="bin/app.noindex/$APP_NAME.app"
EXE=MeetTranscriber
ours() { [ "$(defaults read "$1/Contents/Info" CFBundleIdentifier 2>/dev/null)" = local.meet.bar ]; }
if stale "$APP/Contents/MacOS/$EXE" menubar/MeetBar.swift menubar/Info.plist menubar/AppIcon.icns; then
  mkdir -p bin/app.noindex
  # Staged outside the repo: if the repo is in iCloud Drive, its file provider adds
  # Finder info to any .app bundle created there, and codesign rejects that.
  STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
  NEW="$STAGE/new.app"
  mkdir -p "$NEW/Contents/MacOS" "$NEW/Contents/Resources"
  swiftc -O -swift-version 5 -target "$TARGET" -parse-as-library \
    -o "$NEW/Contents/MacOS/$EXE" menubar/MeetBar.swift
  cp menubar/AppIcon.icns "$NEW/Contents/Resources/AppIcon.icns"
  /usr/bin/python3 -c 'import sys; s=open(sys.argv[1]).read(); open(sys.argv[2],"w").write(s.replace("__MEET_CLI__", sys.argv[3]))' \
    menubar/Info.plist "$NEW/Contents/Info.plist" "$PWD/meet"
  # We just built it ourselves: drop extended attributes some parent apps add to
  # new files. codesign rejects them, and a quarantine flag would make macOS run
  # the app from a random translocated path.
  xattr -cr "$NEW" 2>/dev/null || true
  codesign --force --sign - "$NEW"
  rm -rf "$APP" bin/Meet.app "bin/$APP_NAME.app" # (older build locations)
  mv "$NEW" "$APP"
  echo "built $APP"

  # Keep an installed copy (install.sh puts one in ~/Applications) up to date,
  # replacing one installed under the old name (Meet.app).
  INSTALLED="$HOME/Applications/$APP_NAME.app"
  OLD="$HOME/Applications/Meet.app"
  if [ -d "$OLD" ] && ours "$OLD"; then
    pkill -f "Meet.app/Contents/MacOS/Meet" 2>/dev/null || true
    rm -rf "$OLD"
    mkdir -p "$INSTALLED" # marks it for the copy below
    echo "removed the old $OLD"
  fi
  if [ -d "$INSTALLED" ] && { ours "$INSTALLED" || [ -z "$(ls -A "$INSTALLED")" ]; }; then
    rm -rf "$INSTALLED" && cp -R "$APP" "$INSTALLED" && xattr -dr com.apple.quarantine "$INSTALLED" 2>/dev/null || true
    echo "updated $INSTALLED (quit and reopen it to use the new build)"
  fi
else
  echo "$APP is up to date"
fi
