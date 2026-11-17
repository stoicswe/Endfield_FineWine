#!/usr/bin/env bash
# stamp-sdk-version.sh <Mach-O binary> <oldest macOS> — records the SDK an app was really built
# with in its binary (LC_BUILD_VERSION), keeping its oldest macOS.
#
# Why: SwiftPM's link step records the deployment target as the SDK version too (a binary for
# macOS 15 built with the macOS 27.3 SDK said "sdk 15.0"). macOS decides from that field how to
# draw an app, and draws one built against an SDK older than 26 the way macOS 15 did: no Liquid
# Glass, the old title bar and sidebar, the old controls, whatever the code asks for. Run it on
# the executable before the app is signed (it changes the binary).
set -euo pipefail
bin="${1:?usage: stamp-sdk-version.sh <binary> <oldest macOS>}"
min="${2:?usage: stamp-sdk-version.sh <binary> <oldest macOS>}"
sdk="$(xcrun --sdk macosx --show-sdk-version)"
tmp="$bin.stamp.$$"
xcrun vtool -set-build-version macos "$min" "$sdk" -replace -output "$tmp" "$bin"
mv -f "$tmp" "$bin"
recorded="$(otool -l "$bin" | awk '/LC_BUILD_VERSION/{f=1} f&&/ sdk /{print $2; exit}')"
[ "$recorded" = "$sdk" ] || { echo "ERROR: $bin still says sdk $recorded (wanted $sdk)" >&2; exit 1; }
echo "  sdk $sdk recorded in $(basename "$bin") (oldest macOS $min)"
