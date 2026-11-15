#!/bin/bash
# Builds FineWine's stand-in for the Steam client (runtime-extras/steam-helper) into a runtime:
#   <runtime>/share/finewine/steam/steam.exe
# It is an x64 program: the games that need it are. Needs the llvm-mingw compiler that
# scripts/build-fex.sh downloads; without it the helper is left out and FineWine runs those
# games directly.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?usage: build-steam-helper.sh <runtime folder>}"
CC="$REPO/build/llvm-mingw/bin/x86_64-w64-mingw32-clang"
if [ ! -x "$CC" ]; then
  echo "steam helper skipped: no llvm-mingw in build/ (scripts/build-fex.sh toolchain)"
  exit 0
fi
mkdir -p "$OUT/share/finewine/steam"
"$CC" -O2 -municode -mwindows -o "$OUT/share/finewine/steam/steam.exe" \
  "$REPO/runtime-extras/steam-helper/steam.c" -lntdll
echo "steam helper: $OUT/share/finewine/steam/steam.exe"
