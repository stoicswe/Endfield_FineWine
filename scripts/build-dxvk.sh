#!/usr/bin/env bash
# build-dxvk.sh — DXVK's Direct3D 9, for the FineWine runtime.
#
# Direct3D 9 and older reach Metal one of two ways in a FineWine runtime: through WineD3D's
# OpenGL renderer and Apple's OpenGL (the default), or, with the prefix setting "Direct3D 9
# and older on Vulkan", through DXVK and MoltenVK. DXVK is what Proton and CrossOver use for
# Direct3D 9; WineD3D's own Vulkan renderer was tried first and draws too little of a real
# game (Portal 2) correctly.
#
# Only d3d9.dll is built. Direct3D 10 and 11 are DXMT's in a FineWine runtime, and Direct3D 12
# is vkd3d's.
#
# The source is DXVK 1.10.3 as it is in CrossOver's source archive, which has CodeWeavers'
# changes for MoltenVK, plus patches/dxvk. The archive is the one build-finewine-deps.sh uses,
# pinned by version and checksum in finewine-sources.lock. DXVK asks the GPU for features Metal
# does not have and Direct3D 9 does not use; the runtime's MoltenVK reports them when
# FINEWINE_DXVK_FEATURES=1 (patches/moltenvk/0007), which FineWine sets with the setting.
#
# Installed into the runtime as
#     lib/dxvk/i386-windows/d3d9.dll       for 32-bit programs
#     lib/dxvk/aarch64-windows/d3d9.dll    for 64-bit programs (an x64 library; the runtime's
#                                          folder for 64-bit Windows libraries has this name)
# both marked as Wine builtins, so that putting lib/dxvk on WINEDLLPATH is all it takes, and
# runtime.json gets a "dxvk-d3d9" entry, which is how the app knows the runtime has it.
#
# Usage:  scripts/build-dxvk.sh [all]     fetch -> apply -> build -> install
#         scripts/build-dxvk.sh <step>    fetch | apply | build | install | clean
# Needs:  meson, ninja and glslangValidator (brew install meson ninja glslang), the llvm-mingw
#         from scripts/build-fex.sh toolchain, a Wine build tree (for winebuild), and a packaged
#         runtime to install into.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/scripts/lib/sources-lock.sh"; lock_load   # CROSSOVER_SOURCES_*
BUILD_DIR="${BUILD_DIR:-$REPO/build}"
RUNTIME_DIR="${RUNTIME_DIR:-$BUILD_DIR/finewine-runtime}"
WINE_OBJ="${WINE_OBJ:-$BUILD_DIR/finewine-runtime-build}"
MINGW="${MINGW:-$BUILD_DIR/llvm-mingw}"
ARCHIVE="$BUILD_DIR/crossover-sources-$CROSSOVER_SOURCES_VERSION.tar.gz"
URL="https://media.codeweavers.com/pub/crossover/source/crossover-sources-$CROSSOVER_SOURCES_VERSION.tar.gz"
TOP="$BUILD_DIR/dxvk"
SRC="$TOP/sources/dxvk"

