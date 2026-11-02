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
# Output: in a terminal, steps render as a live dashboard (checklist, progress bars, a tail of the
# current step's log; see scripts/lib/build-ui.sh) and each step's FULL output lands in
# build/<step>.log. On CI / pipes the plain "==>" + tee output is used instead (NO_UI=1 forces it).
#
# Usage:
#   scripts/build-wine.sh deps      # install Homebrew build deps
#   scripts/build-wine.sh fetch     # download + extract CrossOver 26.3 wine source, init git
#   scripts/build-wine.sh apply     # git apply all patches/ (em-backports -> misc -> ace-core -> macos fixes)
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
MODULES="dlls/ntdll/ntdll.so dlls/winemac.drv/winemac.so dlls/kernel32/x86_64-windows/kernel32.dll dlls/ntoskrnl.exe/x86_64-windows/ntoskrnl.exe programs/lsass/x86_64-windows/lsass.exe programs/wineboot/x86_64-windows/wineboot.exe programs/rundll32/x86_64-windows/rundll32.exe server/wineserver"
BREW="$(command -v brew || echo /opt/homebrew/bin/brew)"
export MACOSX_DEPLOYMENT_TARGET=10.15

# Terminal dashboard (progress bars + live log tail). Must be sourced before any
# real work so `zsh scripts/build-wine.sh` can hand over to /bin/bash cleanly.
UI_SELF="$0"
. "$REPO/scripts/lib/build-ui.sh"

use_bison(){ export PATH="$("$BREW" --prefix bison)/bin:$PATH"; }  # Wine needs bison >= 3.0; macOS ships 2.3

cmd_deps() {
  ui_begin deps 2 "Installing Homebrew build dependencies"
  # ccache wraps CC/CXX on CI (the workflow sets "CC: ccache clang"); include it here so a
  # cache-miss build installs it too.
  ui_run "$BUILD_DIR/brew.log" "brew install bison mingw-w64 pkgconf ccache" \
    "$BREW" install bison mingw-w64 pkgconf ccache \
    || { echo "brew install failed — see $BUILD_DIR/brew.log"; exit 1; }
  ui_end
}

cmd_fetch() {
  ui_begin fetch 15 "Fetching CrossOver ${CX_VER} source (~150 MB)"
  mkdir -p "$BUILD_DIR"
  local tgz="$BUILD_DIR/crossover-sources-${CX_VER}.tar.gz" rc=0 len=0 cflags="-fL"
  if [ ! -f "$tgz" ]; then
    # Best-effort Content-Length up front → byte-accurate progress bar. In UI mode curl runs
    # silent (-s): its own \r meter would garble the log pane; plain/CI mode keeps the meter.
    len=$(curl -sIL "$SRC_URL" | grep -i '^content-length:' | tail -n 1 | tr -dc '0-9') || len=0
    case "$len" in ''|*[!0-9]*) len=0 ;; esac
    [ "$UI_ACTIVE" = 1 ] && cflags="-fsSL"
    if [ "$len" -gt 0 ]; then
      UI_PROBE_FILE="$tgz"; UI_PROBE_TOTAL="$len"
      # shellcheck disable=SC2086 # cflags is two single flags
      ui_run "$BUILD_DIR/download.log" "downloading crossover-sources-${CX_VER}.tar.gz" \
        curl $cflags "$SRC_URL" -o "$tgz" || rc=$?
      UI_PROBE_FILE=""; UI_PROBE_TOTAL=0
    else
      # shellcheck disable=SC2086
      ui_run "$BUILD_DIR/download.log" "downloading crossover-sources-${CX_VER}.tar.gz (size unknown)" \
        curl $cflags "$SRC_URL" -o "$tgz" || rc=$?
    fi
    [ "$rc" -eq 0 ] || { echo "download failed ($SRC_URL) — see $BUILD_DIR/download.log"; exit 1; }
  fi
  rm -rf "$WINE_SRC" "$BUILD_DIR/sources"; mkdir -p "$WINE_SRC"
  ui_run "$BUILD_DIR/extract.log" "extracting sources/wine" \
    tar xzf "$tgz" -C "$BUILD_DIR" sources/wine \
    || { echo "extract failed — see $BUILD_DIR/extract.log"; exit 1; }
  mv "$BUILD_DIR/sources/wine"/* "$WINE_SRC/"; rm -rf "$BUILD_DIR/sources"
  # Commit a baseline for inspecting patch changes.
  ui_run "$BUILD_DIR/baseline.log" "committing vanilla baseline (git)" \
    sh -c 'cd "$1" || exit 1; shift
           git init -q || exit 1
           git add -A || exit 1
           git -c user.email=build@localhost -c user.name=build commit -qm "$1" || exit 1' \
    ui_sh "$WINE_SRC" "vanilla CrossOver ${CX_VER} wine" \
    || { echo "git baseline failed — see $BUILD_DIR/baseline.log"; exit 1; }
  echo "Wine source: $WINE_SRC ($(cat "$WINE_SRC/VERSION"))"
  ui_end
}

cmd_apply() {
  ui_begin apply 3 "Applying patches (em-backports -> misc -> ace-core -> macOS)"
  [ -d "$WINE_SRC/.git" ] || { echo "run 'fetch' first"; exit 1; }
  local P="$REPO/patches" list n unit
  list="$(ls "$P"/stage2-dwproton/em-backports/*.patch 2>/dev/null | sort)
$(ls "$P"/stage2-dwproton/misc/*.patch 2>/dev/null | sort)
$(ls "$P"/stage2-dwproton/ace-core/*.patch 2>/dev/null | sort)
$(ls "$P"/stage1-macos/*.patch 2>/dev/null | sort)"
  # shellcheck disable=SC2086 # patch paths contain no spaces
  set -- $list
  [ $# -gt 0 ] || { echo "no patches found under $P"; exit 1; }
  n=$#; unit="patches"; [ "$n" -eq 1 ] && unit="patch"
  UI_LINES_RE='^applying '; UI_LINES_TOTAL=$n     # per-patch progress bar
  ui_run "$BUILD_DIR/apply.log" "applying $n $unit" sh -c '
      cd "$1" || exit 1; shift
      for f in "$@"; do
        printf "applying %s\n" "$(basename "$f")"
        git apply "$f" || { echo "patch failed: $f"; exit 1; }
      done
      echo "applied $# patches"' ui_sh "$WINE_SRC" "$@" \
    || { echo "patch application failed — see $BUILD_DIR/apply.log"; exit 1; }
  ui_end
}

cmd_configure() {
  ui_begin configure 7 "Configuring 64-bit-only Wine"
  [ -d "$WINE_SRC" ] || { echo "run 'fetch' first"; exit 1; }
  rm -rf "$WINE_BUILD"; mkdir -p "$WINE_BUILD"
  use_bison
  # Matching build/host lets configure run x86_64 probes under Rosetta while shell tools
  # stay native. Disable optional libraries: Homebrew's are arm64, and these modules don't need them.
  ui_run "$BUILD_DIR/configure.log" "configure (x86_64 probes under Rosetta)" \
    sh -c 'cd "$1" || exit 1; shift; exec "$@"' ui_sh "$WINE_BUILD" \
      env CC="clang -arch x86_64" CXX="clang++ -arch x86_64" OBJC="clang -arch x86_64" \
      "$WINE_SRC/configure" \
      --build=x86_64-apple-darwin --host=x86_64-apple-darwin --enable-archs=x86_64 \
      --disable-tests --without-x --without-freetype --without-gnutls --without-sdl --without-vulkan \
      --without-krb5 --without-gstreamer --without-gphoto --without-sane --without-pcap --without-usb \
      --without-cups --without-coreaudio \
    || { echo "configure failed — see $BUILD_DIR/configure.log"; exit 1; }
  # Supply library names used by win32u even with --without-vulkan.
  local cfg="$WINE_BUILD/include/config.h"
  sed -i '' 's|/\* #undef SONAME_LIBVULKAN \*/|#define SONAME_LIBVULKAN "libvulkan.1.dylib"|' "$cfg"
  sed -i '' 's|/\* #undef SONAME_LIBMOLTENVK \*/|#define SONAME_LIBMOLTENVK "libMoltenVK.dylib"|' "$cfg"
  ui_end
}

