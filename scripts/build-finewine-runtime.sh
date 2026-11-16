#!/usr/bin/env bash
# build-finewine-runtime.sh — build FineWine's own Wine runtime for Apple Silicon.
#
# The result is build/finewine-runtime/: a folder with bin/, lib/, share/ and a runtime.json,
# which FineWine installs from Settings > Add Runtime…. Nothing here comes from CrossOver's
# binaries; it is upstream Wine plus this repository's patches.
#
#   source   upstream Wine (WINE_TAG, default wine-11.21), shallow-cloned from WineHQ
#   patches  patches/ARM (the ARM series, minus the x86-only ones listed in SKIP_ARM_PATCHES)
#            then patches/runtime/*.patch (runtime-only work, such as MSync)
#   build    native arm64 Mac side; Windows side as ARM64X (--enable-archs=arm64ec,aarch64),
#            the same shape CrossOver ARM uses, so x64 programs can load the DLLs once an
#            x64 emulator is present
#
# Usage:
#   scripts/build-finewine-runtime.sh deps       # Homebrew build dependencies
#   scripts/build-finewine-runtime.sh fetch      # clone the Wine source
#   scripts/build-finewine-runtime.sh apply      # apply the patch series
#   scripts/build-finewine-runtime.sh configure
#   scripts/build-finewine-runtime.sh build
#   scripts/build-finewine-runtime.sh package    # install into build/finewine-runtime + runtime.json
#   scripts/build-finewine-runtime.sh archive    # make the release archive (stripped runtime only)
#   scripts/build-finewine-runtime.sh all        # everything above, in order
#
# The runtime this makes runs ARM64 Windows programs. Two more scripts complete it, and their
# output is added by `package` whenever it exists:
#   scripts/build-fex.sh all    x64 programs, through the FEX emulator
#   scripts/build-dxmt.sh all   Direct3D 10 and 11, through DXMT on Metal
# scripts/test-finewine-runtime.sh checks the result.
#
# The runtime is always built the same way: compiled with debug information, then stripped, with
# the unstripped files kept in build/finewine-runtime-symbols for local debugging. Released
# artifacts contain only the stripped runtime; `archive` refuses to run otherwise.
#
# Env: BUILD_DIR (default ./build), JOBS (default: all cores), WINE_TAG, RUNTIME_VERSION
#      (default 1; part of the runtime's id), WINE_SRC_DIR (use an existing Wine checkout
#      instead of cloning; it is copied, never modified).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/scripts/lib/sources-lock.sh"; lock_load   # WINE_TAG, WINE_COMMIT, BREW_*_MAJOR
BUILD_DIR="${BUILD_DIR:-$REPO/build}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
# WINE_TAG and WINE_COMMIT come from finewine-sources.lock
RUNTIME_VERSION="${RUNTIME_VERSION:-1}"
SRC="$BUILD_DIR/finewine-runtime-src"
OBJ="$BUILD_DIR/finewine-runtime-build"
STAGE="$BUILD_DIR/finewine-runtime-stage"
OUT="$BUILD_DIR/finewine-runtime"
BREW="$(command -v brew || echo /opt/homebrew/bin/brew)"

# ARM-series patches that can't go into an ARM64X build. In ARM64EC code __x86_64__ is defined
# but x86 assembly does not assemble, and both of these add an x86 `int3` stub to kernel32.
SKIP_ARM_PATCHES="
0009-HACK-kernel32-Spoof-GetProcAddress-of-KiUserApcDispa.patch
0010-HACK-kernel32-Lock-GetProcAddress-hack-to-when-neede.patch
"

