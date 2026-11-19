#!/bin/bash
# Builds the program that lets Discord find a Windows game by its file name
# (runtime-extras/presence-helper) into a runtime:
#   <runtime>/lib/wine/aarch64-unix/finewine-presence
# The Mac driver copies it under each game's own file name and starts it (runtime patch 0039).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?usage: build-presence-helper.sh <runtime folder> [minimum macOS]}"
MIN="${2:-15.0}"
DEST="$OUT/lib/wine/aarch64-unix/finewine-presence"
/usr/bin/clang -arch arm64 -mmacosx-version-min="$MIN" -O2 -fobjc-arc -Wall \
  -o "$DEST" "$REPO/runtime-extras/presence-helper/presence.m" -framework AppKit
strip -x "$DEST"
codesign --force --sign - "$DEST" 2>/dev/null
echo "presence helper: $DEST"
