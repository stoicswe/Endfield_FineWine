#!/usr/bin/env bash
# Package build/wine-out and build/moltenvk-out for apply-modules.sh.
#
# Usage:  scripts/package.sh
# Env: BUILD_DIR (default <repo>/build), DIST_DIR (default <repo>/dist)

set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$REPO/build}"
DIST_DIR="${DIST_DIR:-$REPO/dist}"
WINE_OUT="$BUILD_DIR/wine-out"
MVK_OUT="$BUILD_DIR/moltenvk-out"
PKG_NAME="endfield-wine-modules"
out="$DIST_DIR/$PKG_NAME"

log(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die(){ printf 'error: %s\n' "$*" >&2; exit 1; }

log "Packaging into $out.tar.gz"
[ -f "$WINE_OUT/SOURCE_URL" ] || die "no $WINE_OUT; run scripts/build-wine.sh"
[ -f "$MVK_OUT/SOURCE_URL" ] || die "no $MVK_OUT; run scripts/build-moltenvk.sh"

rm -rf "$out" "$out.tar.gz" "$out.tar.gz.sha256"; mkdir -p "$out"
cp "$WINE_OUT"/{ntdll.so,kernel32.dll,ntoskrnl.exe,COPYING.LIB,CROSSOVER_VERSION} "$out/"
cp "$MVK_OUT"/{libMoltenVK.dylib,LICENSE.MoltenVK} "$out/"
# cxcompatdb.so needs ntdll's LC_RPATH to resolve @rpath/libgnutls and enable D3DMetal.
# Add CrossOver's library path here so installation needs no developer tools.
install_name_tool -add_rpath "@loader_path/../../../lib64" "$out/ntdll.so"

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
( cd "$out" && shasum -a 256 ntdll.so kernel32.dll ntoskrnl.exe libMoltenVK.dylib > SHA256SUMS && cat SHA256SUMS )
COPYFILE_DISABLE=1 tar -czf "$out.tar.gz" -C "$DIST_DIR" "$PKG_NAME"
( cd "$DIST_DIR" && shasum -a 256 "$PKG_NAME.tar.gz" > "$PKG_NAME.tar.gz.sha256" )
echo "packaged: $out.tar.gz"