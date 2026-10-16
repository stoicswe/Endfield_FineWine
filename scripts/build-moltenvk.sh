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

log(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }

shallow_clone() { # url rev dir
  git init -q "$3" && git -C "$3" fetch -q --depth 1 "$1" "$2" && git -C "$3" checkout -q FETCH_HEAD
}

cmd_fetch() {
  log "Fetching MoltenVK $MVK_TAG and its pinned SPIRV-Cross and Vulkan-Headers"
  mkdir -p "$BUILD_DIR"; rm -rf "$MVK_SRC" "$SPVC_SRC" "$VKH_SRC"
  local rev="$MVK_SRC/ExternalRevisions"
  shallow_clone https://github.com/KhronosGroup/MoltenVK.git "refs/tags/$MVK_TAG" "$MVK_SRC" \
    && shallow_clone https://github.com/KhronosGroup/SPIRV-Cross.git "$(cat "$rev/SPIRV-Cross_repo_revision")" "$SPVC_SRC" \
    && shallow_clone https://github.com/KhronosGroup/Vulkan-Headers.git "$(cat "$rev/Vulkan-Headers_repo_revision")" "$VKH_SRC" \
    || { echo "clone failed"; exit 1; }
}

cmd_apply() {
  log "Applying patches/moltenvk"
  [ -d "$MVK_SRC/.git" ] || { echo "run 'fetch' first"; exit 1; }
  local f
  for f in "$P"/spirv-cross/*.patch; do git -C "$SPVC_SRC" apply "$f" || { echo "patch failed: $f"; exit 1; }; done
  for f in "$P"/*.patch; do git -C "$MVK_SRC" apply "$f" || { echo "patch failed: $f"; exit 1; }; done
}

cmd_deps() {
  log "Building MoltenVK's external dependencies"
  [ -d "$MVK_SRC/.git" ] || { echo "run 'fetch' first"; exit 1; }
  # Use local roots so fetchDependencies preserves the patches.
  # CrossOver 26.x only loads x86_64; the ARM pipeline builds aarch64.
  local xcconfig="$BUILD_DIR/moltenvk-$MVK_ARCH.xcconfig"
  echo "ARCHS = $MVK_ARCH" > "$xcconfig"
  ( cd "$MVK_SRC" && XCODE_XCCONFIG_FILE="$xcconfig" ./fetchDependencies --macos \
      --spirv-cross-root "$SPVC_SRC" --v-headers-root "$VKH_SRC" ) \
    > "$BUILD_DIR/moltenvk-deps.log" 2>&1 || { echo "fetchDependencies failed — see $BUILD_DIR/moltenvk-deps.log"; exit 1; }
}

cmd_build() {
  log "Building libMoltenVK.dylib into $MVK_OUT"
  xcodebuild -version >/dev/null 2>&1 \
    || { echo "xcodebuild needs full Xcode; set DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer"; exit 1; }
  ( cd "$MVK_SRC" && xcodebuild build -project MoltenVKPackaging.xcodeproj \
      -scheme "MoltenVK Package (macOS only)" -destination generic/platform=macOS ARCHS="$MVK_ARCH" ) \
    > "$BUILD_DIR/moltenvk-build.log" 2>&1 || { echo "MoltenVK build failed — see $BUILD_DIR/moltenvk-build.log"; exit 1; }
  local dylib="$MVK_SRC/Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"
  # `file` prints "arm64" for an aarch64 Mach-O; accept either spelling.
  local archpat="$MVK_ARCH"
  [ "$MVK_ARCH" = "aarch64" ] && archpat="arm64|aarch64"
  file -b "$dylib" | grep -Eq "$archpat" || { echo "no $MVK_ARCH $dylib"; exit 1; }
  rm -rf "$MVK_OUT"; mkdir -p "$MVK_OUT"
  cp "$dylib" "$MVK_OUT/" && cp "$MVK_SRC/LICENSE" "$MVK_OUT/LICENSE.MoltenVK" || exit 1
  echo "https://github.com/KhronosGroup/MoltenVK/tree/$(git -C "$MVK_SRC" rev-parse HEAD)" > "$MVK_OUT/SOURCE_URL"
  echo "built $MVK_OUT"
}

case "${1:-all}" in
  fetch|apply|deps|build) "cmd_$1" ;;
  all) cmd_fetch; cmd_apply; cmd_deps; cmd_build ;;
  *) echo "usage: $0 [all|fetch|apply|deps|build]"; exit 1 ;;
esac