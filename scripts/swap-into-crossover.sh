#!/usr/bin/env bash
# swap-into-crossover.sh — build a patched CrossOver app for Arknights: Endfield.
#
# Produces /Applications/CrossOver_Endfield_Patch.app containing:
#   1. our patched Wine modules (the anti-cheat fixes — the reason the game runs at all)
#   2. GPTK4 / D3DMetal            (a REAL upgrade: stock CrossOver 26.2 ships D3DMetal 3.0 / GPTK3.
#                                   Point GPTK_DIR at Apple's GPTK4 redist to get D3DMetal 4. If your
#                                   SRC_APP already had GPTK4 installed, this step correctly no-ops.)
#   3. the latest MoltenVK          (optional; only used by Vulkan/DXVK/vkd3d paths, NOT by D3DMetal)
#
# Requires: /Applications/CrossOver.app at version 26.2 (ABI must match the build), and a completed
# build in build/wine-build64 (run scripts/build-wine.sh all first).
#
# Usage:  scripts/swap-into-crossover.sh
# Env:
#   SRC_APP    (default /Applications/CrossOver.app)
#   DEST_APP   (default /Applications/CrossOver_Endfield_Patch.app)
#   GPTK_DIR   (default ~/Downloads/GPTK_4/redist/lib/external)  — set SKIP_GPTK=1 to skip
#   MVK_VER    (default 1.4.1)                                    — set SKIP_MVK=1 to skip
#
# See docs/13-working-solution.md.

