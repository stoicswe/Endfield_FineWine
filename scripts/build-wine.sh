#!/usr/bin/env bash
# build-wine.sh — build a 64-bit-only CrossOver Wine from source on Apple Silicon, so we can
# apply patches and experiment (stage 1) and eventually the dw-proton set (stage 2).
#
# WHY 64-bit only: Arknights: Endfield is a pure 64-bit game (Endfield.exe @ 0x140000000, all game
# DLLs 64-bit). We do NOT need win32on64 / the (now-unavailable) cx-llvm patched clang. A 64-bit
# Wine builds with the STANDARD toolchain. See docs/04-building-crossover-wine.md.
#
# This produces an x86_64 Wine (runs under Rosetta 2 — the config where dw-proton's #ifdef __x86_64__
# int3 hack compiles, and the same config where our stage-1 fault occurs).
#
# STATUS: milestone-4 scaffold. The exact CrossOver-26.2 configure flags are NOT yet verified to
# build clean 64-bit-only on macOS 26 — this script is the vehicle to find out. Expect to iterate.
#
# Usage:
#   scripts/build-wine.sh deps      # install Homebrew build deps
#   scripts/build-wine.sh fetch     # download + extract CrossOver 26.2 wine source, init git
#   scripts/build-wine.sh apply     # git apply all patches/ (em-backports -> misc -> macos fixes)
#   scripts/build-wine.sh configure # run ./configure (64-bit)
#   scripts/build-wine.sh build     # make -j
#   scripts/build-wine.sh all       # deps -> fetch -> apply -> configure -> build
#
# Env: CX_VER (default 26.2.0), BUILD_DIR (default ./build), JOBS (default: all cores)

set -uo pipefail
CX_VER="${CX_VER:-26.2.0}"
BUILD_DIR="${BUILD_DIR:-$(pwd)/build}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
SRC_URL="https://media.codeweavers.com/pub/crossover/source/crossover-sources-${CX_VER}.tar.gz"
WINE_SRC="$BUILD_DIR/wine-src"          # extracted sources/wine
WINE_BUILD="$BUILD_DIR/wine-build64"    # out-of-tree 64-bit build
BREW="$(command -v brew || echo /opt/homebrew/bin/brew)"

log(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }

cmd_deps() {
  log "Installing Homebrew build dependencies"
  "$BREW" install bison mingw-w64 pkg-config gnutls freetype sdl2 molten-vk meson || true
  echo "NOTE: put Homebrew bison (>=3.0) AHEAD of system bison (2.3) on PATH before configure:"
  echo "  export PATH=\"$("$BREW" --prefix bison)/bin:\$PATH\""
}

