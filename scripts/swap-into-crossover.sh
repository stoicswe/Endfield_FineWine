#!/usr/bin/env bash
# swap-into-crossover.sh — deploy the patched Wine modules into a copy of CrossOver.app.
#
# The custom Wine (build/wine-build64) is built minimal (no graphics libs), so we surgically swap
# ONLY the 3 patched modules into a copy of CrossOver 26.2 and let CrossOver provide D3DMetal/Metal
# graphics + fonts/TLS. This is the PROVEN procedure that gets Endfield to its login screen.
# See docs/13-working-solution.md.
#
# Requirements: /Applications/CrossOver.app must be version 26.2 (same Wine 11.0 base as the build),
# and build/wine-build64 must contain the patched modules (build + git apply the patches first).
#
# Usage: scripts/swap-into-crossover.sh
# Env:   SRC_APP (default /Applications/CrossOver.app), DEST_APP (default build/CrossOver_patched.app)

set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
B="$REPO/build/wine-build64"
SRC_APP="${SRC_APP:-/Applications/CrossOver.app}"
DEST_APP="${DEST_APP:-$REPO/build/CrossOver_patched.app}"
log(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }

[ -d "$SRC_APP" ] || { echo "ERROR: $SRC_APP not found"; exit 1; }
[ -f "$B/dlls/ntdll/ntdll.so" ] || { echo "ERROR: build not found at $B — build + apply patches first"; exit 1; }
ver="$(defaults read "$SRC_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null)"
[ "$ver" = "26.2" ] || echo "WARNING: $SRC_APP is version '$ver', expected 26.2 (ABI must match the build)."

log "Copying $SRC_APP -> $DEST_APP"
rm -rf "$DEST_APP"; cp -a "$SRC_APP" "$DEST_APP"
DCXR="$DEST_APP/Contents/SharedSupport/CrossOver"

log "Swapping the 3 patched modules (keeping CrossOver's D3DMetal/graphics/fonts)"
swap() {  # src  dst-relative-to-DCXR
  local dst="$DCXR/$2"
  cp -f "$dst" "$dst.cxorig" 2>/dev/null || true
  cp -f "$1" "$dst" && codesign --force --sign - "$dst" 2>/dev/null && echo "  ✓ $2"
}
swap "$B/dlls/ntdll/ntdll.so"                           "lib/wine/x86_64-unix/ntdll.so"       # Rosetta fixes + NtDelayExecution
swap "$B/dlls/kernel32/x86_64-windows/kernel32.dll"     "lib/wine/x86_64-windows/kernel32.dll" # int3 hack
swap "$B/dlls/ntoskrnl.exe/x86_64-windows/ntoskrnl.exe" "lib/wine/x86_64-windows/ntoskrnl.exe" # em-backports

log "Removing bundle seal + quarantine so the modified files load"
rm -rf "$DEST_APP/Contents/_CodeSignature" "$DEST_APP/Contents/CodeResources"
xattr -drs com.apple.quarantine "$DEST_APP" 2>/dev/null || true

log "Smoke test"
"$DCXR/bin/wineserver" --version 2>&1 | head -1

cat <<EOF

Done -> $DEST_APP

Run Endfield through the patched CrossOver (D3DMetal graphics + our anti-cheat fixes):
  "$DCXR/bin/wine" --bottle "Arknights Endfield" \\
    --cx-app "C:/Program Files/GRYPHLINK/games/Arknights Endfield/Endfield.exe"

Or point the CrossOver GUI's launcher at this app. The game should reach the login screen.
To capture logs: prefix with  CX_LOG=/tmp/ef.log WINEDEBUG=+seh
EOF
