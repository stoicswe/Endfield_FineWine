#!/usr/bin/env bash
# build-steam-bridge.sh — build the bridge between a Windows game and the Mac's Steam client
# for FineWine's runtime: lsteamclient (Valve's, from Proton) and the steam.exe helper.
#
# With it, and the loader change in patches/runtime/0042, a game started from the Mac Steam
# client through FineWine's Steam tool can use Steam: sign-in, ownership, achievements.
#
# The sources are in runtime-extras/steam-bridge (see its README for where each came from and
# its licence). Valve's own lsteamclient tree is downloaded at the commit finewine-sources.lock
# names and those files are copied over it. Both parts are built inside the runtime's Wine tree,
# so scripts/build-finewine-runtime.sh must have been run up to `build` first.
#
#   scripts/build-steam-bridge.sh fetch     download Valve's sources and assemble the trees
#   scripts/build-steam-bridge.sh place     put them in the Wine tree and register them
#   scripts/build-steam-bridge.sh build     build lsteamclient.dll, lsteamclient.so, steam.exe
#   scripts/build-steam-bridge.sh install   copy them into build/finewine-runtime/lib/steam-bridge
#   scripts/build-steam-bridge.sh all       everything above, in order
#
# Env: BUILD_DIR (default ./build), JOBS, FINEWINE_UNLOCKED (see finewine-sources.lock)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/scripts/lib/sources-lock.sh"; lock_load
MACOS_MIN="15.0"
export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"
BUILD_DIR="${BUILD_DIR:-$REPO/build}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
SRC="$BUILD_DIR/finewine-runtime-src"
OBJ="$BUILD_DIR/finewine-runtime-build"
OUT="$BUILD_DIR/finewine-runtime"
HERE="$REPO/runtime-extras/steam-bridge"
WORK="$BUILD_DIR/steam-bridge"
TREE="$WORK/lsteamclient"          # Valve's tree with ours over it
HEADERS="$WORK/proton-headers"     # what steam.exe is compiled against
BREW="$(command -v brew || echo /opt/homebrew/bin/brew)"

