#!/bin/bash
# Builds bin/meet-capture (Swift helper) and ad-hoc signs it. Skips the build if
# the binary is newer than its sources (pass --force to rebuild anyway), because
# macOS ties the mic/system-audio grants to the signature: every rebuild can
# trigger the permission prompts again.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
if [ "${1:-}" != "--force" ] && [ -x bin/meet-capture ] \
   && [ bin/meet-capture -nt capture/main.swift ] && [ bin/meet-capture -nt capture/Info.plist ]; then
  echo "bin/meet-capture is up to date"
  exit 0
fi
# Build next to the target and rename into place, so a recorder that is
# currently running keeps its (still valid) binary.
swiftc -O -swift-version 5 \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker capture/Info.plist \
  -o bin/.meet-capture.new capture/main.swift
codesign --force --sign - --identifier local.meet.capture bin/.meet-capture.new
mv -f bin/.meet-capture.new bin/meet-capture
echo "built bin/meet-capture"
