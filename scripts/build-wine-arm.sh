#!/usr/bin/env bash
# build-wine-arm.sh — build the ARM (aarch64, no-Rosetta) Wine module payload for the
# FineWine Patcher, kept deliberately separate from the x64 pipeline (scripts/build-wine.sh)
# so the known-good x64 path is never touched.
#
# What it produces: build/wine-arm-payload/ — a directory shaped exactly like the patcher's
# `Resources/payload/arm/` tree, which scripts/build-app.sh stages when present:
#
#   aarch64-unix/ntdll.so                (patched aarch64 unix ntdll — the host side)
#   x86_64-windows/kernel32.dll          (x86_64 PE — the emulated x86_64 game process)
#   x86_64-windows/ntoskrnl.exe
#   aarch64-windows/lsass.exe            (host-arch programs: wineboot + the lsass stub it starts)
#   aarch64-windows/wineboot.exe
#   lib/aarch64/libMoltenVK.dylib        (patched aarch64 MoltenVK, if built)
#
# The ARM variant is EXPERIMENTAL: the load-bearing `#ifdef __x86_64__` dispatcher spoof is
# absent on the aarch64 unix side, so this payload is the platform for that experiment — it is
# not expected to "just work" the way x64 does.
#
# SOURCE SELECTION (first match wins) — see below for why CrossOver ARM sources are preferred:
#   1. ARM_SRC_DIR       an already-extracted Wine tree
#   2. ARM_SRC_TARBALL   a tarball holding `sources/wine/` (CrossOver) or `wine-<ver>/` (upstream)
#   3. CX_ARM_VER        fetch crossover-sources-${CX_ARM_VER}.tar.gz from CodeWeavers
#   4. ARM_WINE_TAG      shallow-clone upstream Wine from WineHQ git (default: none)
#
# IMPORTANT: the module ABI (wineserver protocol) must match the CrossOver build it is dropped
# into. So the *correct* source is the CrossOver ARM source tree. CodeWeavers has not published
# preview sources yet, so today this falls back to upstream Wine and is expected to need rebasing
# of patches/ — that is fine for an experiment, but wiring CX_ARM_VER to the real
# `crossover-sources-<version>.tar.gz` the moment it exists is the intended path (no other change
# is needed then — the same patches/ are applied unchanged).
#
# Usage:
#   scripts/build-wine-arm.sh deps       # Homebrew build deps
#   scripts/build-wine-arm.sh fetch      # obtain + extract the source, init git
#   scripts/build-wine-arm.sh apply      # git apply all patches/ (same series as x64)
#   scripts/build-wine-arm.sh check      # non-destructive: report how far patches/ get (clean/fuzz/fail)
#   scripts/build-wine-arm.sh configure  # configure aarch64 host + x86_64 PE
#   scripts/build-wine-arm.sh build      # make the modules into build/wine-arm-payload
#   scripts/build-wine-arm.sh all        # deps -> fetch -> apply -> configure -> build
#
# Env: BUILD_DIR (default ./build), JOBS (default: all cores), ARM_WINE_ARCHS (default
#      "aarch64,x86_64").

set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$REPO/build}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
WINE_SRC="$BUILD_DIR/wine-arm-src"          # extracted sources/wine
WINE_BUILD="$BUILD_DIR/wine-arm-build"      # out-of-tree build
WINE_OUT="$BUILD_DIR/wine-arm-out"          # flat module output
PAYLOAD_OUT="$BUILD_DIR/wine-arm-payload"   # payload-shaped output consumed by build-app.sh
ARM_WINE_ARCHS="${ARM_WINE_ARCHS:-aarch64,x86_64}"
CX_ARM_VER="${CX_ARM_VER:-}"
ARM_SRC_DIR="${ARM_SRC_DIR:-}"
ARM_SRC_TARBALL="${ARM_SRC_TARBALL:-}"
ARM_WINE_TAG="${ARM_WINE_TAG:-}"
ARM_SRC_URL="${ARM_SRC_URL:-}"
BREW="$(command -v brew || echo /opt/homebrew/bin/brew)"

# aarch64 host libs live in lib/aarch64 (CrossOver 27 layout, no lib64).
ARM_RPATH="@loader_path/../../../lib/aarch64"

log(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }
use_bison(){ export PATH="$("$BREW" --prefix bison)/bin:$PATH"; }  # Wine needs bison >= 3.0

