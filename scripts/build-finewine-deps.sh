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
#   SDL2 (controllers only) · GLib · GStreamer (playback through macOS's own decoders)
#
# into build/finewine-deps, arm64, for macOS $MACOS_MIN, with install names under @rpath so
# that build-finewine-runtime.sh packages them in place of Homebrew's. SDL2 (controllers only)
# is downloaded from libsdl.org and built the same way.
#
# Usage:  scripts/build-finewine-deps.sh            build what is missing
#         scripts/build-finewine-deps.sh clean      start again
# Needs:  Xcode's command line tools, cmake, ninja and meson. About 25 minutes.
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

# SDL2, for game controllers. Wine's winebus reads controllers through it when it is there and
# presents each one to Windows programs in one standard layout, so that a PlayStation or a
# Switch controller works where a program only knows the Xbox one (as on Proton). Only the
# controller parts are built: no video, audio or rendering, which Wine has its own of.
SDL2_ARCHIVE="$BUILD_DIR/sdl2-download/SDL2-$SDL2_VERSION.tar.gz"
SDL2_URL="https://www.libsdl.org/release/SDL2-$SDL2_VERSION.tar.gz"
if [ ! -f "$PREFIX/.built-sdl2" ]; then
  log "SDL2 $SDL2_VERSION"
  if [ ! -f "$SDL2_ARCHIVE" ]; then
    mkdir -p "$(dirname "$SDL2_ARCHIVE")"
    curl -fsSL -o "$SDL2_ARCHIVE.part" "$SDL2_URL" || die "download failed: $SDL2_URL"
    mv "$SDL2_ARCHIVE.part" "$SDL2_ARCHIVE"
  fi
  got="$(shasum -a 256 "$SDL2_ARCHIVE" | cut -d' ' -f1)"
  [ "$got" = "$SDL2_SHA256" ] || lock_fail "$SDL2_ARCHIVE has checksum $got, but finewine-sources.lock pins $SDL2_SHA256"
  rm -rf "$SRC/SDL2-$SDL2_VERSION" "$SRC/build-sdl2"
  tar xzf "$SDL2_ARCHIVE" -C "$SRC"
  run "configure" cmake -S "$SRC/SDL2-$SDL2_VERSION" -B "$SRC/build-sdl2" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_NAME_DIR=@rpath \
      -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF -DSDL_VIDEO=OFF -DSDL_RENDER=OFF -DSDL_AUDIO=OFF \
      -DSDL_CAMERA=OFF -DSDL_POWER=OFF -DSDL_FILESYSTEM=OFF -DSDL_LOCALE=OFF -DSDL_MISC=OFF \
      -DSDL_JOYSTICK=ON -DSDL_HAPTIC=ON -DSDL_HIDAPI=ON -DSDL_SENSOR=ON
  run "build" cmake --build "$SRC/build-sdl2"
  run "install" cmake --install "$SRC/build-sdl2"
  touch "$PREFIX/.built-sdl2"
fi

