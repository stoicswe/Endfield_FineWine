#!/usr/bin/env bash
# Build patched MoltenVK into build/moltenvk-out.
#
# Usage:
#   scripts/build-moltenvk.sh [all]    # fetch -> apply -> deps -> build
#   scripts/build-moltenvk.sh <step>   # fetch | apply | deps | build
#
# Env: MVK_TAG (default v1.4.2, the patch target),
#      MVK_ARCH (default x86_64 — CrossOver 26.x loads the x86_64 build; the ARM/aarch64
#               pipeline sets MVK_ARCH=aarch64),
#      BUILD_DIR (default <repo>/build)
# Needs full Xcode; set DEVELOPER_DIR if xcode-select points at the Command Line Tools.
#
# Output: in a terminal, steps render as a live dashboard (checklist, progress bars, a tail of the
# current step's log; see scripts/lib/build-ui.sh) and each step's FULL output lands in
# build/*.log. On CI / pipes the plain "==>" + tee output is used instead (NO_UI=1 forces it).

set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
MVK_TAG="${MVK_TAG:-v1.4.2}"
MVK_ARCH="${MVK_ARCH:-x86_64}"
BUILD_DIR="${BUILD_DIR:-$REPO/build}"
MVK_SRC="$BUILD_DIR/moltenvk-src"
SPVC_SRC="$BUILD_DIR/spirv-cross-src"      # patched, linked into MoltenVK's External/
VKH_SRC="$BUILD_DIR/vulkan-headers-src"
# Keep the x86_64 output path stable (build/moltenvk-out); suffix only non-default arches.
if [ "$MVK_ARCH" = "x86_64" ]; then
  MVK_OUT="${MVK_OUT:-$BUILD_DIR/moltenvk-out}"
else
  MVK_OUT="${MVK_OUT:-$BUILD_DIR/moltenvk-out-$MVK_ARCH}"
fi
P="$REPO/patches/moltenvk"

# Terminal dashboard (progress bars + live log tail). Must be sourced before any
# real work so `zsh scripts/build-moltenvk.sh` can hand over to /bin/bash cleanly.
UI_SELF="$0"
. "$REPO/scripts/lib/build-ui.sh"

# shallow-clone <url> <ref> <dir> via sh -c (ui_run cannot call shell functions)
CLONE='git init -q "$3" && git -C "$3" fetch -q --depth 1 "$1" "$2" && git -C "$3" checkout -q FETCH_HEAD'

_learned() { # file — load a line total learned from a previous successful build
  UI_LINES_TOTAL=0
  [ -f "$1" ] && UI_LINES_TOTAL="$(cat "$1" 2>/dev/null)"
  case "$UI_LINES_TOTAL" in ''|*[!0-9]*) UI_LINES_TOTAL=0 ;; esac
  return 0
}

cmd_fetch() {
  ui_begin fetch 12 "Fetching MoltenVK $MVK_TAG and its pinned SPIRV-Cross and Vulkan-Headers"
  mkdir -p "$BUILD_DIR"; rm -rf "$MVK_SRC" "$SPVC_SRC" "$VKH_SRC"
  local rev="$MVK_SRC/ExternalRevisions"
  ui_run "$BUILD_DIR/clone-moltenvk.log" "cloning MoltenVK $MVK_TAG (depth 1)" \
    sh -c "$CLONE" ui_sh "https://github.com/KhronosGroup/MoltenVK.git" "refs/tags/$MVK_TAG" "$MVK_SRC" \
    || { echo "MoltenVK clone failed — see $BUILD_DIR/clone-moltenvk.log"; exit 1; }
  ui_run "$BUILD_DIR/clone-spirv-cross.log" "cloning SPIRV-Cross (pinned revision, depth 1)" \
    sh -c "$CLONE" ui_sh "https://github.com/KhronosGroup/SPIRV-Cross.git" \
    "$(cat "$rev/SPIRV-Cross_repo_revision")" "$SPVC_SRC" \
    || { echo "SPIRV-Cross clone failed — see $BUILD_DIR/clone-spirv-cross.log"; exit 1; }
  ui_run "$BUILD_DIR/clone-vulkan-headers.log" "cloning Vulkan-Headers (pinned revision, depth 1)" \
    sh -c "$CLONE" ui_sh "https://github.com/KhronosGroup/Vulkan-Headers.git" \
    "$(cat "$rev/Vulkan-Headers_repo_revision")" "$VKH_SRC" \
    || { echo "Vulkan-Headers clone failed — see $BUILD_DIR/clone-vulkan-headers.log"; exit 1; }
  ui_end
}