set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
B="$REPO/build/wine-build64"
SRC_APP="${SRC_APP:-/Applications/CrossOver.app}"
DEST_APP="${DEST_APP:-/Applications/CrossOver_Endfield_Patch.app}"
GPTK_DIR="${GPTK_DIR:-$HOME/Downloads/GPTK_4/redist/lib/external}"
MVK_VER="${MVK_VER:-1.4.1}"
WORK="${TMPDIR:-/tmp}/efw-swap.$$"
log(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok(){  printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------- preflight
[ -d "$SRC_APP" ] || { echo "ERROR: $SRC_APP not found"; exit 1; }
[ -f "$B/dlls/ntdll/ntdll.so" ] || { echo "ERROR: no build at $B — run scripts/build-wine.sh all first"; exit 1; }
ver="$(defaults read "$SRC_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null)"
[ "$ver" = "26.2" ] || warn "$SRC_APP is version '$ver', expected 26.2 — the Wine ABI must match the build."

# ---------------------------------------------------------------- 1. copy app
log "Copying $SRC_APP -> $DEST_APP"
rm -rf "$DEST_APP"; cp -a "$SRC_APP" "$DEST_APP" || { echo "copy failed (permissions?)"; exit 1; }
CXR="$DEST_APP/Contents/SharedSupport/CrossOver"
ok "copied"

# ---------------------------------------------------------------- 2. patched Wine
log "Swapping in our patched Wine modules (the anti-cheat fixes)"
swap(){ # src  dst-rel
  local dst="$CXR/$2"
  cp -f "$dst" "$dst.cxorig" 2>/dev/null || true
  cp -f "$1" "$dst" && codesign --force --sign - "$dst" 2>/dev/null && ok "$2"
}
swap "$B/dlls/ntdll/ntdll.so"                           "lib/wine/x86_64-unix/ntdll.so"        # Rosetta NOP + priv-instr fixes, NtDelayExecution QPC
swap "$B/dlls/kernel32/x86_64-windows/kernel32.dll"     "lib/wine/x86_64-windows/kernel32.dll" # KiUser*Dispatcher int3 spoof
swap "$B/dlls/ntoskrnl.exe/x86_64-windows/ntoskrnl.exe" "lib/wine/x86_64-windows/ntoskrnl.exe" # ntoskrnl em-backports

# CRITICAL: CrossOver's ntdll dlopens cxcompatdb.so (which applies the CX_GRAPHICS_BACKEND
# choice per process). cxcompatdb.so needs @rpath/libgnutls.30.dylib from lib64/, and dyld
# resolves that through the CALLING image's LC_RPATH — i.e. ntdll.so's. CodeWeavers' ntdll
# carries "@loader_path/../../../lib64"; our minimal build does not. Without it, cxcompatdb
# silently fails to load, D3DMetal never engages, d3d11 falls back to wined3d and the game
# dies with device-create error 80004005 (then falls back to Vulkan → broken rendering).
NT="$CXR/lib/wine/x86_64-unix/ntdll.so"
if ! otool -l "$NT" | grep -A2 LC_RPATH | grep -q 'lib64'; then
  install_name_tool -add_rpath "@loader_path/../../../lib64" "$NT" 2>/dev/null
  codesign --force --sign - "$NT" 2>/dev/null
fi
otool -l "$NT" | grep -A2 LC_RPATH | grep -q 'lib64' \
  && ok "ntdll.so LC_RPATH → lib64 (cxcompatdb/gnutls — required for D3DMetal)" \
  || { echo "ERROR: failed to add lib64 rpath to ntdll.so — D3DMetal will NOT work"; exit 1; }

# ---------------------------------------------------------------- 3. GPTK4 / D3DMetal
if [ "${SKIP_GPTK:-0}" = "1" ]; then
  log "GPTK4: skipped (SKIP_GPTK=1)"
elif [ -d "$GPTK_DIR" ]; then
  log "GPTK4 / D3DMetal from $GPTK_DIR"
  DEST_GPTK="$CXR/lib64/apple_gptk/external"
  if [ -d "$DEST_GPTK" ]; then
    same=1
    for f in libd3dshared.dylib "D3DMetal.framework/Versions/A/D3DMetal"; do
      a=$(shasum "$GPTK_DIR/$f" 2>/dev/null | cut -d' ' -f1); b=$(shasum "$DEST_GPTK/$f" 2>/dev/null | cut -d' ' -f1)
      [ -n "$a" ] && [ "$a" = "$b" ] || same=0
    done
    if [ "$same" = "1" ]; then
      ok "identical to what is already in $SRC_APP (GPTK4 already installed there) — nothing to do"
    else
      cp -a "$DEST_GPTK" "$DEST_GPTK.cxorig" 2>/dev/null || true
      ditto "$GPTK_DIR/" "$DEST_GPTK/" && ok "installed GPTK4 D3DMetal"
      codesign --force --sign - "$DEST_GPTK/libd3dshared.dylib" 2>/dev/null
      codesign --force --deep --sign - "$DEST_GPTK/D3DMetal.framework" 2>/dev/null
    fi
  else warn "apple_gptk/external not found in this CrossOver — skipping"; fi
else
  warn "GPTK_DIR not found ($GPTK_DIR) — skipping. NOTE: stock CrossOver 26.2 ships D3DMetal 3.0; install Apple GPTK4 for D3DMetal 4."
fi

# ---------------------------------------------------------------- 4. MoltenVK
if [ "${SKIP_MVK:-0}" = "1" ]; then
  log "MoltenVK: skipped (SKIP_MVK=1)"
else
  log "MoltenVK $MVK_VER (only used by Vulkan/DXVK/vkd3d — NOT by the D3DMetal path)"
  mkdir -p "$WORK" && cd "$WORK"
  if curl -sfL -o mvk.tar "https://github.com/KhronosGroup/MoltenVK/releases/download/v${MVK_VER}/MoltenVK-macos.tar" && tar xf mvk.tar 2>/dev/null; then
    NEW=$(find . -name 'libMoltenVK.dylib' -path '*dylib/macOS*' 2>/dev/null | head -1)
    if [ -n "$NEW" ]; then
      # CrossOver's Wine is x86_64 under Rosetta — an arm64-only dylib silently fails to load.
      lipo "$NEW" -thin x86_64 -output mvk-x86_64.dylib 2>/dev/null || cp "$NEW" mvk-x86_64.dylib
      cp -f "$CXR/lib64/libMoltenVK.dylib" "$CXR/lib64/libMoltenVK.dylib.cxorig" 2>/dev/null || true
      cp -f mvk-x86_64.dylib "$CXR/lib64/libMoltenVK.dylib"
      install_name_tool -id @rpath/libMoltenVK.dylib "$CXR/lib64/libMoltenVK.dylib" 2>/dev/null
      codesign --force --sign - "$CXR/lib64/libMoltenVK.dylib" 2>/dev/null
      ok "installed MoltenVK $MVK_VER ($(file "$CXR/lib64/libMoltenVK.dylib" | grep -o 'x86_64' | head -1))"
    else warn "couldn't locate libMoltenVK.dylib in the release tar — keeping CrossOver's"; fi
  else warn "MoltenVK download failed — keeping CrossOver's bundled copy"; fi
  cd "$REPO"; rm -rf "$WORK"
fi

# ---------------------------------------------------------------- 5. sign / unquarantine
log "Removing bundle seal + quarantine so the modified files load"
rm -rf "$DEST_APP/Contents/_CodeSignature" "$DEST_APP/Contents/CodeResources"
xattr -drs com.apple.quarantine "$DEST_APP" 2>/dev/null || true
ok "done"

# ---------------------------------------------------------------- 6. verify
log "Verify"
echo "  wineserver: $("$CXR/bin/wineserver" --version 2>&1 | head -1)"
for f in lib/wine/x86_64-unix/ntdll.so lib/wine/x86_64-windows/kernel32.dll lib/wine/x86_64-windows/ntoskrnl.exe; do
  printf '  %-42s %s bytes\n' "$(basename "$f")" "$(stat -f '%z' "$CXR/$f" 2>/dev/null)"
done
echo "  MoltenVK:  $(strings -a "$CXR/lib64/libMoltenVK.dylib" 2>/dev/null | grep -oE '^1\.[0-9]+\.[0-9]+$' | sort -u | head -1)"
echo "  D3DMetal:  $(plutil -extract CFBundleShortVersionString raw "$CXR/lib64/apple_gptk/external/D3DMetal.framework/Resources/Info.plist" 2>/dev/null)"

cat <<EOF

Done -> $DEST_APP

Next:
  1. Open $DEST_APP, create a fresh Windows 11 64-bit bottle, install the Gryphline launcher + Endfield.
  2. IMPORTANT: in the launcher's graphics settings choose **DirectX 11**.
     Vulkan and DX12 do NOT work under CrossOver 26.2 for this game (white screen).
  3. Launch. See docs/13-working-solution.md for troubleshooting.
EOF
