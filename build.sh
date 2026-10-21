#!/bin/bash
# Builds bin/meet-capture (the recorder) and bin/Meet.app (the menu bar app),
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
APP=bin/Meet.app
if stale "$APP/Contents/MacOS/Meet" menubar/MeetBar.swift menubar/Info.plist; then
  NEW=bin/.Meet.app.new
  rm -rf "$NEW"
  mkdir -p "$NEW/Contents/MacOS"
  swiftc -O -swift-version 5 -target "$TARGET" -parse-as-library \
    -o "$NEW/Contents/MacOS/Meet" menubar/MeetBar.swift
  /usr/bin/python3 -c 'import sys; s=open(sys.argv[1]).read(); open(sys.argv[2],"w").write(s.replace("__MEET_CLI__", sys.argv[3]))' \
    menubar/Info.plist "$NEW/Contents/Info.plist" "$PWD/meet"
  codesign --force --sign - "$NEW"
  # We just built it ourselves; a quarantine flag (set by some parent apps on new
  # files) would make macOS run it from a random translocated path.
  xattr -dr com.apple.quarantine "$NEW" 2>/dev/null || true
  rm -rf "$APP"
  mv "$NEW" "$APP"
  echo "built $APP"
  # Keep an installed copy (install.sh puts one in ~/Applications) up to date.
  INSTALLED="$HOME/Applications/Meet.app"
  if [ -d "$INSTALLED" ] && [ "$(defaults read "$INSTALLED/Contents/Info" CFBundleIdentifier 2>/dev/null)" = local.meet.bar ]; then
    rm -rf "$INSTALLED" && cp -R "$APP" "$INSTALLED" && xattr -dr com.apple.quarantine "$INSTALLED" 2>/dev/null || true
    echo "updated $INSTALLED (quit and reopen Meet to use it)"
  fi
else
  echo "$APP is up to date"
fi