# GLib and GStreamer, for video and audio in games (Wine's winegstreamer), from CrossOver's
# source archive. GStreamer is built without FFmpeg: decoding is done by macOS itself through
# the applemedia plugin (VideoToolbox, AudioToolbox), so what plays is what a Mac plays: H.264,
# HEVC, AAC, MP3 and the like, in MP4, Matroska, AVI, MPEG and WAV files. Only the plugins that
# playback needs are built.
#
# Three small things are not in the archive and are fetched by meson as GLib's own build files
# name them, each pinned there by checksum or commit: PCRE2 10.42 (github.com/PhilipHazel),
# proxy-libintl 0.4 (github.com/frida) and gvdb (gitlab.gnome.org/GNOME).
#
# GLib 2.78's code generator imports a Python module newer Pythons no longer have; a stand-in
# for the one class it uses is in scripts/lib/glib-pyshim.
MESON="$(command -v meson || true)"
GST="$SRC/sources/gstreamer/subprojects"
build_meson(){   # <name> <source folder> <meson options...>
  local name="$1" dir="$2"; shift 2
  [ -f "$PREFIX/.built-$name" ] && { echo "$name: already built"; return; }
  log "$name"
  rm -rf "$SRC/build-$name"
  run "configure" "$MESON" setup "$SRC/build-$name" "$dir" --prefix="$PREFIX" --libdir=lib --buildtype=release \
      -Ddefault_library=shared "$@"
  run "build" "$MESON" compile -C "$SRC/build-$name"
  run "install" "$MESON" install -C "$SRC/build-$name"
  touch "$PREFIX/.built-$name"
}
if [ ! -f "$PREFIX/.built-gst-plugins-bad" ]; then
  [ -n "$MESON" ] || die "meson is needed for GLib and GStreamer (brew install meson)"
  if [ ! -d "$SRC/sources/glib" ] || [ ! -d "$GST/gstreamer" ]; then
    log "Unpacking GLib and GStreamer"
    tar xzf "$ARCHIVE" -C "$SRC" sources/glib sources/gstreamer
    # An empty folder where a subproject belongs stops meson fetching it.
    rmdir "$SRC/sources/glib/subprojects/gvdb" 2>/dev/null || true
  fi
  (
    export PYTHONPATH="$REPO/scripts/lib/glib-pyshim" PATH="$PREFIX/bin:$PATH"
    export OBJC="/usr/bin/clang -arch arm64" OBJCXX="/usr/bin/clang++ -arch arm64"
    build_meson glib "$SRC/sources/glib" -Dtests=false -Dnls=disabled -Dman=false -Dgtk_doc=false -Ddtrace=false \
        -Dsystemtap=false -Dglib_debug=disabled -Dselinux=disabled -Dxattr=false -Dlibmount=disabled -Dlibelf=disabled \
        -Dsysprof=disabled -Dbsymbolic_functions=false
    common=(--wrap-mode=nodownload -Dauto_features=disabled -Dtests=disabled -Dexamples=disabled -Dnls=disabled -Ddoc=disabled)
    build_meson gstreamer "$GST/gstreamer" "${common[@]}" -Dintrospection=disabled -Dcoretracers=disabled -Dcheck=disabled \
        -Dbenchmarks=disabled -Dtools=disabled
    build_meson gst-plugins-base "$GST/gst-plugins-base" "${common[@]}" -Dintrospection=disabled -Dorc=disabled -Dtools=disabled \
        -Dplayback=enabled -Dtypefind=enabled -Dapp=enabled -Daudioconvert=enabled -Daudioresample=enabled \
        -Dvideoconvertscale=enabled -Dvolume=enabled -Drawparse=enabled -Dpbtypes=enabled -Dsubparse=enabled \
        -Dvideorate=enabled -Daudiorate=enabled -Dgl=enabled -Dgl_api=opengl -Dgl_platform=cgl -Dgl_winsys=cocoa
    build_meson gst-plugins-good "$GST/gst-plugins-good" "${common[@]}" -Dorc=disabled -Disomp4=enabled -Dmatroska=enabled \
        -Davi=enabled -Dwavparse=enabled -Daudioparsers=enabled -Did3demux=enabled -Dapetag=enabled -Dicydemux=enabled \
        -Ddeinterlace=enabled -Dflv=enabled -Dvideofilter=enabled
    build_meson gst-plugins-bad "$GST/gst-plugins-bad" "${common[@]}" -Dintrospection=disabled -Dorc=disabled -Dgl=enabled \
        -Dapplemedia=enabled -Dvideoparsers=enabled -Dmpegtsdemux=enabled -Dmpegdemux=enabled -Did3tag=enabled
  ) || exit 1
fi

# Install names: the library's usual name (libfreetype.6.dylib, libgnutls.30.dylib) in this
# folder, as an absolute path, and references between them likewise. Wine's build runs tools
# against them (sfnt2fon uses FreeType), which needs a path that works as it is; the runtime's
# packaging rewrites them for the runtime when it copies them.
log "Install names"
# The file a library name in this folder stands for: links (libglib-2.0.dylib) are followed to
# the library itself (libglib-2.0.0.dylib), so that everything names one library one way. Two
# names for one library would load it twice.
real_name(){
  local f="$PREFIX/lib/$1"
  if [ -e "$f" ]; then basename "$(readlink -f "$f" 2>/dev/null || echo "$f")"; else echo "$1"; fi
}
for lib in "$PREFIX"/lib/*.dylib "$PREFIX"/lib/gstreamer-1.0/*.dylib; do
  [ -f "$lib" ] || continue
  [ -L "$lib" ] && continue
  case "$lib" in
    */gstreamer-1.0/*) ;;   # a plugin: loaded by path, its own name does not matter
    *)
      id="$(basename "$lib")"
      # Nettle names itself by its full version (libnettle.8.9.dylib), but what links to it asks
      # for the major one (libnettle.8.dylib); use the latter, so the runtime carries one copy.
      case "$id" in libnettle.*|libhogweed.*)
        short="$(printf '%s' "$id" | sed -E 's/^(lib[^.]+\.[0-9]+)\.[0-9.]+\.dylib$/\1.dylib/')"
        [ -e "$PREFIX/lib/$short" ] && id="$short" ;;
      esac
      install_name_tool -id "$PREFIX/lib/$id" "$lib" 2>/dev/null ;;
  esac
  { otool -L "$lib" | awk 'NR>1{print $1}' | grep -E "^($PREFIX/lib/[^/]+$|@rpath/)" || true; } | while IFS= read -r dep; do
    name="$(basename "$dep")"
    case "$name" in libnettle.*|libhogweed.*) want="$name" ;; *) want="$(real_name "$name")" ;; esac
    [ -e "$PREFIX/lib/$want" ] || continue
    [ "$dep" = "$PREFIX/lib/$want" ] || install_name_tool -change "$dep" "$PREFIX/lib/$want" "$lib"
  done
  codesign --force --sign - "$lib" 2>/dev/null
done
"$REPO/scripts/lib/check-macos-compat.sh" "$MACOS_MIN" "$PREFIX/lib"
ls "$PREFIX"/lib/libgnutls.30.dylib "$PREFIX"/lib/libfreetype.6.dylib >/dev/null || die "the build is missing a library"
echo "built: $PREFIX"
