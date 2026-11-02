#!/usr/bin/env bash
# build-local.sh — build the complete FineWine Patcher.app for local testing.
#
# Builds the x64 Wine modules and MoltenVK, adds an ARM payload, assembles the app and verifies it.
# Each x64 stage is skipped when its output is newer than its inputs.
#
# In a terminal this shows one dashboard for the whole build, using scripts/lib/build-ui.sh. Each
# stage's full output goes to build/local-<stage>.log. NO_UI=1 or a pipe prints plain output.
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

UI_SELF="$0"
. "$REPO/scripts/lib/build-ui.sh"

die(){ echo "ERROR: $*" >&2; exit 1; }

case "$ARM_MODE" in stock|source|skip) ;; *) die "ARM_MODE must be stock, source or skip" ;; esac
if [ "$ARM_MODE" = "stock" ] && [ ! -d "$ARM_APP" ]; then
  die "$ARM_APP not found. Install CrossOver ARM, or use ARM_MODE=skip"
fi

# True when $1 is missing, or anything under the remaining paths is newer than it.
stale(){
  local output="$1"; shift
  [ "$FORCE" = "1" ] || [ ! -f "$output" ] || [ -n "$(find "$@" -type f -newer "$output" -print -quit)" ]
}

# Runs one stage's command, with progress learned from the same stage's last successful run.
run_stage(){ # stage sublabel cmd args...
  local stage="$1" sub="$2" log="$BUILD_DIR/local-$1.log" lines="$BUILD_DIR/.ui-local-$1-lines"; shift 2
  UI_LINES_TOTAL=0
  [ -f "$lines" ] && UI_LINES_TOTAL="$(cat "$lines")"
  ui_run "$log" "$sub" "$@" || { ui_end 1; echo "Full log: $log" >&2; exit 1; }
  ui_learn "$lines" "$(wc -l < "$log" | tr -d ' ')"
  ui_end
}

skip_stage(){ # reason
  [ "$UI_ACTIVE" = 1 ] || echo "$1"
  ui_skip
}

# A dashboard stage runs in the background, where it ignores Ctrl-C, and the library only stops its
# direct child. Stop the whole tree so an interrupted build doesn't leave make running.
stop_tree(){ # pid
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do stop_tree "$child"; done
  kill "$1" 2>/dev/null || true
}
on_interrupt(){ # exit status
  if [ -n "${UI_PID:-}" ]; then stop_tree "$UI_PID"; fi
  ui_cleanup
  exit "$1"
}

copy_stock_arm_modules(){
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
    source = os.path.join(root, app_path)
    if os.path.exists(source):  # wdfldr.sys is ours, and stock CrossOver ARM doesn't ship it.
        shutil.copy2(source, target)
print(f"copied {len(pairs)} unmodified modules")
PY
}

# MoltenVK needs full Xcode, and SwiftUI's macros aren't available under the Command Line Tools.
if ! xcodebuild -version >/dev/null 2>&1; then
  xcode="$(ls -d /Applications/Xcode*.app 2>/dev/null | grep -v Xcodes | sort -V | tail -1 || true)"
  [ -n "$xcode" ] || die "full Xcode is required"
  export DEVELOPER_DIR="$xcode/Contents/Developer"
fi

mkdir -p "$BUILD_DIR"
ui_init "FineWine — complete patcher build (ARM: $ARM_MODE, $(xcodebuild -version | head -1))"
if [ "$UI_ACTIVE" = 1 ]; then
  trap 'on_interrupt 130' INT
  trap 'on_interrupt 143' TERM
fi
ui_plan wine     70 "Building the x64 Wine modules"
ui_plan moltenvk 18 "Building x64 MoltenVK"
ui_plan arm       6 "Building the ARM payload ($ARM_MODE)"
ui_plan app       5 "Assembling FineWine Patcher.app"
ui_plan verify    1 "Verifying the bundled payload"

ui_begin wine
if stale "$BUILD_DIR/wine-out/winemac.so" patches/x64/stage1-macos patches/x64/stage2-dwproton scripts/build-wine.sh; then
  run_stage wine "scripts/build-wine.sh all" ./scripts/build-wine.sh all
else
  skip_stage "up to date"
fi

ui_begin moltenvk
if stale "$BUILD_DIR/moltenvk-out/libMoltenVK.dylib" patches/x64/moltenvk scripts/build-moltenvk.sh; then
  run_stage moltenvk "scripts/build-moltenvk.sh all" ./scripts/build-moltenvk.sh all
else
  skip_stage "up to date"
fi

ui_begin arm
rm -rf "$ARM_PAYLOAD"
case "$ARM_MODE" in
  stock)  run_stage arm-stock "copying stock CrossOver ARM modules" copy_stock_arm_modules ;;
  source) run_stage arm-source "scripts/build-wine-arm.sh all" ./scripts/build-wine-arm.sh all ;;
  skip)   skip_stage "skipped" ;;
esac

ui_begin app
export PAYLOAD_DIR="$BUILD_DIR/wine-out" MOLTENVK_DIR="$BUILD_DIR/moltenvk-out"
run_stage app "patcher-app/scripts/build-app.sh" ./patcher-app/scripts/build-app.sh

ui_begin verify
run_stage verify "verify-app-payload.py" python3 patcher-app/scripts/verify-app-payload.py "$APP"
ui_finish

echo
if [ "$UI_ACTIVE" = 1 ]; then cat "$BUILD_DIR/local-verify.log"; fi
echo "Built: $APP"
[ "$ARM_MODE" = "skip" ] || echo "NOTE: the ARM payload is for testing. It isn't expected to get past ACE yet."
