#!/usr/bin/env bash
# Package build/wine-out and build/moltenvk-out for apply-modules.sh.
#
# Usage:  scripts/package.sh
# Env: BUILD_DIR (default <repo>/build), DIST_DIR (default <repo>/dist)
#
# Runs under the shared terminal dashboard when stdout is a TTY (see
# scripts/lib/build-ui.sh); plain "==>" output on CI / pipes.

set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$REPO/build}"
DIST_DIR="${DIST_DIR:-$REPO/dist}"
WINE_OUT="$BUILD_DIR/wine-out"
MVK_OUT="$BUILD_DIR/moltenvk-out"
PKG_NAME="endfield-wine-modules"
out="$DIST_DIR/$PKG_NAME"

UI_SELF="$0"
. "$REPO/scripts/lib/build-ui.sh"
die(){ printf 'error: %s\n' "$*" >&2; exit 1; }

ui_init "FineWine — packaging $PKG_NAME"
mkdir -p "$BUILD_DIR" "$DIST_DIR"   # build/ for the tar log, dist/ for the package

ui_begin verify 2 "Checking build outputs"
[ -f "$WINE_OUT/SOURCE_URL" ] || die "no $WINE_OUT; run scripts/build-wine.sh"
[ -f "$MVK_OUT/SOURCE_URL" ] || die "no $MVK_OUT; run scripts/build-moltenvk.sh"
ui_end

ui_begin stage 30 "Staging modules into $out"
rm -rf "$out" "$out.tar.gz" "$out.tar.gz.sha256"; mkdir -p "$out"
cp "$WINE_OUT"/{ntdll.so,winemac.so,dwmapi.dll,kernel32.dll,ntoskrnl.exe,lsass.exe,wineboot.exe,rundll32.exe,wineserver,COPYING.LIB,CROSSOVER_VERSION} "$out/"
cp "$MVK_OUT"/{libMoltenVK.dylib,LICENSE.MoltenVK} "$out/"
# cxcompatdb.so needs ntdll's LC_RPATH to resolve @rpath/libgnutls and enable D3DMetal.
# Add CrossOver's library path here so installation needs no developer tools.
install_name_tool -add_rpath "@loader_path/../../../lib64" "$out/ntdll.so"
# winemac.so resolves CrossOver's own libraries the same way as stock.
install_name_tool -add_rpath "@loader_path/../../../lib64" "$out/winemac.so"
ui_end

ui_begin metadata 18 "Writing SOURCE.txt"
if [ -n "${GITHUB_REPOSITORY:-}" ]; then repo_url="${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY"
else repo_url="$(git -C "$REPO" config --get remote.origin.url || echo unknown)"; fi
commit="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
git -C "$REPO" diff --quiet HEAD -- patches scripts 2>/dev/null || commit="$commit (with uncommitted changes)"
cat > "$out/SOURCE.txt" <<EOF
Wine modules: LGPL-2.1-or-later (see COPYING.LIB).
libMoltenVK.dylib: Apache-2.0 (see LICENSE.MoltenVK).

  CrossOver $(cat "$out/CROSSOVER_VERSION") source: $(cat "$WINE_OUT/SOURCE_URL")
  MoltenVK source:          $(cat "$MVK_OUT/SOURCE_URL")
  patches and build script: $repo_url
  commit:                   $commit
EOF
ui_end

ui_begin checksum 20 "Computing SHA256SUMS"
( cd "$out" && shasum -a 256 ntdll.so winemac.so dwmapi.dll kernel32.dll ntoskrnl.exe lsass.exe wineboot.exe rundll32.exe wineserver libMoltenVK.dylib > SHA256SUMS && cat SHA256SUMS )
ui_end

ui_begin tar 30 "Creating $PKG_NAME.tar.gz"
ui_run "$BUILD_DIR/package-tar.log" "COPYFILE_DISABLE=1 tar -czf $PKG_NAME.tar.gz" \
  sh -c 'exec env COPYFILE_DISABLE=1 tar -czf "$1" -C "$2" "$3"' \
  ui_sh "$out.tar.gz" "$DIST_DIR" "$PKG_NAME"
( cd "$DIST_DIR" && shasum -a 256 "$PKG_NAME.tar.gz" > "$PKG_NAME.tar.gz.sha256" )
ui_end

echo "packaged: $out.tar.gz"
ui_finish