cmd_deps() {
  log "Installing Homebrew build dependencies"
  # bison >= 3, pkgconf, ccache as on the x64 pipeline. mingw-w64 supplies the x86_64 PE
  # cross-compiler for the emulated game's kernel32/ntoskrnl. The aarch64-windows host programs
  # (wineboot/lsass) need an aarch64 PE toolchain — Wine upstream expects llvm-mingw
  # (aarch64-w64-mingw32-*); install it separately (it is not a Homebrew formula).
  "$BREW" install bison pkgconf ccache mingw-w64 || exit 1
  command -v aarch64-w64-mingw32-gcc >/dev/null 2>&1 \
    || command -v aarch64-w64-mingw32-clang >/dev/null 2>&1 \
    || echo "  ! no aarch64 PE toolchain found (need llvm-mingw's aarch64-w64-mingw32-*) — building aarch64-windows wineboot/lsass will fail"
}

fetch_source() {
  # 1. Already-extracted tree
  if [ -n "$ARM_SRC_DIR" ]; then
    [ -d "$ARM_SRC_DIR" ] || { echo "ARM_SRC_DIR not found: $ARM_SRC_DIR"; exit 1; }
    # Copy (never move) — the caller's tree is left untouched.
    cp -R "$ARM_SRC_DIR" "$WINE_SRC"
    return
  fi
  # 2/3. A tarball (explicit, or CodeWeavers by version)
  local tgz="$ARM_SRC_TARBALL" url="$ARM_SRC_URL"
  if [ -z "$tgz" ] && [ -n "$CX_ARM_VER" ]; then
    tgz="$BUILD_DIR/crossover-sources-${CX_ARM_VER}.tar.gz"
    [ -z "$url" ] && url="https://media.codeweavers.com/pub/crossover/source/crossover-sources-${CX_ARM_VER}.tar.gz"
  fi
  if [ -n "$tgz" ]; then
    [ -f "$tgz" ] || { [ -n "$url" ] && curl -fL "$url" -o "$tgz" || { echo "source tarball not found: $tgz"; exit 1; }; }
    mkdir -p "$BUILD_DIR/sources-arm"
    tar xzf "$tgz" -C "$BUILD_DIR/sources-arm" || { echo "extract failed ($tgz)"; exit 1; }
    local inner
    inner="$(find "$BUILD_DIR/sources-arm" -maxdepth 3 -type d -name wine | head -1)"
    [ -n "$inner" ] || { echo "no wine/ tree inside $tgz"; exit 1; }
    cp -R "$inner" "$WINE_SRC"; rm -rf "$BUILD_DIR/sources-arm"
    return
  fi
  # 4. Upstream Wine from WineHQ git
  if [ -n "$ARM_WINE_TAG" ]; then
    git init -q "$WINE_SRC" && git -C "$WINE_SRC" fetch -q --depth 1 \
      https://gitlab.winehq.org/wine/wine.git "refs/tags/$ARM_WINE_TAG" \
      && git -C "$WINE_SRC" checkout -q FETCH_HEAD || { echo "WineHQ fetch failed ($ARM_WINE_TAG)"; exit 1; }
    return
  fi
  echo "No ARM Wine source. Set one of:"
  echo "  CX_ARM_VER=<version>      (fetch crossover-sources-<version>.tar.gz — preferred once published)"
  echo "  ARM_SRC_TARBALL=<file>    (a CrossOver/upstream source tarball you already have)"
  echo "  ARM_SRC_DIR=<dir>         (an already-extracted Wine tree)"
  echo "  ARM_WINE_TAG=wine-<ver>   (upstream WineHK fallback, experimental abi)"
  exit 1
}

cmd_fetch() {
  log "Fetching/extracting the ARM Wine source"
  mkdir -p "$BUILD_DIR"; rm -rf "$WINE_SRC"
  fetch_source
  ( cd "$WINE_SRC" && git init -q 2>/dev/null; git add -A 2>/dev/null; \
    git -c user.email=build@localhost -c user.name=build commit -qm "vanilla ARM wine" 2>/dev/null ) || true
  echo "Wine source: $WINE_SRC (VERSION: $(cat "$WINE_SRC/VERSION" 2>/dev/null || echo '?'))"
}

