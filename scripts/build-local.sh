#!/usr/bin/env bash
# build-local.sh — build the complete FineWine Patcher.app for local testing.
#
# Builds the x64 Wine modules and MoltenVK, adds an ARM payload, assembles the app and verifies it.
# Each x64 stage is skipped when its output is newer than its inputs.
#
# Usage:  scripts/build-local.sh
# Env:
#   ARM_MODE  source (default) build patches/ARM with scripts/build-wine-arm.sh.
#             stock            copy CrossOver ARM's own unmodified modules, with no patches.
#             skip             build an x64-only app.
#   ARM_APP   CrossOver ARM to copy from (default "/Applications/CrossOver ARM Preview.app")
#   FORCE=1   rebuild everything
#
# ARM payloads are for local testing. CI doesn't build one, so they can't reach a release.

set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
BUILD_DIR="$REPO/build"
ARM_MODE="${ARM_MODE:-source}"
ARM_APP="${ARM_APP:-/Applications/CrossOver ARM Preview.app}"
ARM_PAYLOAD="$BUILD_DIR/wine-arm-payload"
FORCE="${FORCE:-0}"
APP="$REPO/patcher-app/build/FineWine Patcher.app"

log(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

case "$ARM_MODE" in stock|source|skip) ;; *) die "ARM_MODE must be stock, source or skip" ;; esac

# True when $1 is missing, or anything under the remaining paths is newer than it.
stale(){
  local output="$1"; shift
  [ "$FORCE" = "1" ] || [ ! -f "$output" ] || [ -n "$(find "$@" -type f -newer "$output" -print -quit)" ]
}

# MoltenVK needs full Xcode, and SwiftUI's macros aren't available under the Command Line Tools.
if ! xcodebuild -version >/dev/null 2>&1; then
  xcode="$(ls -d /Applications/Xcode*.app 2>/dev/null | grep -v Xcodes | sort -V | tail -1 || true)"
  [ -n "$xcode" ] || die "full Xcode is required"
  export DEVELOPER_DIR="$xcode/Contents/Developer"
fi
echo "Xcode: $(xcodebuild -version | head -1)"

log "x64 Wine modules"
if stale "$BUILD_DIR/wine-out/winemac.so" patches/x64/stage1-macos patches/x64/stage2-dwproton scripts/build-wine.sh; then
  ./scripts/build-wine.sh all
else
  echo "up to date"
fi

log "x64 MoltenVK"
if stale "$BUILD_DIR/moltenvk-out/libMoltenVK.dylib" patches/x64/moltenvk scripts/build-moltenvk.sh; then
  ./scripts/build-moltenvk.sh all
else
  echo "up to date"
fi

log "ARM payload ($ARM_MODE)"
rm -rf "$ARM_PAYLOAD"
case "$ARM_MODE" in
  stock)
    [ -d "$ARM_APP" ] || die "$ARM_APP not found. Install CrossOver ARM, or use ARM_MODE=skip"
    python3 - "$ARM_APP/Contents/SharedSupport/CrossOver" "$ARM_PAYLOAD" <<'PY'
import os, re, shutil, sys
root, payload = sys.argv[1:]
source = open("patcher-app/Sources/FineWinePatcher/PatcherEngine.swift", encoding="utf-8").read()
body = source[source.index("var modules: [PayloadModule]"):]
arm = body[body.index("case .arm:"):body.index("enum Payload")]
pairs = re.findall(r'payloadSubpath: "([^"]+)",\s*crossoverSubpath: "([^"]+)"', arm)
if not pairs:
    sys.exit("no ARM modules found in PatcherEngine.swift")
for payload_path, app_path in pairs:
    target = os.path.join(payload, payload_path)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    shutil.copy2(os.path.join(root, app_path), target)
print(f"copied {len(pairs)} unmodified modules")
PY
    ;;
  source)
    ./scripts/build-wine-arm.sh all
    ;;
  skip) echo "skipped" ;;
esac

log "FineWine Patcher.app"
PAYLOAD_DIR="$BUILD_DIR/wine-out" MOLTENVK_DIR="$BUILD_DIR/moltenvk-out" ./patcher-app/scripts/build-app.sh

log "Verifying the bundled payload"
python3 patcher-app/scripts/verify-app-payload.py "$APP"

echo
echo "Built: $APP"
[ "$ARM_MODE" = "skip" ] || echo "NOTE: the ARM payload is for testing. It isn't expected to get past ACE yet."
