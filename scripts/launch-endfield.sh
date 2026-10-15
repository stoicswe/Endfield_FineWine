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
#   DEBUG=light scripts/launch-endfield.sh  # also log Wine errors to ~/endfield-debug/ (cheap —
#                                           #   fine to leave on while playing)
#   DEBUG=1 scripts/launch-endfield.sh      # full CrossOver log (CX_LOG) to ~/endfield-debug/ —
#                                           #   heavy (hundreds of MB, slower; ACE is timing-sensitive)
#
# Env overrides: APP (CrossOver app), BUNDLE_ID (find a renamed patched app by bundle id), BOTTLE, TARGET (windows exe path),
#   WINEDEBUG (channels for DEBUG=1/light, default +seh / err+all,fixme-all — passed with
#   --debugmsg, because CrossOver's wine wrapper overwrites the WINEDEBUG variable itself),
#   GFXARGS (default "-force-d3d11" — a DIRECT launch bypasses the launcher, so the
#   launcher's DirectX-11 setting does NOT apply; without this flag Unity defaults to
#   Vulkan, which is experimental (see docs/graphics-performance.md). Set GFXARGS="" to
#   disable, or GFXARGS=-force-vulkan to force Vulkan.)
#
# NOTE: the game still updates itself via the launcher. If a game patch ships, run the launcher
# once when it's working again to update; this script is for launching an already-updated install.

set -uo pipefail

# ---- locate the patched CrossOver app (by bundle identifier; it may be renamed) ------------
BUNDLE_ID="${BUNDLE_ID:-com.codeweavers.CrossOvEF}"
bundle_id_of() { plutil -extract CFBundleIdentifier raw "$1/Contents/Info.plist" 2>/dev/null \
                 || defaults read "$1/Contents/Info" CFBundleIdentifier 2>/dev/null; }
is_cx_app() { [ -d "$1/Contents/SharedSupport/CrossOver/bin" ] && [ -x "$1/Contents/SharedSupport/CrossOver/bin/wine" ]; }
# Only trust installs under the non-user-writable roots, so a same-bundle-id bundle in a writable
# location (Downloads, /tmp, a mounted image, …) is never run.
is_trusted_install() { case "$1" in /Applications/*|"$HOME"/Applications/*) return 0 ;; *) return 1 ;; esac; }
is_cx_candidate() { is_trusted_install "$1" || return 1; [ "$(bundle_id_of "$1")" = "$BUNDLE_ID" ] || return 1; is_cx_app "$1"; }

APP="${APP:-}"
if [ -z "$APP" ] && command -v mdfind >/dev/null 2>&1; then
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if is_cx_candidate "$c"; then APP="$c"; break; fi
  done < <(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null)
fi
if [ -z "$APP" ]; then
  for c in /Applications/*.app "$HOME"/Applications/*.app; do
    if is_cx_candidate "$c"; then APP="$c"; break; fi
  done
fi
if [ -z "$APP" ]; then
  for c in "/Applications/CrossOver_Endfield_Patch.app" \
           "$HOME/Applications/CrossOver_Endfield_Patch.app" \
           "/Applications/CrossOver.app"; do
    [ -d "$c" ] && APP="$c" && break
  done
fi
[ -d "$APP" ] || { echo "ERROR: patched CrossOver app not found (bundle id $BUNDLE_ID). Set APP=/path/to/CrossOver_Endfield_Patch.app" >&2; exit 1; }
CXR="$APP/Contents/SharedSupport/CrossOver"; CXBIN="$CXR/bin"
[ -x "$CXBIN/wine" ] || { echo "ERROR: wine not found at $CXBIN/wine" >&2; exit 1; }

# ---- bottle + target --------------------------------------------------------
BOTTLE="${BOTTLE:-Arknights Endfield}"
BP="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE"
TARGET="${TARGET:-C:/Program Files/GRYPHLINK/games/Arknights Endfield/Endfield.exe}"
GFXARGS="${GFXARGS--force-d3d11}"
[ -d "$BP" ] || { echo "ERROR: bottle '$BOTTLE' not found at $BP" >&2; exit 1; }

echo "App:    $APP"
echo "Bottle: $BOTTLE"
echo "Game:   $TARGET"

# ---- clean any stale Wine/ACE state so the anti-cheat starts fresh ----------
WINEPREFIX="$BP" CX_ROOT="$CXR" "$CXBIN/wineserver" -k >/dev/null 2>&1 || true
sleep 1

# ---- launch -----------------------------------------------------------------
# --wait-children keeps this terminal attached until the game exits (Ctrl+C to stop).
# Debug channels go through --debugmsg: CrossOver's wrapper sets WINEDEBUG itself ("-all" unless
# CX_LOG or --debugmsg says otherwise), so an exported WINEDEBUG would be silently dropped.
case "${DEBUG:-0}" in
  1|full)
    OUT="$HOME/endfield-debug/launch-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
    echo "Debug log -> $OUT/cxlog.txt"
    CX_LOG="$OUT/cxlog.txt" \
      "$CXBIN/wine" --bottle "$BOTTLE" --debugmsg "${WINEDEBUG:-+seh}" --wait-children --cx-app "$TARGET" $GFXARGS
    ;;
  light|errors)
    OUT="$HOME/endfield-debug/launch-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
    echo "Launching Endfield… (Wine errors + the game's console output -> $OUT/wine-errors.txt)"
    # Without CX_LOG the wrapper adds none of its heavy default channels, so this stays small.
    "$CXBIN/wine" --bottle "$BOTTLE" --debugmsg "${WINEDEBUG:-err+all,fixme-all}" --wait-children \
      --cx-app "$TARGET" $GFXARGS > "$OUT/wine-errors.txt" 2>&1
    ;;
  *)
    echo "Launching Endfield… (log in from the game's own screen; close the game or press Ctrl+C to stop)"
    "$CXBIN/wine" --bottle "$BOTTLE" --wait-children --cx-app "$TARGET" $GFXARGS
    ;;
esac
echo "Endfield exited."
