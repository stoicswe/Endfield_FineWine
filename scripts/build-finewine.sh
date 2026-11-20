#!/usr/bin/env bash
# build-finewine.sh — build everything FineWine is made of, and nothing of the patcher:
#
#   1. MoltenVK, FineWine flavour (ray tracing, MetalFX)     scripts/build-moltenvk.sh
#   2. the Windows compiler for x64 parts (llvm-mingw)       scripts/build-fex.sh toolchain
#   3. the Wine runtime, from a fresh source tree            scripts/build-finewine-runtime.sh all
#      (with the bridge to the Mac's Steam client           scripts/build-steam-bridge.sh)
#   4. FEX (x64 programs)                                    scripts/build-fex.sh all
#   5. DXMT (Direct3D 10 and 11 on Metal)                    scripts/build-dxmt.sh all
#   6. the runtime checks                                    scripts/test-finewine-runtime.sh
#   7. the runtime's release archive                         scripts/build-finewine-runtime.sh archive
#   8. FineWine.app, with the runtime inside it              finewine-app/scripts/build-app.sh
#
# The order matters: the runtime's packaging picks MoltenVK up and needs the compiler from
# step 2 for the Steam stand-in; FEX and DXMT install themselves into the packaged runtime.
# A failure stops the script. The runtime in build/finewine-runtime is only replaced once the
# new one has been built.
#
# Usage:  scripts/build-finewine.sh [all|runtime|app]
#   all      (default) steps 1-8
#   runtime  steps 1-7
#   app      step 8 only
# Env:
#   SKIP_TESTS=1    skip step 6 (and the app's unit tests)
#   SKIP_ARCHIVE=1  skip step 7
#   FINEWINE_VERSION, CODESIGN_ID, ICON_VARIANT   for FineWine.app, as in its build-app.sh
#   JOBS, WINE_TAG, RUNTIME_VERSION               for the runtime, as in its script
#   DEVELOPER_DIR   the Xcode to use; found in /Applications when xcode-select points at the
#                   command line tools
#
# From scratch this takes well over an hour (DXMT builds LLVM once, the runtime about 40 minutes).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-all}"
case "$TARGET" in
  all|runtime|app) ;;
  *) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

log(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }
started=$(date +%s)

# MoltenVK and the app need the full Xcode (xcodebuild), not just the command line tools. If
# the selected developer directory is the command line tools, use the newest released Xcode in
# /Applications for this run only; DEVELOPER_DIR, when set, is left alone.
if [ -z "${DEVELOPER_DIR:-}" ] && ! xcodebuild -version >/dev/null 2>&1; then
  # A released Xcode before a beta one.
  xcode="$(ls -d /Applications/Xcode*.app/Contents/Developer 2>/dev/null | grep -vi beta | sort -V | tail -n 1 || true)"
  [ -n "$xcode" ] || xcode="$(ls -d /Applications/Xcode*.app/Contents/Developer 2>/dev/null | sort -V | tail -n 1 || true)"
  [ -n "$xcode" ] || { echo "ERROR: Xcode is needed (xcodebuild); only the command line tools are installed." >&2; exit 1; }
  export DEVELOPER_DIR="$xcode"
  echo "using Xcode at $DEVELOPER_DIR (xcode-select points at the command line tools)"
fi

if [ "$TARGET" != "app" ]; then
  log "1/8 MoltenVK (FineWine flavour)"
  MVK_FLAVOR=finewine "$REPO/scripts/build-moltenvk.sh" all
  log "2/8 Windows compiler"
  "$REPO/scripts/build-fex.sh" toolchain
  log "3/8 Wine runtime"
  "$REPO/scripts/build-finewine-deps.sh"
  "$REPO/scripts/build-finewine-runtime.sh" all
  log "4/8 FEX"
  "$REPO/scripts/build-fex.sh" all
  log "5/8 DXMT"
  "$REPO/scripts/build-dxmt.sh" all
  # Everything that ships, now that FEX and DXMT are in: the runtime runs on macOS 15 and later.
  "$REPO/scripts/lib/check-macos-compat.sh" 15.0 "$REPO/build/finewine-runtime/bin" "$REPO/build/finewine-runtime/lib"
  if [ "${SKIP_TESTS:-0}" != "1" ]; then
    log "6/8 Runtime checks"
    "$REPO/scripts/test-finewine-runtime.sh"
  fi
  if [ "${SKIP_ARCHIVE:-0}" != "1" ]; then
    log "7/8 Runtime archive"
    "$REPO/scripts/build-finewine-runtime.sh" archive
  fi
fi

if [ "$TARGET" != "runtime" ]; then
  log "8/8 FineWine.app"
  # FineWine's version is its own: only an explicit FINEWINE_VERSION reaches its build.
  ( unset VERSION; [ -n "${FINEWINE_VERSION:-}" ] && export VERSION="$FINEWINE_VERSION"
    BUNDLE_RUNTIME="${BUNDLE_RUNTIME:-required}" "$REPO/finewine-app/scripts/build-app.sh" )
fi

log "Built in $(( ($(date +%s) - started) / 60 )) min"
[ "$TARGET" = "app" ]     || echo "  $REPO/build/finewine-runtime   (add it in FineWine: Settings > Add Runtime…)"
[ "$TARGET" = "runtime" ] || echo "  $REPO/finewine-app/build/FineWine.app"
