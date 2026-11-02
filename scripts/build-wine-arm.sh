#!/usr/bin/env bash
# build-wine-arm.sh — build the ARM (aarch64, no-Rosetta) Wine module payload for the
# FineWine Patcher, kept deliberately separate from the x64 pipeline (scripts/build-wine.sh)
# so the known-good x64 path is never touched.
#
# What it produces: build/wine-arm-payload/ — a directory shaped exactly like the patcher's
# `Resources/payload/arm/` tree, which scripts/build-app.sh stages when present:
#
#   aarch64-windows/ntoskrnl.exe
#   aarch64-windows/rundll32.exe
#   aarch64-windows/wdfldr.sys
#
# The ARM variant is EXPERIMENTAL: the load-bearing `#ifdef __x86_64__` dispatcher spoof is
# absent on the aarch64 unix side, so this payload is the platform for that experiment — it is
# not expected to "just work" the way x64 does.
#
# SOURCE SELECTION (first match wins) — see below for why CrossOver ARM sources are preferred:
#   1. ARM_SRC_DIR       an already-extracted Wine tree
#   2. ARM_SRC_TARBALL   a tarball holding `sources/wine/` (CrossOver) or `wine-<ver>/` (upstream)
#   3. CX_ARM_VER        fetch crossover-sources-${CX_ARM_VER}.tar.gz from CodeWeavers
#   4. ARM_WINE_TAG      shallow-clone upstream Wine from WineHQ git (default: wine-11.17)
#
# IMPORTANT: the module ABI (wineserver protocol) must match the CrossOver build it is dropped
# into. So the *correct* source is the CrossOver ARM source tree. CodeWeavers has not published
# preview sources yet, so today this falls back to upstream Wine and is expected to need rebasing
# of patches/ — that is fine for an experiment, but wiring CX_ARM_VER to the real
# `crossover-sources-<version>.tar.gz` the moment it exists is the intended path (no other change
# is needed then — the same patches/ are applied unchanged).
#
# SOURCE NOTE (2026-10): there is no public CrossOver ARM source tarball — only
# crossover-sources-26.3.0.tar.gz (the x64 base) is published, and preview version strings 404.
# Per CodeWeavers (Brendan Shanks, wine-devel, Aug 2026) the native-ARM64 Wine support
# (FEX for i386/x86_64 emulation, x18 ABI, 4K pages, PAGEZERO/TSO) is being **upstreamed to
# Wine**, so upstream Wine master/11.17+ is the correct long-term source for this pipeline rather
# than a CrossOver-only tree. Run `scripts/build-wine-arm.sh check` against the newest Wine you
# can as the ARM64 MRs land — the rebase surface shrinks as the base converges. Re-check
# media.codeweavers.com/pub/crossover/source/ for the 27/28 tarball once CrossOver 27 ships.
#
# Usage:
#   scripts/build-wine-arm.sh deps       # Homebrew build deps
#   scripts/build-wine-arm.sh fetch      # obtain + extract the source, init git
#   scripts/build-wine-arm.sh apply      # git apply all of patches/ARM
#   scripts/build-wine-arm.sh check      # non-destructive: report how far patches/ARM gets (clean/fuzz/fail)
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
ARM_WINE_TAG="${ARM_WINE_TAG:-wine-11.17}"
ARM_SRC_URL="${ARM_SRC_URL:-}"
BREW="$(command -v brew || echo /opt/homebrew/bin/brew)"

log(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }
use_bison(){ export PATH="$("$BREW" --prefix bison)/bin:$PATH"; }  # Wine needs bison >= 3.0
# Wine builds the aarch64-windows modules with clang + lld. Apple's clang can't target Windows.
use_pe_toolchain(){ export PATH="$("$BREW" --prefix llvm)/bin:$("$BREW" --prefix lld)/bin:$PATH"; }
verify_source() {
  local file="$1" expected="${ARM_SRC_SHA256:-}" actual
  [ -n "$expected" ] || { echo "ARM_SRC_SHA256 is required when using ARM tarball sources"; exit 1; }
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || { echo "source checksum mismatch for $file"; echo "expected: $expected"; echo "actual:   $actual"; exit 1; }
}

cmd_deps() {
  log "Installing Homebrew build dependencies"
  # bison >= 3 and pkgconf as on the x64 pipeline, mingw-w64 for the x86_64 PE tools, and
  # llvm + lld for the aarch64-windows modules.
  "$BREW" install bison pkgconf mingw-w64 llvm lld || exit 1
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
    verify_source "$tgz"
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
  log "Applying patches/ARM (em-backports -> misc -> ace-core -> macOS)"
  [ -d "$WINE_SRC" ] || { echo "run 'fetch' first"; exit 1; }
  local P="$REPO/patches/ARM" n=0 f
  ( cd "$WINE_SRC"
    for f in $(ls "$P"/stage2-dwproton/em-backports/*.patch | sort) \
             $(ls "$P"/stage2-dwproton/misc/*.patch | sort) \
             $(ls "$P"/stage2-dwproton/ace-core/*.patch | sort) \
             $(ls "$P"/stage1-macos/*.patch | sort); do
      # Fail loudly rather than silently skip.
      git apply "$f" || { echo "patch failed: $f"; exit 1; }
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
  local P="$REPO/patches/ARM"
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
  use_bison; use_pe_toolchain
  # Host (unix) = aarch64, no Rosetta. The PE side stays x86_64 because Endfield is x86_64.
  # Same library opt-outs as the x64 pipeline; add SONAME defines below as it does.
  ( cd "$WINE_BUILD" && CC="/usr/bin/clang -arch arm64" CXX="/usr/bin/clang++ -arch arm64" OBJC="/usr/bin/clang -arch arm64" \
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

# Build the modules, then assemble the payload tree. These are the ARM64 PE modules an arm64 bottle
# loads. ntdll.so and wineserver stay stock: see the note in CrossOverVariant.modules.
cmd_build() {
  log "Building ARM modules (make -j$JOBS)"
  [ -f "$WINE_BUILD/Makefile" ] || { echo "run 'configure' first"; exit 1; }
  use_bison; use_pe_toolchain
  local modules="dlls/ntoskrnl.exe/aarch64-windows/ntoskrnl.exe dlls/wdfldr.sys/aarch64-windows/wdfldr.sys programs/rundll32/aarch64-windows/rundll32.exe"
  # shellcheck disable=SC2086
  ( cd "$WINE_BUILD" && make -j"$JOBS" $modules ) 2>&1 | tee "$BUILD_DIR/build-arm.log"
  [ "${PIPESTATUS[0]}" = 0 ] || { echo "make failed — see $BUILD_DIR/build-arm.log"; exit 1; }

  rm -rf "$PAYLOAD_OUT"; mkdir -p "$PAYLOAD_OUT/aarch64-windows"
  local module
  for module in $modules; do cp "$WINE_BUILD/$module" "$PAYLOAD_OUT/aarch64-windows/"; done
  cp "$WINE_SRC/COPYING.LIB" "$PAYLOAD_OUT/" 2>/dev/null || true
  echo "built $PAYLOAD_OUT"
}

case "${1:-all}" in
  deps|fetch|apply|configure|build|check) "cmd_$1" ;;
  all) cmd_deps; cmd_fetch; cmd_apply; cmd_configure; cmd_build ;;
  *) echo "usage: $0 [all|deps|fetch|apply|configure|build|check]"; exit 1 ;;
esac