cmd_apply() {
  log "Applying patches/ (same series as x64: em-backports -> misc -> ace-core -> macOS)"
  [ -d "$WINE_SRC" ] || { echo "run 'fetch' first"; exit 1; }
  local P="$REPO/patches" n=0 f
  ( cd "$WINE_SRC"
    for f in $(ls "$P"/stage2-dwproton/em-backports/*.patch | sort) \
             $(ls "$P"/stage2-dwproton/misc/*.patch | sort) \
             $(ls "$P"/stage2-dwproton/ace-core/*.patch | sort) \
             $(ls "$P"/stage1-macos/*.patch | sort); do
      # NOTE: with upstream Wine these may need rebasing; with the CrossOver ARM sources they
      # should apply as-is (same base as x64). Fail loudly rather than silently skip.
      git apply "$f" || { echo "patch failed: $f (expected if this is upstream Wine, not CrossOver)"; exit 1; }
      n=$((n+1))
    done
    echo "applied $n patches" ) || exit 1
}

# Non-destructive applicability report against the fetched source: how much of patches/ applies
# cleanly (git apply), how much only with -F3 fuzz (mechanical line drift), and what genuinely
# conflicts (needs rebasing). Restores the tree afterwards. Run this first — it tells you how far
# the CrossOver-26.3-era series is from the source you pointed the pipeline at, before a long build.
cmd_check() {
  log "Checking patch applicability against $WINE_SRC"
  [ -d "$WINE_SRC" ] || { echo "run 'fetch' first"; exit 1; }
  [ -d "$WINE_SRC/.git" ] || { echo "source is not a git repo — cannot check non-destructively"; exit 1; }
  local P="$REPO/patches"
  ( cd "$WINE_SRC"
    git reset -q --hard && git clean -qfd && git clean -qfdx
    local clean=0 fuzz=0 fail=0 f b
    for f in $(ls "$P"/stage2-dwproton/em-backports/*.patch | sort) \
             $(ls "$P"/stage2-dwproton/misc/*.patch | sort) \
             $(ls "$P"/stage2-dwproton/ace-core/*.patch | sort) \
             $(ls "$P"/stage1-macos/*.patch | sort); do
      b="$(basename "$f")"
      if git apply "$f" 2>/dev/null; then
        clean=$((clean+1))
      elif patch -p1 --forward --batch --fuzz=3 < "$f" >/dev/null 2>&1; then
        fuzz=$((fuzz+1)); printf '  fuzz  %s\n' "$b"
      else
        fail=$((fail+1)); printf '  FAIL  %s\n' "$b"
      fi
    done
    echo "-----"
    echo "clean=$clean  fuzz=$fuzz  failed=$fail  (of $((clean+fuzz+fail)))"
    git reset -q --hard && git clean -qfd
    echo "working tree restored"
  )
}

cmd_configure() {
  log "Configuring aarch64 host + x86_64 PE ($ARM_WINE_ARCHS)"
  [ -d "$WINE_SRC" ] || { echo "run 'fetch' first"; exit 1; }
  rm -rf "$WINE_BUILD"; mkdir -p "$WINE_BUILD"
  use_bison
  # Host (unix) = aarch64, no Rosetta. The PE side stays x86_64 because Endfield is x86_64.
  # Same library opt-outs as the x64 pipeline; add SONAME defines below as it does.
  ( cd "$WINE_BUILD" && CC="clang -arch arm64" CXX="clang++ -arch arm64" OBJC="clang -arch arm64" \
      "$WINE_SRC/configure" \
      --build=aarch64-apple-darwin --host=aarch64-apple-darwin --enable-archs="$ARM_WINE_ARCHS" \
      --disable-tests --without-x --without-freetype --without-gnutls --without-sdl --without-vulkan \
      --without-krb5 --without-gstreamer --without-gphoto --without-sane --without-pcap --without-usb \
      --without-cups --without-coreaudio
  ) 2>&1 | tee "$BUILD_DIR/configure-arm.log"
  [ "${PIPESTATUS[0]}" = 0 ] || { echo "configure failed — see $BUILD_DIR/configure-arm.log"; exit 1; }
  local cfg="$WINE_BUILD/include/config.h"
  [ -f "$cfg" ] && {
    sed -i '' 's|/\* #undef SONAME_LIBVULKAN \*/|#define SONAME_LIBVULKAN "libvulkan.1.dylib"|' "$cfg"
    sed -i '' 's|/\* #undef SONAME_LIBMOLTENVK \*/|#define SONAME_LIBMOLTENVK "libMoltenVK.dylib"|' "$cfg"
  }
}

# Build the module set, then assemble the payload tree.
cmd_build() {
  log "Building ARM modules (make -j$JOBS)"
  [ -f "$WINE_BUILD/Makefile" ] || { echo "run 'configure' first"; exit 1; }
  use_bison
  local targets="dlls/ntdll/ntdll.so \
    dlls/kernel32/x86_64-windows/kernel32.dll \
    dlls/ntoskrnl.exe/x86_64-windows/ntoskrnl.exe \
    programs/lsass/aarch64-windows/lsass.exe \
    programs/wineboot/aarch64-windows/wineboot.exe"
  # shellcheck disable=SC2086
  ( cd "$WINE_BUILD" && make -j"$JOBS" $targets ) 2>&1 | tee "$BUILD_DIR/build-arm.log"
  [ "${PIPESTATUS[0]}" = 0 ] || { echo "make failed — see $BUILD_DIR/build-arm.log"; exit 1; }

  rm -rf "$WINE_OUT" "$PAYLOAD_OUT"
  mkdir -p "$WINE_OUT" "$PAYLOAD_OUT/aarch64-unix" "$PAYLOAD_OUT/x86_64-windows" \
           "$PAYLOAD_OUT/aarch64-windows" "$PAYLOAD_OUT/lib/aarch64"
  # Locate each module (paths shift between Wine trees) and copy into the payload shape.
  # kernel32/ntoskrnl are x86_64 PE (the emulated game process); wineboot/lsass are the
  # host-arch aarch64-windows programs.
  find_module() { find "$WINE_BUILD" -type f -path "*$1" 2>/dev/null | head -1; }
  local pair
  for pair in "dlls/ntdll/ntdll.so:aarch64-unix/ntdll.so" \
              "x86_64-windows/kernel32.dll:x86_64-windows/kernel32.dll" \
              "x86_64-windows/ntoskrnl.exe:x86_64-windows/ntoskrnl.exe" \
              "aarch64-windows/lsass.exe:aarch64-windows/lsass.exe" \
              "aarch64-windows/wineboot.exe:aarch64-windows/wineboot.exe"; do
    local src dst
    src="$(find_module "${pair%%:*}")"; dst="${pair##*:}"
    [ -n "$src" ] || { echo "ERROR: could not find ${pair%%:*} in the build tree"; exit 1; }
    cp "$src" "$PAYLOAD_OUT/$dst"
    cp "$src" "$WINE_OUT/"
  done

  # Patch the aarch64 ntdll.so rpath so cxcompatdb.so can resolve libgnutls from lib/aarch64.
  local NT="$PAYLOAD_OUT/aarch64-unix/ntdll.so"
  if otool -l "$NT" >/dev/null 2>&1; then
    if ! otool -l "$NT" | grep -A2 LC_RPATH | grep -q 'lib/aarch64'; then
      install_name_tool -add_rpath "$ARM_RPATH" "$NT"
    fi
    otool -l "$NT" | grep -A2 LC_RPATH | grep -q 'lib/aarch64' \
      && echo "  ntdll.so LC_RPATH -> lib/aarch64" \
      || { echo "ERROR: could not add the lib/aarch64 rpath to ntdll.so"; exit 1; }
  fi

  # Ad-hoc sign the Mach-O halves so they load on Apple Silicon.
  codesign --force --sign - "$NT" 2>/dev/null || true

  # MoltenVK (aarch64): use the patched aarch64 build if present. Optional — the patcher
  # reports an incomplete payload if it is missing.
  local MVK="$BUILD_DIR/moltenvk-out-aarch64/libMoltenVK.dylib"
  if [ -f "$MVK" ]; then
    cp "$MVK" "$PAYLOAD_OUT/lib/aarch64/libMoltenVK.dylib"
    install_name_tool -id "@rpath/libMoltenVK.dylib" "$PAYLOAD_OUT/lib/aarch64/libMoltenVK.dylib" 2>/dev/null || true
    codesign --force --sign - "$PAYLOAD_OUT/lib/aarch64/libMoltenVK.dylib" 2>/dev/null || true
    echo "  aarch64 MoltenVK from $MVK"
  else
    echo "  ! no $MVK — build it with: MVK_ARCH=aarch64 scripts/build-moltenvk.sh all"
  fi

  cp "$WINE_SRC/COPYING.LIB" "$PAYLOAD_OUT/" 2>/dev/null || true
  echo "built $PAYLOAD_OUT"
}

case "${1:-all}" in
  deps|fetch|apply|configure|build|check) "cmd_$1" ;;
  all) cmd_deps; cmd_fetch; cmd_apply; cmd_configure; cmd_build ;;
  *) echo "usage: $0 [all|deps|fetch|apply|configure|build|check]"; exit 1 ;;
esac
