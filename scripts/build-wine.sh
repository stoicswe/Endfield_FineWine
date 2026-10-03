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
# STATUS: verified with the CrossOver 26.3.0 sources — builds clean 64-bit-only on the CI builder
# (GitHub's xcode-27 image) and locally on an M4 / macOS 27.0 with Command Line Tools 16 (~10 min
# on its 10 cores).
#
# Usage:
#   scripts/build-wine.sh deps      # install Homebrew build deps
#   scripts/build-wine.sh fetch     # download + extract CrossOver 26.3 wine source, init git
#   scripts/build-wine.sh apply     # git apply all patches/ (em-backports -> misc -> macos fixes)
#   scripts/build-wine.sh configure # run ./configure (64-bit)
#   scripts/build-wine.sh build     # make -j
#   scripts/build-wine.sh all       # deps -> fetch -> apply -> configure -> build
#
# Env: CX_VER (default 26.3.0), BUILD_DIR (default ./build), JOBS (default: all cores)

set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CX_VER="${CX_VER:-26.3.0}"
BUILD_DIR="${BUILD_DIR:-$REPO/build}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
SRC_URL="https://media.codeweavers.com/pub/crossover/source/crossover-sources-${CX_VER}.tar.gz"
WINE_SRC="$BUILD_DIR/wine-src"          # extracted sources/wine
WINE_BUILD="$BUILD_DIR/wine-build64"    # out-of-tree 64-bit build
WINE_OUT="$BUILD_DIR/wine-out"
MODULES="dlls/ntdll/ntdll.so dlls/kernel32/x86_64-windows/kernel32.dll dlls/ntoskrnl.exe/x86_64-windows/ntoskrnl.exe"
BREW="$(command -v brew || echo /opt/homebrew/bin/brew)"
export MACOSX_DEPLOYMENT_TARGET=10.15

log(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }
use_bison(){ export PATH="$("$BREW" --prefix bison)/bin:$PATH"; }  # Wine needs bison >= 3.0; macOS ships 2.3

cmd_deps() {
  log "Installing Homebrew build dependencies"
  # ccache wraps CC/CXX on CI (the workflow sets "CC: ccache clang"); include it here so a
  # cache-miss build installs it too.
  "$BREW" install bison mingw-w64 pkgconf ccache || exit 1
}

cmd_fetch() {
  log "Fetching CrossOver ${CX_VER} source (~150 MB) and extracting sources/wine"
  mkdir -p "$BUILD_DIR"
  local tgz="$BUILD_DIR/crossover-sources-${CX_VER}.tar.gz"
  [ -f "$tgz" ] || curl -fL "$SRC_URL" -o "$tgz" || { echo "download failed ($SRC_URL)"; exit 1; }
  rm -rf "$WINE_SRC" "$BUILD_DIR/sources"; mkdir -p "$WINE_SRC"
  tar xzf "$tgz" -C "$BUILD_DIR" sources/wine || { echo "extract failed"; exit 1; }
  mv "$BUILD_DIR/sources/wine"/* "$WINE_SRC/"; rm -rf "$BUILD_DIR/sources"
  # Commit a baseline for inspecting patch changes.
  ( cd "$WINE_SRC" && git init -q && git add -A && git -c user.email=build@localhost -c user.name=build commit -qm "vanilla CrossOver ${CX_VER} wine" ) || exit 1
  echo "Wine source: $WINE_SRC ($(cat "$WINE_SRC/VERSION"))"
}

cmd_apply() {
  log "Applying patches (em-backports -> misc -> macOS)"
  [ -d "$WINE_SRC/.git" ] || { echo "run 'fetch' first"; exit 1; }
  local P="$REPO/patches"
  ( cd "$WINE_SRC"
    n=0
    for f in $(ls "$P"/stage2-dwproton/em-backports/*.patch | sort) \
             $(ls "$P"/stage2-dwproton/misc/*.patch | sort) \
             $(ls "$P"/stage1-macos/*.patch | sort); do
      git apply "$f" || { echo "patch failed: $f"; exit 1; }
      n=$((n+1))
    done
    echo "applied $n patches" ) || exit 1
}

cmd_configure() {
  log "Configuring 64-bit-only Wine"
  [ -d "$WINE_SRC" ] || { echo "run 'fetch' first"; exit 1; }
  rm -rf "$WINE_BUILD"; mkdir -p "$WINE_BUILD"
  use_bison
  # Matching build/host lets configure run x86_64 probes under Rosetta while shell tools
  # stay native. Disable optional libraries: Homebrew's are arm64, and these modules don't need them.
  ( cd "$WINE_BUILD" && CC="clang -arch x86_64" CXX="clang++ -arch x86_64" OBJC="clang -arch x86_64" "$WINE_SRC/configure" \
      --build=x86_64-apple-darwin --host=x86_64-apple-darwin --enable-archs=x86_64 \
      --disable-tests --without-x --without-freetype --without-gnutls --without-sdl --without-vulkan \
      --without-krb5 --without-gstreamer --without-gphoto --without-sane --without-pcap --without-usb \
      --without-cups --without-coreaudio
  ) 2>&1 | tee "$BUILD_DIR/configure.log"
  [ "${PIPESTATUS[0]}" = 0 ] || { echo "configure failed — see $BUILD_DIR/configure.log"; exit 1; }
  # Supply library names used by win32u even with --without-vulkan.
  local cfg="$WINE_BUILD/include/config.h"
  sed -i '' 's|/\* #undef SONAME_LIBVULKAN \*/|#define SONAME_LIBVULKAN "libvulkan.1.dylib"|' "$cfg"
  sed -i '' 's|/\* #undef SONAME_LIBMOLTENVK \*/|#define SONAME_LIBMOLTENVK "libMoltenVK.dylib"|' "$cfg"
}

cmd_build() {
  local targets="$MODULES" m
  [ "${FULL:-0}" = "1" ] && targets=""
  log "Building ${targets:-the full tree} (make -j$JOBS)"
  [ -f "$WINE_BUILD/Makefile" ] || { echo "run 'configure' first"; exit 1; }
  use_bison
  # shellcheck disable=SC2086 # targets is a word list
  ( cd "$WINE_BUILD" && make -j"$JOBS" $targets ) 2>&1 | tee "$BUILD_DIR/build.log"
  [ "${PIPESTATUS[0]}" = 0 ] || { echo "make failed — see $BUILD_DIR/build.log"; exit 1; }
  rm -rf "$WINE_OUT"; mkdir -p "$WINE_OUT"
  for m in $MODULES; do cp "$WINE_BUILD/$m" "$WINE_OUT/" || exit 1; done
  cp "$WINE_SRC/COPYING.LIB" "$WINE_OUT/" || exit 1
  echo "$CX_VER" > "$WINE_OUT/CROSSOVER_VERSION"
  echo "$SRC_URL" > "$WINE_OUT/SOURCE_URL"
  echo "built $WINE_OUT"
}

case "${1:-all}" in
  deps|fetch|apply|configure|build) "cmd_$1" ;;
  all) cmd_deps; cmd_fetch; cmd_apply; cmd_configure; cmd_build ;;
  *) echo "usage: $0 [all|deps|fetch|apply|configure|build]"; exit 1 ;;
esac