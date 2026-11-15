#!/usr/bin/env bash
# build-fex.sh — build FEX, the x64 emulator, for FineWine's Wine runtime on Apple Silicon.
#
# FEX translates x86-64 Windows code to ARM64 inside an ARM64 Wine process. Its ARM64EC build is
# one DLL, libarm64ecfex.dll, which Wine loads under the name xtajit64.dll whenever an x64
# program starts. This script builds that DLL on a Mac and puts it in the runtime.
#
#   source     FEX at the pinned commit (FEX_COMMIT), with patches/fex applied
#   compiler   llvm-mingw (clang for Windows targets), downloaded once into build/llvm-mingw and
#              checked against a pinned SHA-256. Its winnt.h is changed so NtCurrentTeb() reads
#              the TEB from thread-specific data instead of x18 (see patches/fex/0001).
#   output     build/fex-arm64ec/Bin/libarm64ecfex.dll, and, with `install`, a copy in
#              build/finewine-runtime/lib/wine/aarch64-windows/xtajit64.dll
#
# Usage:
#   scripts/build-fex.sh toolchain   # download and prepare llvm-mingw
#   scripts/build-fex.sh fetch       # clone FEX and its submodules
#   scripts/build-fex.sh apply       # apply patches/fex
#   scripts/build-fex.sh build       # configure and build
#   scripts/build-fex.sh install     # copy the DLL into the runtime as xtajit64.dll
#   scripts/build-fex.sh all         # everything above
#
# Env: BUILD_DIR (default ./build), FEX_COMMIT, RUNTIME_DIR (default build/finewine-runtime).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$REPO/build}"
FEX_COMMIT="${FEX_COMMIT:-ea43314f040633c76fb5891ff31d8a7c3dc533b8}"
RUNTIME_DIR="${RUNTIME_DIR:-$BUILD_DIR/finewine-runtime}"
SRC="$BUILD_DIR/fex-src"
OBJ="$BUILD_DIR/fex-arm64ec"
MINGW="$BUILD_DIR/llvm-mingw"
MINGW_VERSION="20260908"
MINGW_ARCHIVE="llvm-mingw-$MINGW_VERSION-ucrt-macos-universal.tar.xz"
MINGW_URL="https://github.com/mstorsjo/llvm-mingw/releases/download/$MINGW_VERSION/$MINGW_ARCHIVE"
MINGW_SHA256="d1dc5d1ecf3a3ced5ed5544c72f1acd0c8e84eb3024d520ecc6b143eec62a149"

