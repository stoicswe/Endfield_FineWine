#!/usr/bin/env bash
# build-dxmt.sh — build DXMT (Direct3D 10 and 11 on Metal) for FineWine's Wine runtime.
#
# DXMT is the Direct3D layer for this runtime: Apple's D3DMetal is x86_64-only and cannot be
# loaded into an ARM64 Wine. DXMT's DLLs are built as ARM64X, so both ARM64 programs and x64
# programs running under FEX use them, and its Metal bridge is a native arm64 library.
#
#   source     DXMT at the pinned commit (DXMT_COMMIT), with patches/dxmt applied. Direct3D 12
#              is not DXMT's here: it stays Wine's (vkd3d on MoltenVK), and the patch makes
#              DXMT's DXGI pass Direct3D 12 swap chains on to Wine's.
#   needs      LLVM 15 static libraries, built here from source into build/dxmt-llvm (about 20
#              minutes, once); llvm-mingw from scripts/build-fex.sh toolchain; the Wine build tree
#              from scripts/build-finewine-runtime.sh; an Xcode with the Metal toolchain installed
#   output     build/dxmt-install, and, with `install`, in build/finewine-runtime:
#                lib/dxmt/aarch64-windows/{d3d11,d3d10core,dxgi}.dll   selected per prefix
#                lib/wine/aarch64-windows/winemetal.dll                always present
#                lib/wine/aarch64-windows/{nvngx,nvapi64}.dll          DLSS as MetalFX, NVAPI
#                lib/wine/aarch64-unix/winemetal.so
#              plus a "dxmt" entry in runtime.json
#   32-bit     when the Wine build tree has a 32-bit side, DXMT's Windows DLLs are built a
#              second time for 32-bit x86 programs (DXMT's own build-win32.txt):
#                lib/dxmt/i386-windows/{d3d11,d3d10core,dxgi}.dll
#                lib/wine/i386-windows/winemetal.dll
#              They call the same winemetal.so, which adds the base of the 32-bit program's
#              memory window to its pointers (patches/dxmt/0008, Wine runtime patch 0043).
#              The NVIDIA stand-ins are 64-bit only.
#
# Usage:
#   scripts/build-dxmt.sh llvm      # build LLVM 15 (skipped if already built)
#   scripts/build-dxmt.sh fetch     # clone DXMT and its submodules
#   scripts/build-dxmt.sh apply     # apply patches/dxmt
#   scripts/build-dxmt.sh build     # configure, compile and stage
#   scripts/build-dxmt.sh install   # copy into the runtime and update runtime.json
#   scripts/build-dxmt.sh all       # everything above
#
# Env: BUILD_DIR (default ./build), DXMT_COMMIT, RUNTIME_DIR (default build/finewine-runtime),
#      METAL_DEVELOPER_DIR (an Xcode's Contents/Developer that has the Metal toolchain; found
#      automatically among /Applications/Xcode*.app if unset).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/scripts/lib/sources-lock.sh"; lock_load   # DXMT_COMMIT, DXMT_LLVM_TAG, DXMT_LLVM_COMMIT
BUILD_DIR="${BUILD_DIR:-$REPO/build}"
# winemetal.so runs in FineWine's runtime, which supports macOS 15 and later.
export MACOSX_DEPLOYMENT_TARGET="15.0"
RUNTIME_DIR="${RUNTIME_DIR:-$BUILD_DIR/finewine-runtime}"
SRC="$BUILD_DIR/dxmt-src"
OBJ="$BUILD_DIR/dxmt-build"
STAGE="$BUILD_DIR/dxmt-install"
OBJ32="$BUILD_DIR/dxmt-build-32"
STAGE32="$BUILD_DIR/dxmt-install-32"
LLVM="$BUILD_DIR/dxmt-llvm"
MINGW="$BUILD_DIR/llvm-mingw"
WINE_OBJ="$BUILD_DIR/finewine-runtime-build"
CROSS_FILE="$REPO/patches/dxmt/build-arm64ec-finewine.txt"

