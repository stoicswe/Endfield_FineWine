#!/usr/bin/env bash
# build-finewine-deps.sh — the third-party libraries FineWine's runtime bundles, built for the
# runtime's oldest macOS.
#
# Wine opens FreeType (fonts) and GnuTLS (TLS, for anything that talks HTTPS through Windows'
# own APIs) at run time, and the runtime carries its own copies. Homebrew's copies are built for
# the macOS they are installed on, and macOS refuses to load a library built for a newer
# version than its own, so they cannot be shipped. These are built from the sources in
# CrossOver's source archive, except Nettle, which comes from GNU's release archive (CrossOver's
# copy lacks its Makefile.in). Both are pinned by version and checksum in finewine-sources.lock:
#
#   GMP · Nettle (with hogweed) · GnuTLS, without p11-kit, IDN or its tools · FreeType
#
# into build/finewine-deps, arm64, for macOS $MACOS_MIN, with install names under @rpath so
# that build-finewine-runtime.sh packages them in place of Homebrew's. SDL2 is not built:
# without it Wine reads game controllers through macOS's own IOHID support.
#
# Usage:  scripts/build-finewine-deps.sh            build what is missing
#         scripts/build-finewine-deps.sh clean      start again
# Needs:  Xcode's command line tools, cmake and ninja. About 10 minutes.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/scripts/lib/sources-lock.sh"; lock_load   # CROSSOVER_SOURCES_*, NETTLE_*
BUILD_DIR="${BUILD_DIR:-$REPO/build}"
MACOS_MIN="15.0"
export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"
PREFIX="$BUILD_DIR/finewine-deps"
SRC="$BUILD_DIR/finewine-deps-src"
ARCHIVE="$BUILD_DIR/crossover-sources-$CROSSOVER_SOURCES_VERSION.tar.gz"
URL="https://media.codeweavers.com/pub/crossover/source/crossover-sources-$CROSSOVER_SOURCES_VERSION.tar.gz"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
export CC="/usr/bin/clang -arch arm64" CXX="/usr/bin/clang++ -arch arm64"
export CFLAGS="-O2" LDFLAGS="-L$PREFIX/lib -Wl,-headerpad_max_install_names" CPPFLAGS="-I$PREFIX/include"
# Only what is built here; Homebrew's own .pc files must not be picked up instead.
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
NETTLE_ARCHIVE="$BUILD_DIR/nettle-download/nettle-$NETTLE_VERSION.tar.gz"
NETTLE_URL="https://ftp.gnu.org/gnu/nettle/nettle-$NETTLE_VERSION.tar.gz"
LOG="$BUILD_DIR/finewine-deps.log"