cmd_fetch() {
  log "Fetching CrossOver ${CX_VER} source (~142 MB) and extracting sources/wine"
  mkdir -p "$BUILD_DIR"
  local tgz="$BUILD_DIR/crossover-sources-${CX_VER}.tar.gz"
  [ -f "$tgz" ] || curl -fL "$SRC_URL" -o "$tgz" || { echo "download failed ($SRC_URL)"; exit 1; }
  rm -rf "$WINE_SRC"; mkdir -p "$WINE_SRC"
  # extract only sources/wine/* into WINE_SRC
  tar xzf "$tgz" -C "$BUILD_DIR" sources/wine 2>/dev/null || { echo "extract failed"; exit 1; }
  mv "$BUILD_DIR/sources/wine"/* "$WINE_SRC/" 2>/dev/null; rmdir "$BUILD_DIR/sources/wine" "$BUILD_DIR/sources" 2>/dev/null || true
  log "git-init the wine tree (so patches can be applied with 'git am' and diffed)"
  ( cd "$WINE_SRC" && git init -q && git add -A && git -c user.email=b@b -c user.name=build commit -qm "vanilla CrossOver ${CX_VER} wine" )
  echo "wine source ready at: $WINE_SRC"
  echo "does it still support win32on64 (should NOT need it) / what archs? check:"
  grep -h -m1 -iE 'enable-archs|win32on64' "$WINE_SRC/configure.ac" 2>/dev/null | sed 's/^/  /' || true
}

cmd_apply() {
  log "Applying patches to $WINE_SRC (em-backports -> misc -> macos Rosetta fixes)"
  [ -d "$WINE_SRC/.git" ] || { echo "run 'fetch' first"; exit 1; }
  local P; P="$(cd "$(dirname "$0")/../patches" && pwd)"
  ( cd "$WINE_SRC"
    local n=0 f
    for f in $(ls "$P"/stage2-dwproton/em-backports/*.patch | sort) \
             $(ls "$P"/stage2-dwproton/misc/*.patch | sort) \
             "$P"/stage1-macos/0000-*.patch "$P"/stage1-macos/0001-*.patch; do
      if git apply "$f"; then n=$((n+1)); else echo "FAILED to apply: $f"; exit 1; fi
    done
    echo "applied $n patches cleanly" )
}

cmd_configure() {
  log "Configuring 64-bit-only Wine (standard toolchain, no win32on64/cx-llvm)"
  [ -d "$WINE_SRC" ] || { echo "run 'fetch' first"; exit 1; }
  export PATH="$("$BREW" --prefix bison)/bin:$PATH"
  rm -rf "$WINE_BUILD"; mkdir -p "$WINE_BUILD"
  # CRITICAL (learned 2026-07-14): CrossOver on Apple Silicon builds the ENTIRE tree as x86_64
  # under Rosetta. Run configure+make under `arch -x86_64` so __x86_64__ is defined for the unix
  # objects (else winemac.drv's WineMetalLayer, guarded by #if __x86_64__, fails to compile).
  # Homebrew libs are arm64-only here, so we disable the optional externals we can't get in x86_64
  # (fine for reaching the game's stage-1 fault — no fonts/TLS/graphics needed). This yields a
  # MINIMAL Wine; for a fully playable build, install x86_64 deps (Intel Homebrew) and drop the --without-* flags.
  arch -x86_64 /bin/bash -c '
    export PATH="'"$("$BREW" --prefix bison)"'/bin:$PATH"
    export MACOSX_DEPLOYMENT_TARGET=10.15
    echo "host arch: $(uname -m); bison: $(bison --version | head -1)"
    cd "'"$WINE_BUILD"'"
    CC=clang CXX=clang++ "'"$WINE_SRC"'/configure" --enable-archs=x86_64 --disable-tests --without-x \
      --without-freetype --without-gnutls --without-sdl --without-vulkan --without-krb5 \
      --without-gstreamer --without-gphoto --without-sane --without-pcap --without-usb \
      --without-cups --without-openal --without-coreaudio
  ' 2>&1 | tee "$BUILD_DIR/configure.log"
  # CrossOver's win32u/vulkan.c uses SONAME_LIBVULKAN even with --without-vulkan; define it so it
  # compiles (dlopen fails gracefully at runtime — vulkan not needed for stage 1).
  local cfg="$WINE_BUILD/include/config.h"
  sed -i '' 's|/\* #undef SONAME_LIBVULKAN \*/|#define SONAME_LIBVULKAN "libvulkan.1.dylib"|' "$cfg"
  sed -i '' 's|/\* #undef SONAME_LIBMOLTENVK \*/|#define SONAME_LIBMOLTENVK "libMoltenVK.dylib"|' "$cfg"
  echo "Patched config.h SONAME defines. Review $BUILD_DIR/configure.log."
}

cmd_build() {
  log "Building (make -j$JOBS under arch -x86_64) — expect 20-60 min"
  [ -d "$WINE_BUILD" ] || { echo "run 'configure' first"; exit 1; }
  arch -x86_64 /bin/bash -c '
    export PATH="'"$("$BREW" --prefix bison)"'/bin:$PATH"; export MACOSX_DEPLOYMENT_TARGET=10.15
    cd "'"$WINE_BUILD"'" && make -j'"$JOBS"'
  ' 2>&1 | tee "$BUILD_DIR/build.log"
  echo ""
  echo "Output loader: $WINE_BUILD/loader/wine64 ; server: $WINE_BUILD/server/wineserver"
  echo "Run the game directly (stage-1 debug):"
  echo "  WINEPREFIX=<bottle> arch -x86_64 $WINE_BUILD/loader/wine64 <Endfield.exe path>"
}

case "${1:-all}" in
  deps) cmd_deps ;;
  fetch) cmd_fetch ;;
  apply) cmd_apply ;;
  configure) cmd_configure ;;
  build) cmd_build ;;
  all) cmd_deps; cmd_fetch; cmd_apply; cmd_configure; cmd_build ;;
  *) echo "usage: $0 {deps|fetch|apply|configure|build|all}"; exit 1 ;;
esac
