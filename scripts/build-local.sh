#!/usr/bin/env bash
# build-local.sh — build the complete FineWine Patcher.app for local testing.
#
# One entry point for both variants: builds what the chosen target needs, assembles the app and
# verifies it. Every build stage is skipped when its output is newer than its inputs.
#
#   x64:  the x64 Wine modules (build-wine.sh) and x64 MoltenVK (build-moltenvk.sh)
#   arm:  the arm64 MoltenVK (MVK_ARCH=aarch64 build-moltenvk.sh) and the ARM payload
#         (build-wine-arm.sh: ntoskrnl, rundll32, wdfldr, the ARM64X nsi.dll, fwalpha.dylib)
#
# In a terminal this shows one dashboard for the whole build, using scripts/lib/build-ui.sh. Each
# stage's full output goes to build/local-<stage>.log. NO_UI=1 or a pipe prints plain output.
#
# Usage:  scripts/build-local.sh [all|x64|arm]
#   all  (default) build both, and bundle both payloads
#   x64  build only the x64 side, and bundle only the x64 payload
#   arm  build only the ARM side, and bundle it with the x64 payload already in build/ (the app
#        always carries the x64 payload, so run `x64` or `all` once first)
# Env:
#   ARM_MODE  source (default) build patches/ARM with scripts/build-wine-arm.sh.
#             stock            copy CrossOver ARM's own unmodified modules, with no patches.
#             skip             build an x64-only app (same as the `x64` target).
#   ARM_APP   CrossOver ARM to copy from (default "/Applications/CrossOver ARM Preview.app")
#   FORCE=1   rebuild everything the target covers

set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
BUILD_DIR="$REPO/build"
TARGET="${1:-all}"
ARM_MODE="${ARM_MODE:-source}"
ARM_APP="${ARM_APP:-/Applications/CrossOver ARM Preview.app}"
ARM_PAYLOAD="$BUILD_DIR/wine-arm-payload"
FORCE="${FORCE:-0}"
APP="$REPO/patcher-app/build/FineWine Patcher.app"

UI_SELF="$0"
. "$REPO/scripts/lib/build-ui.sh"

die(){ echo "ERROR: $*" >&2; exit 1; }

case "$TARGET" in all|x64|arm) ;; -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "usage: scripts/build-local.sh [all|x64|arm]" ;; esac
case "$ARM_MODE" in stock|source|skip) ;; *) die "ARM_MODE must be stock, source or skip" ;; esac
[ "$TARGET" = "x64" ] && ARM_MODE=skip
[ "$TARGET" = "arm" ] && [ "$ARM_MODE" = "skip" ] && die "the arm target can't use ARM_MODE=skip"
BUILD_X64=1; [ "$TARGET" = "arm" ] && BUILD_X64=0
X64_WINE_OUT="$BUILD_DIR/wine-out/winemac.so"
X64_MVK_OUT="$BUILD_DIR/moltenvk-out/libMoltenVK.dylib"
ARM_MVK_OUT="$BUILD_DIR/moltenvk-out-aarch64/libMoltenVK.dylib"
if [ "$BUILD_X64" = 0 ]; then
  for f in "$X64_WINE_OUT" "$X64_MVK_OUT"; do
    [ -f "$f" ] || die "no x64 payload at $f. The app always carries it: run scripts/build-local.sh x64 first"
  done
fi
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
ui_init "FineWine — patcher build: $TARGET (ARM: $ARM_MODE, $(xcodebuild -version | head -1))"
if [ "$UI_ACTIVE" = 1 ]; then
  trap 'on_interrupt 130' INT
  trap 'on_interrupt 143' TERM
fi
ui_plan wine     70 "Building the x64 Wine modules"
ui_plan moltenvk 18 "Building x64 MoltenVK"
ui_plan mvk-arm  18 "Building arm64 MoltenVK"
ui_plan arm      30 "Building the ARM payload ($ARM_MODE)"
ui_plan app       5 "Assembling FineWine Patcher.app"
ui_plan verify    1 "Verifying the bundled payload"

ui_begin wine
if [ "$BUILD_X64" = 0 ]; then
  skip_stage "not in the arm target; using build/wine-out"
elif stale "$X64_WINE_OUT" patches/x64/stage1-macos patches/x64/stage2-dwproton scripts/build-wine.sh; then
  run_stage wine "scripts/build-wine.sh all" ./scripts/build-wine.sh all
else
  skip_stage "up to date"
fi

ui_begin moltenvk
if [ "$BUILD_X64" = 0 ]; then
  skip_stage "not in the arm target; using build/moltenvk-out"
elif stale "$X64_MVK_OUT" patches/x64/moltenvk scripts/build-moltenvk.sh; then
  run_stage moltenvk "scripts/build-moltenvk.sh all" ./scripts/build-moltenvk.sh all
else
  skip_stage "up to date"
fi

# The ARM payload bundles the arm64 MoltenVK, so it comes first. Same patches as x64.
ui_begin mvk-arm
if [ "$ARM_MODE" != "source" ]; then
  skip_stage "not needed for ARM_MODE=$ARM_MODE"
elif stale "$ARM_MVK_OUT" patches/x64/moltenvk scripts/build-moltenvk.sh; then
  run_stage mvk-arm "MVK_ARCH=aarch64 scripts/build-moltenvk.sh all" env MVK_ARCH=aarch64 ./scripts/build-moltenvk.sh all
else
  skip_stage "up to date"
fi

# The ARM build fetches a fresh Wine source each time, so it only runs when something changed.
# nsi.dll is the last module it adds, and fwalpha.dylib comes from the payload step after it.
ui_begin arm
case "$ARM_MODE" in
  stock)
    rm -rf "$ARM_PAYLOAD"
    run_stage arm-stock "copying stock CrossOver ARM modules" copy_stock_arm_modules ;;
  source)
    if stale "$ARM_PAYLOAD/aarch64-unix/fwalpha.dylib" patches/ARM scripts/build-wine-arm.sh "$ARM_MVK_OUT" \
       || [ ! -f "$ARM_PAYLOAD/aarch64-windows/nsi.dll" ]; then
      rm -rf "$ARM_PAYLOAD"
      run_stage arm-source "scripts/build-wine-arm.sh all" ./scripts/build-wine-arm.sh all
    else
      skip_stage "up to date"
    fi ;;
  skip) skip_stage "skipped" ;;
esac

ui_begin app
export PAYLOAD_DIR="$BUILD_DIR/wine-out" MOLTENVK_DIR="$BUILD_DIR/moltenvk-out"
# An x64-only build leaves any ARM payload in build/ alone but doesn't bundle it.
if [ "$ARM_MODE" = "skip" ]; then export ARM_PAYLOAD_DIR="$BUILD_DIR/.no-arm-payload"; fi
run_stage app "patcher-app/scripts/build-app.sh" ./patcher-app/scripts/build-app.sh

ui_begin verify
run_stage verify "verify-app-payload.py" python3 patcher-app/scripts/verify-app-payload.py "$APP"
ui_finish

echo
if [ "$UI_ACTIVE" = 1 ]; then cat "$BUILD_DIR/local-verify.log"; fi
echo "Built: $APP"
[ "$ARM_MODE" = "skip" ] || echo "NOTE: the ARM payload is for testing. It isn't expected to get past ACE yet."
