#!/usr/bin/env bash
# launch-endfield.sh — launch Arknights: Endfield directly, bypassing the Gryphline launcher.
#
# The game binary ships its own embedded login UI (CefView / QCefView.dll), so it can start and
# log in without the launcher. Use this when the launcher won't start, or to skip it entirely.
# It runs through the patched CrossOver app, so the anti-cheat fixes and the D3DMetal graphics
# setting are already in effect.
#
# Usage:
#   scripts/launch-endfield.sh              # launch and play
#   DEBUG=1 scripts/launch-endfield.sh      # also capture a Wine log to ~/endfield-debug/
#
# Env overrides: APP (CrossOver app), BOTTLE, TARGET (windows exe path), WINEDEBUG
#
# NOTE: the game still updates itself via the launcher. If a game patch ships, run the launcher
# once when it's working again to update; this script is for launching an already-updated install.

set -uo pipefail

# ---- locate the patched CrossOver app ---------------------------------------
APP="${APP:-}"
if [ -z "$APP" ]; then
  for c in "/Applications/CrossOver_Endfield_Patch.app" \
           "$HOME/Applications/CrossOver_Endfield_Patch.app" \
           "/Applications/CrossOver.app"; do
    [ -d "$c" ] && APP="$c" && break
  done
fi
[ -d "$APP" ] || { echo "ERROR: patched CrossOver app not found. Set APP=/path/to/CrossOver_Endfield_Patch.app" >&2; exit 1; }
CXR="$APP/Contents/SharedSupport/CrossOver"; CXBIN="$CXR/bin"
[ -x "$CXBIN/wine" ] || { echo "ERROR: wine not found at $CXBIN/wine" >&2; exit 1; }

# ---- bottle + target --------------------------------------------------------
BOTTLE="${BOTTLE:-Arknights Endfield}"
BP="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE"
TARGET="${TARGET:-C:/Program Files/GRYPHLINK/games/Arknights Endfield/Endfield.exe}"
[ -d "$BP" ] || { echo "ERROR: bottle '$BOTTLE' not found at $BP" >&2; exit 1; }

echo "App:    $APP"
echo "Bottle: $BOTTLE"
echo "Game:   $TARGET"

# ---- clean any stale Wine/ACE state so the anti-cheat starts fresh ----------
WINEPREFIX="$BP" CX_ROOT="$CXR" "$CXBIN/wineserver" -k >/dev/null 2>&1 || true
sleep 1

# ---- launch -----------------------------------------------------------------
# --wait-children keeps this terminal attached until the game exits (Ctrl+C to stop).
if [ "${DEBUG:-0}" = "1" ]; then
  OUT="$HOME/endfield-debug/launch-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
  echo "Debug log -> $OUT/cxlog.txt"
  CX_LOG="$OUT/cxlog.txt" WINEDEBUG="${WINEDEBUG:-+seh}" \
    "$CXBIN/wine" --bottle "$BOTTLE" --wait-children --cx-app "$TARGET"
else
  echo "Launching Endfield… (log in from the game's own screen; close the game or press Ctrl+C to stop)"
  "$CXBIN/wine" --bottle "$BOTTLE" --wait-children --cx-app "$TARGET"
fi
echo "Endfield exited."