cmd_build() {
  local targets="$MODULES" m
  [ "${FULL:-0}" = "1" ] && targets=""
  local what="the full tree"; [ -n "$targets" ] && what="Wine modules"
  ui_begin build 73 "Building $what (make -j$JOBS)"
  [ -f "$WINE_BUILD/Makefile" ] || { echo "run 'configure' first"; exit 1; }
  use_bison
  # Progress = lines of make output vs. the total learned from the last successful
  # build of this mode; the first-ever build shows a spinner + running line count.
  local learn
  if [ -n "$targets" ]; then learn="$WINE_BUILD/.ui-lines-modules"; else learn="$WINE_BUILD/.ui-lines-full"; fi
  UI_LINES_TOTAL=0
  [ -f "$learn" ] && UI_LINES_TOTAL="$(cat "$learn" 2>/dev/null)"
  case "$UI_LINES_TOTAL" in ''|*[!0-9]*) UI_LINES_TOTAL=0 ;; esac
  # shellcheck disable=SC2086 # targets is a word list
  ui_run "$BUILD_DIR/build.log" "make -j$JOBS" \
    sh -c 'cd "$1" || exit 1; shift; exec make -j"$1" $2' ui_sh "$WINE_BUILD" "$JOBS" "$targets" \
    || { echo "make failed — see $BUILD_DIR/build.log"; exit 1; }
  ui_learn "$learn" "$(wc -l < "$BUILD_DIR/build.log" | tr -d ' ')"
  rm -rf "$WINE_OUT"; mkdir -p "$WINE_OUT"
  for m in $MODULES; do cp "$WINE_BUILD/$m" "$WINE_OUT/" || exit 1; done
  cp "$WINE_SRC/COPYING.LIB" "$WINE_OUT/" || exit 1
  echo "$CX_VER" > "$WINE_OUT/CROSSOVER_VERSION"
  echo "$SRC_URL" > "$WINE_OUT/SOURCE_URL"
  echo "built $WINE_OUT"
  ui_end
}

ui_init "FineWine — CrossOver ${CX_VER} Wine (x86_64)"
mkdir -p "$BUILD_DIR"   # every step logs into build/<step>.log
case "${1:-all}" in
  deps|fetch|apply|configure|build) "cmd_$1" ;;
  all) cmd_deps; cmd_fetch; cmd_apply; cmd_configure; cmd_build ;;
  *) echo "usage: $0 [all|deps|fetch|apply|configure|build]"; exit 1 ;;
esac
rc=$?
ui_finish
exit "$rc"