log(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

[ "${1:-}" = "clean" ] && { rm -rf "$PREFIX" "$SRC"; echo "removed $PREFIX and $SRC"; exit 0; }
mkdir -p "$BUILD_DIR"; : > "$LOG"

if [ ! -f "$ARCHIVE" ]; then
  log "Downloading CrossOver's source archive $CROSSOVER_SOURCES_VERSION"
  curl -fsSL -o "$ARCHIVE.part" "$URL" || die "download failed: $URL"
  mv "$ARCHIVE.part" "$ARCHIVE"
fi
got="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
[ "$got" = "$CROSSOVER_SOURCES_SHA256" ] || lock_fail "$ARCHIVE has checksum $got, but finewine-sources.lock pins $CROSSOVER_SOURCES_SHA256"

if [ ! -f "$NETTLE_ARCHIVE" ]; then
  log "Downloading Nettle $NETTLE_VERSION"
  mkdir -p "$(dirname "$NETTLE_ARCHIVE")"
  curl -fsSL -o "$NETTLE_ARCHIVE.part" "$NETTLE_URL" || die "download failed: $NETTLE_URL"
  mv "$NETTLE_ARCHIVE.part" "$NETTLE_ARCHIVE"
fi
got="$(shasum -a 256 "$NETTLE_ARCHIVE" | cut -d' ' -f1)"
[ "$got" = "$NETTLE_SHA256" ] || lock_fail "$NETTLE_ARCHIVE has checksum $got, but finewine-sources.lock pins $NETTLE_SHA256"

if [ ! -d "$SRC/sources/gnutls" ] || [ ! -d "$SRC/sources/freetype" ] || [ ! -d "$SRC/nettle-$NETTLE_VERSION" ]; then
  log "Unpacking GnuTLS, Nettle, GMP and FreeType"
  rm -rf "$SRC"; mkdir -p "$SRC"
  tar xzf "$ARCHIVE" -C "$SRC" sources/gnutls/gmp sources/gnutls/gnutls sources/freetype
  tar xzf "$NETTLE_ARCHIVE" -C "$SRC"
fi

run(){ local what="$1"; shift; echo "  $what"; "$@" >>"$LOG" 2>&1 || die "$what failed, see $LOG"; }

build_autotools(){   # <name> <source folder> <configure arguments...>
  local name="$1" dir="$2"; shift 2
  [ -f "$PREFIX/.built-$name" ] && { echo "$name: already built"; return; }
  log "$name"
  local obj="$SRC/build-$name"; rm -rf "$obj"; mkdir -p "$obj"
  ( cd "$obj" && run "configure" "$dir/configure" --prefix="$PREFIX" --enable-shared --disable-static "$@" \
      && run "build" make -j"$JOBS" && run "install" make install )
  touch "$PREFIX/.built-$name"
}

build_autotools gmp "$SRC/sources/gnutls/gmp" --host=aarch64-apple-darwin --build=aarch64-apple-darwin

build_autotools nettle "$SRC/nettle-$NETTLE_VERSION" --disable-documentation --disable-openssl \
  --with-include-path="$PREFIX/include" --with-lib-path="$PREFIX/lib"

# --disable-gost: GnuTLS 3.8.3 carries its own copy of Nettle's GOST code, which clashes with
# Nettle 3.10's ("redefinition of 'streebog512_ctx'"); Windows has no GOST ciphers to ask for.
# Nettle's flags given outright: GnuTLS's configure otherwise leaves libnettle off the link.
# One word each: configure tests them unquoted (`test x$NETTLE_LIBS != x`), and a value with a
# space quietly turns its Nettle backend off. The folder comes from LDFLAGS and CPPFLAGS.
export NETTLE_CFLAGS="-DFINEWINE_DEPS" NETTLE_LIBS="-lnettle"
export HOGWEED_CFLAGS="-DFINEWINE_DEPS" HOGWEED_LIBS="-lhogweed"
export GMP_CFLAGS="-DFINEWINE_DEPS" GMP_LIBS="-lgmp"
build_autotools gnutls "$SRC/sources/gnutls/gnutls" \
  --with-included-libtasn1 --with-included-unistring --without-p11-kit --without-idn --disable-gost \
  --without-brotli --without-zstd --without-tpm --without-tpm2 --without-zlib \
  --disable-doc --disable-manpages --disable-tools --disable-tests --disable-cxx --disable-nls \
  --disable-guile --disable-full-test-suite --disable-libdane --disable-openssl-compatibility

if [ ! -f "$PREFIX/.built-freetype" ]; then
  log "freetype"
  run "configure" cmake -S "$SRC/sources/freetype" -B "$SRC/build-freetype" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
    -DFT_DISABLE_PNG=ON -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_ZLIB=ON
  run "build" cmake --build "$SRC/build-freetype"
  run "install" cmake --install "$SRC/build-freetype"
  touch "$PREFIX/.built-freetype"
fi

# Install names: the library's usual name (libfreetype.6.dylib, libgnutls.30.dylib) in this
# folder, as an absolute path, and references between them likewise. Wine's build runs tools
# against them (sfnt2fon uses FreeType), which needs a path that works as it is; the runtime's
# packaging rewrites them for the runtime when it copies them.
log "Install names"
for lib in "$PREFIX"/lib/*.dylib; do
  [ -L "$lib" ] && continue
  id="$(basename "$(otool -D "$lib" | sed -n 2p)")"
  # Nettle names itself by its full version (libnettle.8.9.dylib), but what links to it asks for
  # the major one (libnettle.8.dylib); use the latter, so the runtime carries one copy.
  short="$(printf '%s' "$id" | sed -E 's/^(lib[^.]+\.[0-9]+)\.[0-9.]+\.dylib$/\1.dylib/')"
  [ -e "$PREFIX/lib/$short" ] && id="$short"
  install_name_tool -id "$PREFIX/lib/$id" "$lib" 2>/dev/null
  { otool -L "$lib" | awk 'NR>1{print $1}' | grep -E "^($PREFIX/|@rpath/)" || true; } | while IFS= read -r dep; do
    [ "$dep" = "$PREFIX/lib/$(basename "$dep")" ] || install_name_tool -change "$dep" "$PREFIX/lib/$(basename "$dep")" "$lib"
  done
  codesign --force --sign - "$lib" 2>/dev/null
done
"$REPO/scripts/lib/check-macos-compat.sh" "$MACOS_MIN" "$PREFIX/lib"
ls "$PREFIX"/lib/libgnutls.30.dylib "$PREFIX"/lib/libfreetype.6.dylib >/dev/null || die "the build is missing a library"
echo "built: $PREFIX"