log(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

# DXMT compiles Metal shaders, which needs an Xcode with the Metal toolchain component.
find_metal_xcode(){
  if [ -n "${METAL_DEVELOPER_DIR:-}" ]; then echo "$METAL_DEVELOPER_DIR"; return; fi
  local d
  for d in /Applications/Xcode*.app/Contents/Developer; do
    [ -d "$d" ] || continue
    if DEVELOPER_DIR="$d" xcrun metal --version >/dev/null 2>&1; then echo "$d"; return; fi
  done
  return 1
}

cmd_llvm(){
  if [ -f "$LLVM/lib/libLLVMCore.a" ]; then echo "LLVM 15: already built in $LLVM"; return; fi
  log "Building LLVM 15 static libraries (once, about 20 minutes)"
  rm -rf "$BUILD_DIR/dxmt-llvm-project" "$BUILD_DIR/dxmt-llvm-build"
  # The tag is fetched by name and then checked against the pinned commit.
  git init -q "$BUILD_DIR/dxmt-llvm-project"
  git -C "$BUILD_DIR/dxmt-llvm-project" fetch -q --depth 1 https://github.com/llvm/llvm-project.git "refs/tags/$DXMT_LLVM_TAG"
  git -C "$BUILD_DIR/dxmt-llvm-project" checkout -q FETCH_HEAD
  lock_check "LLVM $DXMT_LLVM_TAG" "$(git -C "$BUILD_DIR/dxmt-llvm-project" rev-parse HEAD)" "$DXMT_LLVM_COMMIT"
  cmake -B "$BUILD_DIR/dxmt-llvm-build" -S "$BUILD_DIR/dxmt-llvm-project/llvm" -G Ninja \
    -DCMAKE_INSTALL_PREFIX="$LLVM" -DCMAKE_OSX_ARCHITECTURES=arm64 -DLLVM_HOST_TRIPLE=arm64-apple-darwin \
    -DLLVM_ENABLE_ASSERTIONS=On -DLLVM_ENABLE_ZSTD=Off -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_FLAGS="-D_LIBCPP_KEEP_TRANSITIVE_INCLUDES_LLVM23" -DLLVM_TARGETS_TO_BUILD="" \
    -DLLVM_BUILD_TOOLS=Off -DLLVM_INCLUDE_BENCHMARKS=Off -DLLVM_INCLUDE_TESTS=Off \
    -DBUG_REPORT_URL="https://github.com/3Shain/dxmt" -DPACKAGE_VENDOR="DXMT" \
    -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off > "$BUILD_DIR/dxmt-llvm-configure.log" 2>&1 \
    || die "LLVM configure failed, see $BUILD_DIR/dxmt-llvm-configure.log"
  cmake --build "$BUILD_DIR/dxmt-llvm-build" > "$BUILD_DIR/dxmt-llvm-build.log" 2>&1 \
    || die "LLVM build failed, see $BUILD_DIR/dxmt-llvm-build.log"
  cmake --install "$BUILD_DIR/dxmt-llvm-build" > "$BUILD_DIR/dxmt-llvm-install.log" 2>&1
}

cmd_fetch(){
  log "Fetching DXMT ($DXMT_COMMIT)"
  rm -rf "$SRC"; git init -q "$SRC"
  git -C "$SRC" fetch -q --depth 1 https://github.com/3Shain/dxmt.git "$DXMT_COMMIT" 2>/dev/null \
    || { git -C "$SRC" fetch -q https://github.com/3Shain/dxmt.git && true; }
  git -C "$SRC" checkout -q "$DXMT_COMMIT" 2>/dev/null || git -C "$SRC" checkout -q FETCH_HEAD
  lock_check DXMT "$(git -C "$SRC" rev-parse HEAD)" "$DXMT_COMMIT"
  git -C "$SRC" submodule update --init --depth 1 >/dev/null
  echo "source: $SRC ($(git -C "$SRC" log -1 --format=%h))"
}

cmd_apply(){
  log "Applying patches/dxmt"
  [ -d "$SRC" ] || die "run 'fetch' first"
  local f n=0
  for f in "$REPO"/patches/dxmt/*.patch; do
    git -C "$SRC" apply "$f" || die "patch failed: $f"
    n=$((n+1))
  done
  echo "applied $n patches"
}

cmd_build(){
  log "Building DXMT for ARM64X"
  [ -d "$SRC" ] || die "run 'fetch' first"
  [ -f "$LLVM/lib/libLLVMCore.a" ] || die "run 'llvm' first"
  [ -x "$MINGW/bin/arm64ec-w64-mingw32-gcc" ] || die "no llvm-mingw: run scripts/build-fex.sh toolchain"
  [ -f "$WINE_OBJ/Makefile" ] || die "no Wine build tree: run scripts/build-finewine-runtime.sh"
  local xcode; xcode="$(find_metal_xcode)" \
    || die "no Xcode with the Metal toolchain found. Install it with: xcodebuild -downloadComponent MetalToolchain"
  echo "Metal toolchain from: $xcode"
  export PATH="$MINGW/bin:$PATH" DEVELOPER_DIR="$xcode"
  rm -rf "$OBJ" "$STAGE"
  # Paths are given in absolute, normalised form: meson rejects one that looks like it points
  # into the source tree.
  ( cd "$SRC" && meson setup --cross-file "$CROSS_FILE" -Dnative_llvm_path="$LLVM" \
      -Dwine_build_path="$WINE_OBJ" -Denable_nvapi=true -Denable_nvngx=true \
      "$OBJ" --buildtype release --prefix "$STAGE" --strip ) \
    > "$BUILD_DIR/dxmt-setup.log" 2>&1 || die "meson setup failed, see $BUILD_DIR/dxmt-setup.log"
  meson compile -C "$OBJ" > "$BUILD_DIR/dxmt-compile.log" 2>&1 || die "build failed, see $BUILD_DIR/dxmt-compile.log"
  meson install -C "$OBJ" > "$BUILD_DIR/dxmt-install.log" 2>&1 || die "install failed, see $BUILD_DIR/dxmt-install.log"
  ls "$STAGE/aarch64-windows/"*.dll "$STAGE/aarch64-unix/winemetal.so" >/dev/null || die "the build is missing files"
  echo "built: $STAGE"
  build_32
}

# The Windows DLLs again, for 32-bit x86 programs. Only when Wine was built with a 32-bit side;
# the Mac half (winemetal.so) is the one built above.
build_32(){
  rm -rf "$OBJ32" "$STAGE32"
  if [ ! -f "$WINE_OBJ/dlls/ntdll/i386-windows/libntdll.a" ]; then
    echo "note: the Wine build tree has no 32-bit side; DXMT is not built for 32-bit programs"
    return 0
  fi
  log "Building DXMT's Windows DLLs for 32-bit programs"
  [ -x "$MINGW/bin/i686-w64-mingw32-gcc" ] || die "llvm-mingw has no 32-bit compiler: run scripts/build-fex.sh toolchain"
  ( cd "$SRC" && meson setup --cross-file "$SRC/build-win32.txt" -Dnative_llvm_path="$LLVM" \
      -Dwine_build_path="$WINE_OBJ" "$OBJ32" --buildtype release --prefix "$STAGE32" --strip ) \
    > "$BUILD_DIR/dxmt-setup-32.log" 2>&1 || die "meson setup (32-bit) failed, see $BUILD_DIR/dxmt-setup-32.log"
  meson compile -C "$OBJ32" > "$BUILD_DIR/dxmt-compile-32.log" 2>&1 || die "32-bit build failed, see $BUILD_DIR/dxmt-compile-32.log"
  meson install -C "$OBJ32" > "$BUILD_DIR/dxmt-install-32.log" 2>&1 || die "32-bit install failed, see $BUILD_DIR/dxmt-install-32.log"
  local dll
  for dll in d3d11 d3d10core dxgi winemetal; do
    [ -f "$STAGE32/i386-windows/$dll.dll" ] || die "the 32-bit build is missing $dll.dll"
    file "$STAGE32/i386-windows/$dll.dll" | grep -q 'Intel 80386\|Intel i386' || die "$dll.dll (32-bit build) is not a 32-bit x86 file"
  done
  echo "built: $STAGE32"
}

cmd_install(){
  log "Installing DXMT into the runtime"
  [ -f "$STAGE/aarch64-unix/winemetal.so" ] || die "run 'build' first"
  [ -f "$RUNTIME_DIR/runtime.json" ] || die "no runtime at $RUNTIME_DIR (run scripts/build-finewine-runtime.sh all)"
  local pe="$RUNTIME_DIR/lib/wine/aarch64-windows" unix="$RUNTIME_DIR/lib/wine/aarch64-unix" sel="$RUNTIME_DIR/lib/dxmt/aarch64-windows"
  rm -rf "$RUNTIME_DIR/lib/dxmt"; mkdir -p "$sel"
  # The Direct3D DLLs go in their own folder, which a prefix selects through WINEDLLPATH.
  for dll in d3d11 d3d10core dxgi; do cp "$STAGE/aarch64-windows/$dll.dll" "$sel/"; done
  # The Metal bridge is not a replacement for anything in Wine, and Wine only loads a built-in
  # DLL that has a file in the prefix, so it lives with Wine's own DLLs: every new prefix then
  # gets it (existing ones after `wineboot --update`).
  cp "$STAGE/aarch64-windows/winemetal.dll" "$pe/winemetal.dll"
  # DXMT's stand-ins for NVIDIA's libraries: nvngx.dll turns DLSS upscaling into MetalFX, and
  # nvapi64.dll answers the NVAPI calls games make beside it. Games load both by name from
  # system32, so like the Metal bridge they have to be among Wine's own DLLs. They stay inert
  # unless DXMT_ENABLE_NVEXT=1 is set, which FineWine does for a prefix with "DLSS through
  # MetalFX" on: DXMT then registers nvngx.dll where the DLSS SDK inside a game looks for it.
  cp "$STAGE/aarch64-windows/nvngx.dll" "$STAGE/aarch64-windows/nvapi64.dll" "$pe/"
  cp "$STAGE/aarch64-unix/winemetal.so" "$unix/winemetal.so"
  install_name_tool -add_rpath "@loader_path/../.." "$unix/winemetal.so" 2>/dev/null || true
  codesign --force --sign - "$unix/winemetal.so" 2>/dev/null
  # The 32-bit Windows DLLs, beside the others: Wine picks the folder by the program's kind.
  rm -f "$RUNTIME_DIR/lib/wine/i386-windows/winemetal.dll"
  if [ -f "$STAGE32/i386-windows/winemetal.dll" ] && [ -d "$RUNTIME_DIR/lib/wine/i386-windows" ]; then
    mkdir -p "$RUNTIME_DIR/lib/dxmt/i386-windows"
    for dll in d3d11 d3d10core dxgi; do cp "$STAGE32/i386-windows/$dll.dll" "$RUNTIME_DIR/lib/dxmt/i386-windows/"; done
    cp "$STAGE32/i386-windows/winemetal.dll" "$RUNTIME_DIR/lib/wine/i386-windows/winemetal.dll"
    echo "installed: $RUNTIME_DIR/lib/dxmt/i386-windows (for 32-bit programs)"
  fi
  python3 - "$RUNTIME_DIR/runtime.json" <<'PY'
import json, sys
path = sys.argv[1]
manifest = json.load(open(path))
# No overrides are needed: the DLLs are Wine built-ins, found first because their folder is
# ahead of Wine's own in WINEDLLPATH.
manifest.setdefault("graphics", {})["dxmt"] = {"dllPath": "lib/dxmt", "overrides": {}}
json.dump(manifest, open(path, "w"), indent=2)
open(path, "a").write("\n")
PY
  echo "installed: $sel, winemetal in $pe and $unix; runtime.json lists dxmt"
}

case "${1:-}" in
  llvm) cmd_llvm ;;
  fetch) cmd_fetch ;;
  apply) cmd_apply ;;
  build) cmd_build ;;
  install) cmd_install ;;
  all) cmd_llvm; cmd_fetch; cmd_apply; cmd_build; cmd_install ;;
  *) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