log(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

# Makes NtCurrentTeb() in the toolchain's headers read the TEB from thread-specific data slot 6
# instead of x18. Does nothing if it has already been done.
patch_toolchain_header(){
  python3 - "$MINGW/generic-w64-mingw32/include/winnt.h" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
marker = "FineWine (macOS): x18 does not survive"
old = '''    register struct _TEB *__mingw_current_teb __asm__("x18");
    FORCEINLINE struct _TEB *NtCurrentTeb(VOID)
    {
        return __mingw_current_teb;
    }'''
new = '''    /* FineWine (macOS): x18 does not survive a trip through the kernel on macOS, so the TEB
     * is read from thread-specific data slot 6, where Wine's Unix side stores it. */
    FORCEINLINE struct _TEB *NtCurrentTeb(VOID)
    {
        unsigned __int64 __finewine_tsd;
        __asm__("mrs %0, tpidrro_el0" : "=r" (__finewine_tsd));
        return ((struct _TEB **)(__finewine_tsd & ~(unsigned __int64)7))[6];
    }'''
if marker in text:
    print("toolchain header: already patched")
elif text.count(old) == 1:
    open(path, "w").write(text.replace(old, new))
    print("toolchain header: NtCurrentTeb() now reads the TEB from thread-specific data")
else:
    sys.exit("toolchain header: the x18 definition of NtCurrentTeb() was not found; "
             "this llvm-mingw version needs the patch updating")
PY
}

cmd_toolchain(){
  log "Preparing llvm-mingw $MINGW_VERSION"
  if [ ! -x "$MINGW/bin/arm64ec-w64-mingw32-clang" ]; then
    mkdir -p "$BUILD_DIR"
    local tmp; tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/$MINGW_ARCHIVE" "$MINGW_URL" || die "download failed: $MINGW_URL"
    local got; got="$(shasum -a 256 "$tmp/$MINGW_ARCHIVE" | cut -d' ' -f1)"
    [ "$got" = "$MINGW_SHA256" ] || { rm -rf "$tmp"; die "checksum mismatch for $MINGW_ARCHIVE (got $got)"; }
    tar -xJf "$tmp/$MINGW_ARCHIVE" -C "$tmp"
    rm -rf "$MINGW"; mv "$tmp/${MINGW_ARCHIVE%.tar.xz}" "$MINGW"; rm -rf "$tmp"
  fi
  patch_toolchain_header
  "$MINGW/bin/arm64ec-w64-mingw32-clang" --version | head -n 1
}

cmd_fetch(){
  log "Fetching FEX ($FEX_COMMIT)"
  rm -rf "$SRC"; git init -q "$SRC"
  git -C "$SRC" fetch -q --depth 1 https://github.com/FEX-Emu/FEX.git "$FEX_COMMIT"
  git -C "$SRC" checkout -q FETCH_HEAD
  git -C "$SRC" submodule update --init --depth 1 >/dev/null
  echo "source: $SRC"
}

cmd_apply(){
  log "Applying patches/fex"
  [ -d "$SRC" ] || die "run 'fetch' first"
  local f n=0
  for f in "$REPO"/patches/fex/*.patch; do
    git -C "$SRC" apply "$f" || die "patch failed: $f"
    n=$((n+1))
  done
  echo "applied $n patches"
}

cmd_build(){
  log "Building FEX for Windows ARM64EC"
  [ -d "$SRC" ] || die "run 'fetch' first"
  [ -x "$MINGW/bin/arm64ec-w64-mingw32-clang" ] || die "run 'toolchain' first"
  # FEX's build scripts import pkg_resources only to compare versions; newer Pythons lack it.
  local shim="$BUILD_DIR/fex-pyshim"
  mkdir -p "$shim"; cp "$REPO/scripts/lib/fex-pkg_resources.py" "$shim/pkg_resources.py"
  export PYTHONPATH="$shim" PATH="$MINGW/bin:$PATH"
  # TUNE_CPU=none: the default asks the build machine's /proc/cpuinfo, which a Mac doesn't have.
  cmake -B "$OBJ" -S "$SRC" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$SRC/Data/CMake/toolchain_mingw.cmake" -DMINGW_TRIPLE=arm64ec-w64-mingw32 \
    -DBUILD_TESTING=False -DBUILD_TESTS=False -DENABLE_LTO=False -DENABLE_JEMALLOC_GLIBC_ALLOC=False \
    -DENABLE_ASSERTIONS=False -DTUNE_CPU=none -DTUNE_ARCH=armv8.5-a \
    > "$BUILD_DIR/fex-configure.log" 2>&1 || die "configure failed, see $BUILD_DIR/fex-configure.log"
  cmake --build "$OBJ" > "$BUILD_DIR/fex-build.log" 2>&1 || die "build failed, see $BUILD_DIR/fex-build.log"
  [ -f "$OBJ/Bin/libarm64ecfex.dll" ] || die "the build produced no libarm64ecfex.dll"
  # Anything still using x18 would read a zeroed register at run time. The two known uses are
  # in the toolchain's prebuilt C++ exception support, which FEX does not reach.
  local left
  left="$(llvm-objdump -d "$OBJ/Bin/libarm64ecfex.dll" | grep -E '\bx18\b' | grep -vc '%' || true)"
  echo "built: $OBJ/Bin/libarm64ecfex.dll (x18 instructions left: $left)"
  [ "$left" -le 2 ] || die "$left instructions still use x18; expected at most 2 (see the note above)"
}

cmd_install(){
  log "Installing FEX into the runtime"
  local dir="$RUNTIME_DIR/lib/wine/aarch64-windows"
  [ -d "$dir" ] || die "no runtime at $RUNTIME_DIR (run scripts/build-finewine-runtime.sh all)"
  [ -f "$OBJ/Bin/libarm64ecfex.dll" ] || die "run 'build' first"
  # Keep Wine's own placeholder emulator once, so the change can be undone.
  [ -f "$dir/xtajit64.dll.winestub" ] || cp "$dir/xtajit64.dll" "$dir/xtajit64.dll.winestub"
  cp "$OBJ/Bin/libarm64ecfex.dll" "$dir/xtajit64.dll"
  echo "installed: $dir/xtajit64.dll"
}

case "${1:-}" in
  toolchain) cmd_toolchain ;;
  fetch) cmd_fetch ;;
  apply) cmd_apply ;;
  build) cmd_build ;;
  install) cmd_install ;;
  all) cmd_toolchain; cmd_fetch; cmd_apply; cmd_build; cmd_install ;;
  *) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