log(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

cmd_fetch(){
  log "DXVK from CrossOver's source archive $CROSSOVER_SOURCES_VERSION"
  mkdir -p "$BUILD_DIR"
  if [ ! -f "$ARCHIVE" ]; then
    curl -fsSL -o "$ARCHIVE.part" "$URL" || die "download failed: $URL"
    mv "$ARCHIVE.part" "$ARCHIVE"
  fi
  local got; got="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
  [ "$got" = "$CROSSOVER_SOURCES_SHA256" ] || lock_fail "$ARCHIVE has checksum $got, but finewine-sources.lock pins $CROSSOVER_SOURCES_SHA256"
  rm -rf "$TOP"; mkdir -p "$TOP"
  tar xzf "$ARCHIVE" -C "$TOP" sources/dxvk
  # A repository of its own, so that the patches apply with git and a second 'apply' is refused.
  git -C "$SRC" init -q
  git -C "$SRC" add -A
  git -C "$SRC" -c user.name=finewine -c user.email=finewine@localhost commit -qm "DXVK from crossover-sources-$CROSSOVER_SOURCES_VERSION"
  echo "source: $SRC ($(grep -o "version : 'v[0-9.]*'" "$SRC/meson.build" | head -n 1))"
}

cmd_apply(){
  log "Applying patches/dxvk"
  [ -d "$SRC" ] || die "run 'fetch' first"
  local f n=0
  for f in "$REPO"/patches/dxvk/*.patch; do
    git -C "$SRC" apply "$f" || die "patch failed: $f"
    n=$((n+1))
  done
  echo "applied $n patches"
}

build_one(){   # <cross file> <object folder> <what>
  local cross="$1" obj="$2" what="$3"
  rm -rf "$obj"
  ( cd "$SRC" && meson setup --cross-file "$cross" --buildtype release \
      -Denable_d3d9=true -Denable_d3d10=false -Denable_d3d11=false -Denable_dxgi=false -Denable_tests=false \
      "$obj" ) > "$BUILD_DIR/dxvk-setup-$what.log" 2>&1 || die "meson setup ($what) failed, see $BUILD_DIR/dxvk-setup-$what.log"
  ninja -C "$obj" > "$BUILD_DIR/dxvk-compile-$what.log" 2>&1 || die "build ($what) failed, see $BUILD_DIR/dxvk-compile-$what.log"
  [ -f "$obj/src/d3d9/d3d9.dll" ] || die "no d3d9.dll came out of the $what build"
  echo "built: $obj/src/d3d9/d3d9.dll"
}

cmd_build(){
  log "Building DXVK's d3d9.dll, 32-bit and x64"
  [ -d "$SRC" ] || die "run 'fetch' first"
  [ -x "$MINGW/bin/i686-w64-mingw32-g++" ] || die "no llvm-mingw: run scripts/build-fex.sh toolchain"
  command -v meson >/dev/null || die "meson is not installed (brew install meson)"
  command -v ninja >/dev/null || die "ninja is not installed (brew install ninja)"
  command -v glslangValidator >/dev/null || die "glslangValidator is not installed (brew install glslang)"
  export PATH="$MINGW/bin:$PATH"
  build_one "$SRC/build-win32.txt" "$TOP/obj32" 32
  build_one "$SRC/build-win64.txt" "$TOP/obj64" 64
}

cmd_install(){
  log "Installing into $RUNTIME_DIR"
  [ -f "$RUNTIME_DIR/runtime.json" ] || die "no packaged runtime at $RUNTIME_DIR: run scripts/build-finewine-runtime.sh"
  [ -f "$TOP/obj32/src/d3d9/d3d9.dll" ] && [ -f "$TOP/obj64/src/d3d9/d3d9.dll" ] || die "run 'build' first"
  local winebuild="$WINE_OBJ/tools/winebuild/winebuild"
  [ -x "$winebuild" ] || die "no winebuild in $WINE_OBJ: run scripts/build-finewine-runtime.sh"
  rm -rf "$RUNTIME_DIR/lib/dxvk"
  local pair dir obj out
  for pair in "i386-windows:obj32" "aarch64-windows:obj64"; do
    dir="${pair%%:*}"; obj="${pair##*:}"; out="$RUNTIME_DIR/lib/dxvk/$dir/d3d9.dll"
    mkdir -p "$(dirname "$out")"
    cp "$TOP/$obj/src/d3d9/d3d9.dll" "$out"
    "$MINGW/bin/llvm-strip" --strip-debug "$out" 2>/dev/null || true
    # Wine takes a library from WINEDLLPATH only if it is marked as one of its own.
    "$winebuild" --builtin "$out" || die "could not mark $out as a builtin"
  done
  cp "$SRC/LICENSE" "$RUNTIME_DIR/lib/dxvk/LICENSE"
  python3 - "$RUNTIME_DIR/runtime.json" <<'PY'
import json, sys
path = sys.argv[1]
manifest = json.load(open(path))
manifest.setdefault("graphics", {})["dxvk-d3d9"] = {"dllPath": "lib/dxvk", "overrides": {}}
json.dump(manifest, open(path, "w"), indent=2)
open(path, "a").write("\n")
PY
  echo "installed: $RUNTIME_DIR/lib/dxvk (Direct3D 9, 32-bit and 64-bit programs)"
}

case "${1:-all}" in
  fetch) cmd_fetch ;;
  apply) cmd_apply ;;
  build) cmd_build ;;
  install) cmd_install ;;
  clean) rm -rf "$TOP"; echo "removed $TOP" ;;
  all) cmd_fetch; cmd_apply; cmd_build; cmd_install ;;
  *) die "unknown step '$1' (expected: fetch, apply, build, install, clean, all)" ;;
esac