log(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
toolchain(){
  export PATH="$("$BREW" --prefix bison)/bin:$("$BREW" --prefix llvm)/bin:$("$BREW" --prefix lld)/bin:$PATH"
}
sha(){ shasum -a 256 "$1" | cut -d' ' -f1; }

# One file from a Valve repository at a commit, checked against the lock file.
fetch_header(){
  local project="$1" commit="$2" path="$3" dest="$4" want="$5"
  local cached="$WORK/cache/$project-$commit-$(echo "$path" | tr '/' '_')"
  mkdir -p "$WORK/cache" "$(dirname "$dest")"
  if [ ! -f "$cached" ]; then
    echo "fetching $project/$path at ${commit:0:12}"
    curl -fsSL -o "$cached.part" "https://raw.githubusercontent.com/ValveSoftware/$project/$commit/$path"
    mv "$cached.part" "$cached"
  fi
  local got; got="$(sha "$cached")"
  if [ "$got" != "$want" ]; then rm -f "$cached"; lock_fail "$project/$path is $got, but finewine-sources.lock pins $want"; fi
  cp -f "$cached" "$dest"
}

cmd_fetch(){
  log "Fetching Valve's lsteamclient (Proton ${STEAM_BRIDGE_PROTON_COMMIT:0:12})"
  local tarball="$WORK/cache/proton-$STEAM_BRIDGE_PROTON_COMMIT.tar.gz" base="$WORK/cache/lsteamclient-$STEAM_BRIDGE_PROTON_COMMIT"
  mkdir -p "$WORK/cache"
  if [ ! -d "$base" ]; then
    if [ ! -f "$tarball" ]; then
      curl -fsSL -o "$tarball.part" "https://codeload.github.com/ValveSoftware/Proton/tar.gz/$STEAM_BRIDGE_PROTON_COMMIT"
      mv "$tarball.part" "$tarball"
    fi
    rm -rf "$base.part"; mkdir -p "$base.part"
    tar xzf "$tarball" -C "$base.part" --strip-components=2 "*/lsteamclient/"
    mv "$base.part" "$base"
  fi
  local got
  got="$(cd "$base" && python3 -c '
import hashlib, pathlib
root = pathlib.Path(".")
h = hashlib.sha256()
for p in sorted(q for q in root.rglob("*") if q.is_file()):
    h.update(hashlib.sha256(str(p.relative_to(root)).encode()).digest())
    h.update(hashlib.sha256(p.read_bytes()).digest())
print(h.hexdigest())')"
  lock_check "Valve's lsteamclient" "$got" "$STEAM_BRIDGE_LSTEAMCLIENT_DIGEST"

  # Rebuilt every time, so a file removed here does not linger.
  rm -rf "$TREE"; mkdir -p "$WORK"
  cp -c -R "$base" "$TREE" 2>/dev/null || cp -R "$base" "$TREE"
  local f
  for f in steamclient_main.c unix_steam_input_manual.cpp unixlib.cpp; do
    [ -f "$TREE/$f" ] || die "$f is not in Valve's tree, so it cannot replace anything"
    cp -f "$HERE/lsteamclient/$f" "$TREE/$f"
  done
  mkdir "$TREE/steamworks_sdk_165x"
  for f in steamtypes.h steamclientpublic.h steamnetworkingtypes.h steamuniverse.h; do
    cp "$TREE/steamworks_sdk_165/$f" "$TREE/steamworks_sdk_165x/"
  done
  cp "$HERE/lsteamclient/steamworks_sdk_165x/isteamnetworkingsocketsserialized.h" "$TREE/steamworks_sdk_165x/"
  patch -p1 -d "$TREE" --forward -s < "$HERE/lsteamclient/serialized005.patch"
  # 32-bit games: the 32-bit pointer type of the Mac half adds the base of the program's
  # memory window (Wine runtime patch 0043).
  patch -p1 -d "$TREE" --forward -s < "$HERE/lsteamclient/window32.patch"
  # The Mac half is C++ and Valve's makefile names no C++ library (on Linux the compiler
  # driver adds it). Without this, Wine's own `make` stops at linking lsteamclient.so.
  grep -q '^UNIX_LIBS' "$TREE/Makefile.in" && die "Valve's Makefile.in has UNIX_LIBS now: look at it again"
  sed -i '' 's|^UNIXLIB   = lsteamclient.so$|UNIXLIB   = lsteamclient.so\nUNIX_LIBS = -lc++|' "$TREE/Makefile.in"
  grep -q '^UNIX_LIBS = -lc++$' "$TREE/Makefile.in" || die "could not add the C++ library to lsteamclient's Makefile.in"
  echo "assembled $TREE ($(find "$TREE" -type f | wc -l | tr -d ' ') files)"

  log "Fetching the headers the steam.exe helper needs"
  rm -rf "$HEADERS"
  fetch_header openvr "$STEAM_BRIDGE_OPENVR_COMMIT" headers/openvr.h "$HEADERS/openvr/headers/openvr.h" "$STEAM_BRIDGE_OPENVR_H_SHA256"
  fetch_header openvr "$STEAM_BRIDGE_OPENVR_COMMIT" src/ivrclientcore.h "$HEADERS/openvr/src/ivrclientcore.h" "$STEAM_BRIDGE_IVRCLIENTCORE_H_SHA256"
  fetch_header wine "$STEAM_BRIDGE_VALVE_WINE_COMMIT" include/wine/heap.h "$HEADERS/wine/include/wine/heap.h" "$STEAM_BRIDGE_WINE_HEAP_H_SHA256"
  cp -R "$TREE/steamworks_sdk_142" "$HEADERS/steamworks_sdk_142"
  echo "assembled $HEADERS"
}

# Wine's configure lists every module it builds. These two are added to the script and to its
# source by name, next to their neighbours in the alphabet, so the edit does not depend on line
# numbers; a tree that already has them is left alone.
register(){
  python3 - "$SRC" <<'PY'
import re, sys, pathlib
src = pathlib.Path(sys.argv[1])
def insert_after(text, anchor, line, what):
    if line in text: return text
    if anchor not in text: sys.exit(f"cannot register {what}: no line '{anchor.strip()}'")
    return text.replace(anchor, anchor + line, 1)
ac = (src / "configure.ac").read_text()
ac = insert_after(ac, "WINE_CONFIG_MAKEFILE(dlls/localui/tests)\n", "WINE_CONFIG_MAKEFILE(dlls/lsteamclient)\n", "lsteamclient")
ac = insert_after(ac, "WINE_CONFIG_MAKEFILE(programs/start)\n", "WINE_CONFIG_MAKEFILE(programs/steam.exe)\nWINE_EXTERNAL(programs/steam.exe)\n", "steam.exe")
(src / "configure.ac").write_text(ac)
c = (src / "configure").read_text()
c = insert_after(c, "\nenable_localui\n", "enable_lsteamclient\n", "lsteamclient")
c = insert_after(c, "\nenable_start\n", "enable_steam_exe\n", "steam.exe")
c = insert_after(c, "wine_fn_config_makefile dlls/localui/tests enable_tests\n", "wine_fn_config_makefile dlls/lsteamclient enable_lsteamclient\n", "lsteamclient")
c = insert_after(c, "wine_fn_config_makefile programs/start enable_start\n", "wine_fn_config_makefile programs/steam.exe enable_steam_exe\n", "steam.exe")
if "programs/steam.exe libs/compiler-rt" not in c:
    new, n = re.subn(r'(\nEXTERNAL_SUBDIRS="[^"\n]*) libs/compiler-rt"', r'\1 programs/steam.exe libs/compiler-rt"', c, count=1)
    if not n: sys.exit("cannot register steam.exe: no EXTERNAL_SUBDIRS line")
    c = new
(src / "configure").write_text(c)
PY
}

cmd_place(){
  log "Placing the sources in the Wine tree"
  [ -d "$SRC/dlls/ntdll" ] || die "no Wine source at $SRC: run scripts/build-finewine-runtime.sh fetch and apply first"
  [ -d "$TREE" ] && [ -d "$HEADERS" ] || die "run 'fetch' first"
  mkdir -p "$SRC/dlls/lsteamclient" "$SRC/programs/steam.exe"
  # Unchanged files keep their time, so they are not compiled again.
  rsync -a --delete "$TREE/" "$SRC/dlls/lsteamclient/"
  rsync -a --delete --exclude LICENSE --exclude proton-headers "$HERE/steam-helper/" "$SRC/programs/steam.exe/"
  rsync -a --delete "$HEADERS/" "$SRC/programs/steam.exe/proton-headers/"
  register
  if [ ! -f "$OBJ/Makefile" ]; then
    echo "registered; Wine's configure will pick the two modules up"
  elif grep -q '^dlls/lsteamclient/lsteamclient.so:' "$OBJ/Makefile" \
       && grep -q -- '-lc++' <(sed -n '/^dlls\/lsteamclient\/lsteamclient.so:/,/^$/p' "$OBJ/Makefile"); then
    echo "already in Wine's build"
  else
    toolchain
    echo "running Wine's configure again for the two modules"
    ( cd "$OBJ" && ./config.status --recheck >/dev/null && ./config.status >/dev/null )
  fi
}

# The loader for a PE file: its machine (8664 = runs as an x64 program) and whether Wine made it.
pe_info(){
  python3 - "$1" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
pe = struct.unpack_from("<I", d, 0x3c)[0]
print("%04x %s" % (struct.unpack_from("<H", d, pe + 4)[0], "builtin" if d[0x40:0x50] == b"Wine builtin DLL" else "native"))
PY
}

cmd_build(){
  log "Building the bridge"
  toolchain
  cd "$OBJ"
  [ -f dlls/ntdll/ntdll.so ] || die "the runtime's Wine is not built"
  local dll=dlls/lsteamclient

  echo "lsteamclient.dll (Windows half, for ARM64 and x64 programs)"
  make -j"$JOBS" "$dll/aarch64-windows/lsteamclient.dll" >"$BUILD_DIR/steam-bridge-pe.log" 2>&1 \
    || die "lsteamclient.dll failed: see $BUILD_DIR/steam-bridge-pe.log"

  # The same for 32-bit games, when Wine is built with a 32-bit side. It calls the same Mac half.
  if grep -q '^i386_CC = ' Makefile; then
    echo "lsteamclient.dll (Windows half, for 32-bit programs)"
    make -j"$JOBS" "$dll/i386-windows/lsteamclient.dll" >"$BUILD_DIR/steam-bridge-pe32.log" 2>&1 \
      || die "the 32-bit lsteamclient.dll failed: see $BUILD_DIR/steam-bridge-pe32.log"
  fi
  echo "lsteamclient.so (Mac half)"
  make -j"$JOBS" "$dll/lsteamclient.so" >"$BUILD_DIR/steam-bridge-unix.log" 2>&1 \
    || die "lsteamclient's Mac half failed: see $BUILD_DIR/steam-bridge-unix.log"
  [ "$(lipo -archs "$dll/lsteamclient.so")" = arm64 ] || die "lsteamclient.so is not arm64"
  [ "$(stat -f %z "$dll/lsteamclient.so")" -gt 1000000 ] || die "lsteamclient.so is too small: the link dropped its objects"
  otool -l "$dll/lsteamclient.so" | grep -A3 LC_BUILD_VERSION | grep -q "minos $MACOS_MIN" \
    || die "lsteamclient.so was not built for macOS $MACOS_MIN"

  # steam.exe has to run as an x64 program: it loads Steam's x64 client library itself, and a
  # native ARM64 program cannot. Wine's makefile only builds programs as ARM64, so this one is
  # compiled and linked here as ARM64EC, which Windows (and Wine) run as x64.
  echo "steam.exe (helper, as an x64 program)"
  local prog=programs/steam.exe out=programs/steam.exe/arm64ec-windows A=aarch64-windows f
  mkdir -p "$out"
  for f in jsoncpp steam; do
    clang -std=gnu++17 -c -o "$out/$f.o" "$SRC/$prog/$f.cpp" -I"$prog" -I"$SRC/$prog" -Iinclude -I"$SRC/include" \
      -I"$SRC/include/msvcrt" -I"$SRC/$prog/proton-headers/steamworks_sdk_142" \
      -I"$SRC/$prog/proton-headers/openvr/headers" -I"$SRC/$prog/proton-headers/wine/include" \
      -D_UCRT -DWINE_NO_LONG_TYPES -D__WINESRC__ -DPATH_MAX=4096 -include posix_compat.h -D__WINE_PE_BUILD \
      -target arm64ec-windows -fuse-ld=lld --no-default-config -fno-strict-aliasing \
      -Wno-microsoft-enum-forward-reference -ffunction-sections -ffp-exception-behavior=maytrap \
      -gdwarf-4 -g -O2 -march=armv8.4-a -w
  done
  # The import libraries in aarch64-windows hold both kinds of code.
  make -j"$JOBS" "libs/c++/$A/libc++.a" "dlls/msi/$A/libmsi.a" "dlls/shell32/$A/libshell32.a" >/dev/null 2>&1 || true
  tools/winegcc/winegcc -o "$out/steam.exe" --wine-objdir . --cc-cmd="clang" -b arm64ec-windows -Wl,--wine-builtin \
    -mwindows -mcygwin -static-libgcc "$out/jsoncpp.o" "$out/steam.o" \
    "libs/c++/$A/libc++.a" "libs/c++/$A/libc++.a" "dlls/msvcp140/$A/libmsvcp140.a" "dlls/vcruntime140/$A/libvcruntime140.a" \
    "dlls/user32/$A/libuser32.a" "dlls/advapi32/$A/libadvapi32.a" "dlls/shlwapi/$A/libshlwapi.a" \
    "dlls/shell32/$A/libshell32.a" "dlls/msi/$A/libmsi.a" "libs/winecrt0/$A/libwinecrt0.a" \
    "libs/compiler-rt/$A/libcompiler-rt.a" "dlls/ucrtbase/$A/libucrtbase.a" "dlls/kernel32/$A/libkernel32.a" \
    "dlls/ntdll/$A/libntdll.a" --no-default-config -Wl,-debug:dwarf -Wl,--build-id
  [ "$(pe_info "$out/steam.exe")" = "8664 builtin" ] || die "steam.exe is '$(pe_info "$out/steam.exe")', not an x64 Wine program"

  # Steam's own overlay library is loaded into the game by lsteamclient, long after the game
  # started; this shim starts the overlay's Metal hooks then and keeps keys and clicks from
  # the game while the overlay is open.
  echo "overlay-shim.dylib (the Steam overlay's helper)"
  mkdir -p "$WORK/out"
  /usr/bin/clang -arch arm64 -mmacosx-version-min="$MACOS_MIN" -Werror=unguarded-availability-new -dynamiclib -O2 \
    -install_name @rpath/overlay-shim.dylib -framework Metal -framework QuartzCore -framework CoreGraphics \
    -framework CoreFoundation -framework Foundation -w \
    -o "$WORK/out/overlay-shim.dylib" "$HERE/overlay-shim/overlay_shim.m"
  codesign --force --sign - "$WORK/out/overlay-shim.dylib" 2>/dev/null
  case "$(pe_info "$dll/$A/lsteamclient.dll")" in *builtin) ;; *) die "lsteamclient.dll is not a Wine module" ;; esac
  ls -l "$dll/$A/lsteamclient.dll" "$dll/lsteamclient.so" "$out/steam.exe"
}