log(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

# Homebrew bison (the system one is too old for Wine) and LLVM + lld for the Windows side.
toolchain(){
  export PATH="$("$BREW" --prefix bison)/bin:$("$BREW" --prefix llvm)/bin:$("$BREW" --prefix lld)/bin:$PATH"
}

cmd_deps(){
  log "Installing build dependencies with Homebrew"
  "$BREW" install bison pkgconf llvm lld freetype gnutls sdl2 molten-vk
  check_tools
}

# The Homebrew tools that shape what is built, against the major versions in the lock file.
check_tools(){
  lock_check_brew llvm "${BREW_LLVM_MAJOR:-}"
  lock_check_brew lld "${BREW_LLD_MAJOR:-}"
  lock_check_brew bison "${BREW_BISON_MAJOR:-}"
}

cmd_fetch(){
  log "Fetching Wine ($WINE_TAG)"
  mkdir -p "$BUILD_DIR"; rm -rf "$SRC"
  if [ -n "${WINE_SRC_DIR:-}" ]; then
    [ -d "$WINE_SRC_DIR" ] || die "WINE_SRC_DIR not found: $WINE_SRC_DIR"
    cp -R "$WINE_SRC_DIR" "$SRC"
    git -C "$SRC" checkout -q -- . 2>/dev/null || true
    git -C "$SRC" clean -qfdx 2>/dev/null || true
  else
    git init -q "$SRC"
    git -C "$SRC" fetch -q --depth 1 https://gitlab.winehq.org/wine/wine.git "refs/tags/$WINE_TAG"
    git -C "$SRC" checkout -q FETCH_HEAD
  fi
  [ -n "${WINE_SRC_DIR:-}" ] || lock_check "Wine $WINE_TAG" "$(git -C "$SRC" rev-parse HEAD)" "${WINE_COMMIT:-}"
  echo "source: $SRC ($(cat "$SRC/VERSION"), $(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo 'not a git tree'))"
}

patch_series(){
  local P="$REPO/patches/ARM" f
  for f in $(ls "$P"/stage2-dwproton/misc/*.patch | sort) \
           $(ls "$P"/stage2-dwproton/ace-core/*.patch | sort) \
           $(ls "$P"/stage1-macos/*.patch | sort); do
    case "$SKIP_ARM_PATCHES" in *"$(basename "$f")"*) continue ;; esac
    echo "$f"
  done
  ls "$REPO"/patches/runtime/*.patch 2>/dev/null | sort || true
}

cmd_apply(){
  log "Applying patches"
  [ -d "$SRC" ] || die "run 'fetch' first"
  local n=0 f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    git -C "$SRC" apply "$f" || die "patch failed: $f"
    n=$((n+1))
  done < <(patch_series)
  # The server protocol changed (MSync adds a reply field): regenerate the files derived from it.
  ( cd "$SRC" && perl tools/make_requests )
  echo "applied $n patches"
}

cmd_configure(){
  log "Configuring"
  check_tools
  [ -d "$SRC" ] || die "run 'fetch' first"
  toolchain
  local hb; hb="$("$BREW" --prefix)"
  mkdir -p "$OBJ"
  # x86_64_CC: the ARM64EC modules contain a few x86_64 objects. Left alone, configure picks
  # Homebrew's mingw gcc for them when it is installed, and its assembler rejects Wine's code.
  # Everything is passed as configure arguments, not environment variables: make re-runs
  # configure by itself when the source's configure script changes, and only arguments are
  # remembered for that.
  # PE_CFLAGS: the Windows side is compiled for the CPUs it will run on. Every Apple silicon
  # Mac implements ARMv8.4-A, and with it the single-instruction atomic operations that locks
  # and reference counts are made of; the default, a 2011 baseline, uses retry loops for them
  # (measured: 1.5 times slower, tests/runtime/bench.c). Not -mcpu=apple-m1: clang 23 fails on
  # Wine's exception-handling code with it ("Failed to evaluate function length in SEH unwind info").
  local PE_CFLAGS="-g -O2 -march=armv8.4-a"
  ( cd "$OBJ" && "$SRC/configure" --build=aarch64-apple-darwin --host=aarch64-apple-darwin \
        x86_64_CC=clang \
        aarch64_CFLAGS="$PE_CFLAGS" arm64ec_CFLAGS="$PE_CFLAGS" \
        CC="/usr/bin/clang -arch arm64" CXX="/usr/bin/clang++ -arch arm64" OBJC="/usr/bin/clang -arch arm64" \
        PKG_CONFIG_PATH="$hb/lib/pkgconfig" CPPFLAGS="-I$hb/include" LDFLAGS="-L$hb/lib" \
        --enable-archs=arm64ec,aarch64 --prefix=/ --disable-tests \
        --without-x --without-krb5 --without-gstreamer --without-gphoto --without-sane --without-pcap \
        --without-usb --without-cups --without-opencl --without-pcsclite --without-dbus --without-netapi
  ) > "$BUILD_DIR/configure-runtime.log" 2>&1 || die "configure failed, see $BUILD_DIR/configure-runtime.log"
  # configure looks for libvulkan; on macOS Vulkan is MoltenVK, which the runtime bundles.
  sed -i '' 's|/\* #undef SONAME_LIBMOLTENVK \*/|#define SONAME_LIBMOLTENVK "libMoltenVK.dylib"|' "$OBJ/include/config.h"
  grep -q '^x86_64_CC = clang' "$OBJ/Makefile" || die "configure did not take clang as the x86_64 compiler"
  grep -q '^aarch64_CFLAGS = .*-march=armv8.4-a' "$OBJ/Makefile" || die "configure did not take the Windows-side compiler flags"
  echo "configured: $OBJ"
}

cmd_build(){
  log "Building Wine ($JOBS jobs)"
  [ -f "$OBJ/Makefile" ] || die "run 'configure' first"
  toolchain
  # If make re-ran configure (see cmd_configure), the hand-set MoltenVK name is gone again.
  fix_config(){ sed -i '' 's|/\* #undef SONAME_LIBMOLTENVK \*/|#define SONAME_LIBMOLTENVK "libMoltenVK.dylib"|' "$OBJ/include/config.h"; }
  make -C "$OBJ" Makefile > /dev/null 2>&1 || true
  fix_config
  grep -q '^x86_64_CC = clang' "$OBJ/Makefile" || die "the Makefile lost clang as the x86_64 compiler; run 'configure' again"
  make -C "$OBJ" -j"$JOBS" > "$BUILD_DIR/build-runtime.log" 2>&1 \
    || { grep -n ' error: \|Error [0-9]' "$BUILD_DIR/build-runtime.log" | tail -5; die "build failed, see $BUILD_DIR/build-runtime.log"; }
  [ -x "$OBJ/loader/wine" ] && [ -x "$OBJ/server/wineserver" ] || die "the build produced no wine or wineserver"
}

# Copies a Homebrew dylib and the Homebrew dylibs it needs into the runtime's lib folder, and
# points their references at each other, so the runtime runs on a Mac without Homebrew.
bundle_dylib(){
  local src="$1" name dep
  name="$(basename "$src")"
  [ -f "$OUT/lib/$name" ] && return 0
  cp -L "$src" "$OUT/lib/$name"; chmod u+w "$OUT/lib/$name"
  install_name_tool -id "@rpath/$name" "$OUT/lib/$name" 2>/dev/null
  otool -L "$src" | awk 'NR>1{print $1}' | grep -E "^($("$BREW" --prefix)|@rpath|@loader_path)" | while IFS= read -r dep; do
    local real="$dep"
    case "$dep" in
      @rpath/*|@loader_path/*) real="$(dirname "$(readlink -f "$src" 2>/dev/null || echo "$src")")/$(basename "$dep")" ;;
    esac
    [ -f "$real" ] || continue
    [ "$(basename "$real")" = "$name" ] && continue
    bundle_dylib "$real"
    install_name_tool -change "$dep" "@loader_path/$(basename "$real")" "$OUT/lib/$name" 2>/dev/null
  done
  codesign --force --sign - "$OUT/lib/$name" 2>/dev/null
}

# Wine is compiled with debug information, which is most of what it builds (1.7 GB against
# 856 MB). The runtime is always stripped; the unstripped files are kept beside it in
# build/finewine-runtime-symbols, at the same relative paths, for anyone who builds locally and
# wants to debug or symbolize a crash address. That folder is local only: it is never part of
# the runtime, of the archive `archive` makes, or of a released FineWine.
strip_runtime(){
  local symbols="$BUILD_DIR/finewine-runtime-symbols" f rel before after
  before="$(du -sk "$OUT" | cut -f1)"
  rm -rf "$symbols"
  # Windows-side modules (PE files) and Mac-side modules and programs (Mach-O files).
  while IFS= read -r f; do
    rel="${f#$OUT/}"
    mkdir -p "$symbols/$(dirname "$rel")"; cp -p "$f" "$symbols/$rel"
    case "$f" in
      */aarch64-windows/*) llvm-strip --strip-debug "$f" 2>/dev/null || true ;;
      *) strip -S -x "$f" 2>/dev/null || true ;;
    esac
  done < <(find "$OUT/lib/wine/aarch64-windows" "$OUT/lib/wine/aarch64-unix" "$OUT/bin" -type f \
             \( -name '*.dll' -o -name '*.exe' -o -name '*.sys' -o -name '*.drv' -o -name '*.ocx' -o -name '*.cpl' \
                -o -name '*.acm' -o -name '*.ax' -o -name '*.tlb' -o -name '*.so' -o -name '*.com' -o -name '*.ds' \
                -o -name '*.msstyles' -o -perm -u+x \) ! -name '*.a' ! -name '*.pl')
  after="$(du -sk "$OUT" | cut -f1)"
  echo "stripped: $((before / 1024)) MB -> $((after / 1024)) MB; symbols kept in $symbols ($(du -sh "$symbols" | cut -f1), local only)"
}

# Lists files in the runtime that still carry debug information. Prints nothing when clean.
find_debug_info(){
  local f
  while IFS= read -r f; do
    if llvm-objdump -h "$f" 2>/dev/null | grep -qE '[[:space:]]\.debug_|[[:space:]]__debug_'; then echo "${f#$OUT/}"; fi
  done < <(find "$OUT" -type f \( -name '*.dll' -o -name '*.exe' -o -name '*.sys' -o -name '*.drv' -o -name '*.so' -o -name '*.dylib' \))
}

# The archive that gets released: the stripped runtime folder and nothing else.
cmd_archive(){
  log "Archiving the runtime for release"
  [ -f "$OUT/runtime.json" ] || die "run 'package' first"
  toolchain
  local id leftovers archive
  leftovers="$(find_debug_info)"
  [ -z "$leftovers" ] || { echo "$leftovers" | head -n 10; die "these files still carry debug information; not archiving"; }
  id="$(sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' "$OUT/runtime.json")"
  archive="$BUILD_DIR/$id.tar.xz"
  # Only the runtime folder goes in, under its id; the symbols folder is a sibling, not a child.
  tar -C "$BUILD_DIR" -cf - -s "|^finewine-runtime|$id|" finewine-runtime | xz -T0 -6 > "$archive"
  shasum -a 256 "$archive" | awk '{print $1}' > "$archive.sha256"
  echo "archive: $archive ($(du -h "$archive" | cut -f1)), sha256 $(cat "$archive.sha256")"
}

cmd_package(){
  log "Packaging the runtime"
  [ -x "$OBJ/loader/wine" ] || die "run 'build' first"
  toolchain
  # Install into a staging folder first: the existing runtime is only replaced once that worked.
  rm -rf "$STAGE"
  make -C "$OBJ" install DESTDIR="$STAGE" > "$BUILD_DIR/install-runtime.log" 2>&1 \
    || { rm -rf "$STAGE"; die "install failed, see $BUILD_DIR/install-runtime.log (the existing runtime was left alone)"; }
  rm -rf "$OUT"
  mkdir -p "$OUT"
  for d in bin lib share; do [ -d "$STAGE/$d" ] && mv "$STAGE/$d" "$OUT/$d"; done
  rm -rf "$STAGE" "$OUT/share/man" "$OUT/include"

  local hb; hb="$("$BREW" --prefix)"
  # The libraries Wine opens by name at run time. FineWine puts <runtime>/lib on
  # DYLD_FALLBACK_LIBRARY_PATH, so they only need to be here.
  for lib in "$hb/lib/libfreetype.6.dylib" "$hb/lib/libgnutls.30.dylib" "$hb/lib/libSDL2-2.0.0.dylib"; do
    [ -f "$lib" ] && bundle_dylib "$lib"
  done
  # MoltenVK: this repository's patched arm64 build when it exists, else Homebrew's.
  if [ -f "$BUILD_DIR/moltenvk-out-finewine/libMoltenVK.dylib" ]; then
    # MVK_FLAVOR=finewine scripts/build-moltenvk.sh: adds ray queries (patches/moltenvk).
    cp "$BUILD_DIR/moltenvk-out-finewine/libMoltenVK.dylib" "$OUT/lib/libMoltenVK.dylib"
  elif [ -f "$BUILD_DIR/moltenvk-out-aarch64/libMoltenVK.dylib" ]; then
    echo "note: no build/moltenvk-out-finewine; using the CrossOver ARM MoltenVK, which has no ray tracing"
    cp "$BUILD_DIR/moltenvk-out-aarch64/libMoltenVK.dylib" "$OUT/lib/libMoltenVK.dylib"
  elif [ -f "$hb/lib/libMoltenVK.dylib" ]; then
    bundle_dylib "$hb/lib/libMoltenVK.dylib"
  fi

  # Wine asks for the Vulkan loader by name; on macOS MoltenVK provides the same entry points.
  [ -f "$OUT/lib/libMoltenVK.dylib" ] && ln -sf libMoltenVK.dylib "$OUT/lib/libvulkan.1.dylib"

  local wine_version id
  wine_version="$(sed 's/^Wine version //' "$SRC/VERSION")"
  id="finewine-$wine_version-$RUNTIME_VERSION"
  cat > "$OUT/runtime.json" <<JSON
{
  "id": "$id",
  "name": "FineWine $wine_version",
  "version": "$RUNTIME_VERSION",
  "wineVersion": "$wine_version",
  "architecture": "arm64",
  "graphics": {}
}
JSON
  # Wine opens freetype, gnutls, MoltenVK and the rest by bare name. dyld resolves a bare name
  # through the calling library's rpaths, so each Mac-side Wine library gets one pointing at
  # <runtime>/lib. The runtime then finds its libraries with no environment variable set.
  for so in "$OUT"/lib/wine/aarch64-unix/*.so; do
    otool -l "$so" | grep -A2 LC_RPATH | grep -q '@loader_path/../..' \
      || install_name_tool -add_rpath "@loader_path/../.." "$so" 2>/dev/null || true
  done

  strip_runtime

  # Mach-O files are signed ad hoc; arm64 macOS refuses to run unsigned code.
  find "$OUT/bin" "$OUT/lib" -type f \( -perm -u+x -o -name '*.so' -o -name '*.dylib' \) -print0 \
    | xargs -0 -n 50 codesign --force --sign - 2>/dev/null || true
  # The loader a second time, inside the app bundle that tells macOS it is a game (Game Mode);
  # FineWine runs programs that use Direct3D or Vulkan with it. Made after everything is
  # signed, so that the bundle is sealed with its final contents.
  "$REPO/scripts/lib/make-game-loader.sh" "$OUT/lib/wine/aarch64-unix" || die "could not make the game loader"
  # The stand-in for the Steam client that some games need to find before they start.
  "$REPO/scripts/lib/build-steam-helper.sh" "$OUT" || die "could not build the Steam helper"
  # Packaging starts from an empty folder, so the two add-ons built by their own scripts are
  # put back when their builds exist: FEX (x64 programs) and DXMT (Direct3D 10 and 11 on Metal).
  if [ -f "$BUILD_DIR/fex-arm64ec/Bin/libarm64ecfex.dll" ]; then
    "$REPO/scripts/build-fex.sh" install | tail -n 1
  else
    echo "note: no FEX build; x64 programs will not run (scripts/build-fex.sh all)"
  fi
  if [ -f "$BUILD_DIR/dxmt-install/aarch64-unix/winemetal.so" ]; then
    "$REPO/scripts/build-dxmt.sh" install | tail -n 1
  else
    echo "note: no DXMT build; Direct3D 10 and 11 will not work (scripts/build-dxmt.sh all)"
  fi
  echo "runtime: $OUT ($id, $(du -sh "$OUT" | cut -f1))"
}

case "${1:-}" in
  deps) cmd_deps ;;
  fetch) cmd_fetch ;;
  apply) cmd_apply ;;
  configure) cmd_configure ;;
  build) cmd_build ;;
  package) cmd_package ;;
  archive) cmd_archive ;;
  all) cmd_deps; cmd_fetch; cmd_apply; cmd_configure; cmd_build; cmd_package ;;
  *) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