cmd_apply() {
  ui_begin apply 1 "Applying patches/moltenvk"
  [ -d "$MVK_SRC/.git" ] || { echo "run 'fetch' first"; exit 1; }
  local list n unit
  list=$(ls "$P"/spirv-cross/*.patch 2>/dev/null)
  # shellcheck disable=SC2086 # patch paths contain no spaces
  set -- $list
  n=$#; unit="patches"; [ "$n" -eq 1 ] && unit="patch"
  UI_LINES_RE='^applying '; UI_LINES_TOTAL=$#     # per-patch progress bar
  ui_run "$BUILD_DIR/moltenvk-apply-spvc.log" "patching SPIRV-Cross ($n $unit)" sh -c '
      d="$1"; shift                 # $1 is the repo dir; loop over the patches only
      for f in "$@"; do
        printf "applying %s\n" "$(basename "$f")"
        git -C "$d" apply "$f" || { echo "patch failed: $f"; exit 1; }
      done' ui_sh "$SPVC_SRC" "$@" \
    || { echo "SPIRV-Cross patch failed — see $BUILD_DIR/moltenvk-apply-spvc.log"; exit 1; }
  list=$(ls "$P"/*.patch 2>/dev/null)
  # shellcheck disable=SC2086
  set -- $list
  n=$#; unit="patches"; [ "$n" -eq 1 ] && unit="patch"
  UI_LINES_RE='^applying '; UI_LINES_TOTAL=$#     # ui_run resets knobs after each call
  ui_run "$BUILD_DIR/moltenvk-apply-mvk.log" "patching MoltenVK ($n $unit)" sh -c '
      d="$1"; shift                 # $1 is the repo dir; loop over the patches only
      for f in "$@"; do
        printf "applying %s\n" "$(basename "$f")"
        git -C "$d" apply "$f" || { echo "patch failed: $f"; exit 1; }
      done' ui_sh "$MVK_SRC" "$@" \
    || { echo "MoltenVK patch failed — see $BUILD_DIR/moltenvk-apply-mvk.log"; exit 1; }
  ui_end
}

cmd_deps() {
  ui_begin deps 42 "Building MoltenVK's external dependencies"
  [ -d "$MVK_SRC/.git" ] || { echo "run 'fetch' first"; exit 1; }
  # Use local roots so fetchDependencies preserves the patches.
  # CrossOver 26.x only loads x86_64; the ARM pipeline builds aarch64.
  local xcconfig="$BUILD_DIR/moltenvk-$MVK_ARCH.xcconfig"
  echo "ARCHS = $MVK_ARCH" > "$xcconfig"
  _learned "$BUILD_DIR/.ui-mvk-deps-lines"
  ui_run "$BUILD_DIR/moltenvk-deps.log" "fetchDependencies --macos" \
    sh -c 'cd "$1" || exit 1; shift
           exec env XCODE_XCCONFIG_FILE="$1" ./fetchDependencies --macos \
                --spirv-cross-root "$2" --v-headers-root "$3"' \
    ui_sh "$MVK_SRC" "$xcconfig" "$SPVC_SRC" "$VKH_SRC" \
    || { echo "fetchDependencies failed — see $BUILD_DIR/moltenvk-deps.log"; exit 1; }
  ui_learn "$BUILD_DIR/.ui-mvk-deps-lines" "$(wc -l < "$BUILD_DIR/moltenvk-deps.log" | tr -d ' ')"
  ui_end
}

cmd_build() {
  ui_begin build 45 "Building libMoltenVK.dylib into $MVK_OUT"
  xcodebuild -version >/dev/null 2>&1 \
    || { echo "xcodebuild needs full Xcode; set DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer"; exit 1; }
  _learned "$BUILD_DIR/.ui-mvk-build-lines"
  ui_run "$BUILD_DIR/moltenvk-build.log" "xcodebuild — MoltenVK Package (macOS only), $MVK_ARCH" \
    sh -c 'cd "$1" || exit 1; shift
           exec xcodebuild build -project MoltenVKPackaging.xcodeproj \
                -scheme "MoltenVK Package (macOS only)" \
                -destination generic/platform=macOS ARCHS="$1"' \
    ui_sh "$MVK_SRC" "$MVK_ARCH" \
    || { echo "MoltenVK build failed — see $BUILD_DIR/moltenvk-build.log"; exit 1; }
  ui_learn "$BUILD_DIR/.ui-mvk-build-lines" "$(wc -l < "$BUILD_DIR/moltenvk-build.log" | tr -d ' ')"
  local dylib="$MVK_SRC/Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"
  # `file` prints "arm64" for an aarch64 Mach-O; accept either spelling.
  local archpat="$MVK_ARCH"
  [ "$MVK_ARCH" = "aarch64" ] && archpat="arm64|aarch64"
  file -b "$dylib" | grep -Eq "$archpat" || { echo "no $MVK_ARCH $dylib"; exit 1; }
  rm -rf "$MVK_OUT"; mkdir -p "$MVK_OUT"
  cp "$dylib" "$MVK_OUT/" && cp "$MVK_SRC/LICENSE" "$MVK_OUT/LICENSE.MoltenVK" || exit 1
  echo "https://github.com/KhronosGroup/MoltenVK/tree/$(git -C "$MVK_SRC" rev-parse HEAD)" > "$MVK_OUT/SOURCE_URL"
  echo "built $MVK_OUT"
  ui_end
}

ui_init "FineWine — MoltenVK ${MVK_TAG} ($MVK_ARCH)"
mkdir -p "$BUILD_DIR"   # every step logs into build/*.log
case "${1:-all}" in
  fetch|apply|deps|build) "cmd_$1" ;;
  all) cmd_fetch; cmd_apply; cmd_deps; cmd_build ;;
  *) echo "usage: $0 [all|fetch|apply|deps|build]"; exit 1 ;;
esac
rc=$?
ui_finish
exit "$rc"