# Into the runtime, in a folder of their own: nothing here is loaded unless FineWine's Steam
# tool asks for it.
#   lib/steam-bridge/wine    goes on WINEDLLPATH: lsteamclient.dll with its Mac half beside it
#   lib/steam-bridge/overlay-shim.dylib   named to lsteamclient, which loads it with Steam's overlay
#   lib/steam-bridge/steam   copied into a prefix's Steam folder: lsteamclient.dll (a file must
#                            be there for Wine to load it outside prefix setup) and steam.exe
# Valve's own Windows client files (steamclient64.dll and its two libraries) are not part of
# this: they are Valve's, and are fetched from Valve on the user's Mac.
cmd_install(){
  log "Installing into $OUT/lib/steam-bridge"
  [ -d "$OUT/lib/wine" ] || die "no packaged runtime at $OUT: run scripts/build-finewine-runtime.sh package first"
  local dest="$OUT/lib/steam-bridge" strip="$("$BREW" --prefix llvm)/bin/llvm-strip"
  # Wine's `make install` puts the two modules among its own. They must not stay there: a
  # steam.exe among Wine's programs is the ARM64 one, and Wine would run it in place of the
  # x64 helper in the prefix.
  # The 32-bit copies Wine's build also makes go too: the bridge is for 64-bit programs, and
  # the 32-bit steam.exe is an empty program (see steam-helper/steam.cpp).
  rm -f "$OUT/lib/wine/aarch64-windows/steam.exe" "$OUT/lib/wine/aarch64-windows/lsteamclient.dll" \
        "$OUT/lib/wine/aarch64-unix/lsteamclient.so" \
        "$OUT/lib/wine/i386-windows/steam.exe" "$OUT/lib/wine/i386-windows/lsteamclient.dll"
  rm -rf "$dest"; mkdir -p "$dest/wine" "$dest/steam"
  cp "$OBJ/dlls/lsteamclient/aarch64-windows/lsteamclient.dll" "$dest/wine/lsteamclient.dll"
  cp "$OBJ/dlls/lsteamclient/lsteamclient.so" "$dest/wine/lsteamclient.so"
  # For 32-bit games, in the folder Wine looks in for a 32-bit program's libraries.
  if [ -f "$OBJ/dlls/lsteamclient/i386-windows/lsteamclient.dll" ]; then
    mkdir -p "$dest/wine/i386-windows"
    cp "$OBJ/dlls/lsteamclient/i386-windows/lsteamclient.dll" "$dest/wine/i386-windows/lsteamclient.dll"
    "$strip" --strip-debug "$dest/wine/i386-windows/lsteamclient.dll"
    # Wine looks for the Mac half of a library it found in <folder>/i386-windows in
    # <folder>/aarch64-unix. It is the one library, so that is a link to it.
    mkdir -p "$dest/wine/aarch64-unix"
    ln -sf ../lsteamclient.so "$dest/wine/aarch64-unix/lsteamclient.so"
  fi
  cp "$OBJ/programs/steam.exe/arm64ec-windows/steam.exe" "$dest/steam/steam.exe"
  # Released runtimes carry no debug information (see build-finewine-runtime.sh).
  "$strip" --strip-debug "$dest/wine/lsteamclient.dll" "$dest/steam/steam.exe"
  /usr/bin/strip -S -x "$dest/wine/lsteamclient.so" 2>/dev/null
  codesign --force --sign - "$dest/wine/lsteamclient.so" 2>/dev/null
  cp "$dest/wine/lsteamclient.dll" "$dest/steam/lsteamclient.dll"
  cp "$WORK/out/overlay-shim.dylib" "$dest/overlay-shim.dylib"
  cp "$HERE/lsteamclient/LICENSE" "$dest/LICENSE.lsteamclient"
  cp "$HERE/steam-helper/LICENSE" "$dest/LICENSE.steam-helper"
  [ "$(pe_info "$dest/steam/steam.exe")" = "8664 builtin" ] || die "stripping broke steam.exe"
  du -sh "$dest"; ls -l "$dest/wine" "$dest/steam"
}

case "${1:-all}" in
  fetch) cmd_fetch ;;
  place) cmd_place ;;
  build) cmd_build ;;
  install) cmd_install ;;
  all) cmd_fetch; cmd_place; cmd_build; cmd_install ;;
  *) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
