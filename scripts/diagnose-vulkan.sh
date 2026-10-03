#!/usr/bin/env bash
# diagnose-vulkan.sh — one-shot diagnostic capture for the game's Vulkan renderer.
#
# Runs Endfield through the patched CrossOver app with the game's Vulkan renderer, Metal API
# validation and MoltenVK logging enabled, and captures the process's stderr — where MoltenVK
# (`MVKBaseObject::reportMessage` -> fprintf(stderr, ...)) and Metal write their diagnostics.
# CrossOver's GUI discards that stderr, which is why the unified log only shows redacted
# `<private>` messages (the 234k `Metal:GPUDebug` lines and Metal compiler warnings).
#
# Usage:
#   scripts/diagnose-vulkan.sh                 # MoltenVK INFO logs + stderr captured (validation OFF)
#   SHADER_DUMP=1 scripts/diagnose-vulkan.sh   # also dump SPIR-V input + generated MSL per pipeline
#   LOGLEVEL=4 scripts/diagnose-vulkan.sh      # MoltenVK debug logging (very verbose, slower)
#   VALIDATION=1 scripts/diagnose-vulkan.sh    # ALSO enable MTL_DEBUG_LAYER / shader validation
#                                              #   (very slow — only when needed)
#
# Output: ~/endfield-debug/diagnose-<timestamp>/
#   wine-errors.txt   process stderr+stdout: MoltenVK logs, Metal validation, compiler warnings
#   shaders/          (SHADER_DUMP=1) SPIR-V input + generated MSL per pipeline
#
# Reproduce the menu / operator view / walk around, then quit (or Ctrl+C). The terminal stays
# attached until the game exits. The script stops the bottle first (wineserver -k), so an
# existing session ends.
#
# Env overrides: APP, BOTTLE, TARGET, LOGLEVEL, SHADER_DUMP, VALIDATION, MTL_DEBUG_LAYER,
#   MTL_SHADER_VALIDATION, WINEDEBUG (Wine channels, default err+all,fixme-all), GFXARGS.

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
[ -x "$CXBIN/wine" ] || { echo "ERROR: wine not found at $CXBIN" >&2; exit 1; }

# ---- bottle + target --------------------------------------------------------
BOTTLE="${BOTTLE:-Arknights Endfield}"
BP="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE"
TARGET="${TARGET:-C:/Program Files/GRYPHLINK/games/Arknights Endfield/Endfield.exe}"
GFXARGS="${GFXARGS:--force-vulkan}"
[ -d "$BP" ] || { echo "ERROR: bottle '$BOTTLE' not found at $BP" >&2; exit 1; }

OUT="$HOME/endfield-debug/diagnose-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"

# ---- diagnostic environment (inherited by the game process) -----------------
# Metal API validation is OFF by default: it checks/serialises nearly every Metal call and
# makes shader compilation and loading dramatically slower. The bottle normally has these
# commented out; do not re-enable them unless explicitly asked. Set VALIDATION=1 to opt in.
if [ "${VALIDATION:-0}" = 1 ]; then
  export MTL_DEBUG_LAYER="${MTL_DEBUG_LAYER:-1}"
  export MTL_SHADER_VALIDATION="${MTL_SHADER_VALIDATION:-1}"
fi
# MoltenVK log level: 2=warn, 3=info (default; includes the per-shader
# "Compiling Metal shader with FastMath <x>abled and PreserveInvariance <y>abled." line), 4=debug.
export MVK_CONFIG_LOG_LEVEL="${LOGLEVEL:-3}"
if [ "${SHADER_DUMP:-0}" = 1 ]; then
  export MVK_CONFIG_SHADER_DUMP_DIR="$OUT/shaders"
fi

echo "App:         $APP"
echo "Bottle:      $BOTTLE"
echo "Renderer:    Vulkan ($GFXARGS)"
if [ "${VALIDATION:-0}" = 1 ]; then
  echo "Validation:  ON (MTL_DEBUG_LAYER=${MTL_DEBUG_LAYER}, MTL_SHADER_VALIDATION=${MTL_SHADER_VALIDATION}) — slow, debug-only"
else
  echo "Validation:  off (enable with VALIDATION=1)"
fi
echo "MVK log:     level ${MVK_CONFIG_LOG_LEVEL}"
[ -n "${MVK_CONFIG_SHADER_DUMP_DIR:-}" ] && echo "Shader dump: $MVK_CONFIG_SHADER_DUMP_DIR"
echo "Capture:     $OUT/wine-errors.txt"

# ---- clean stale Wine/ACE state so the game starts fresh --------------------
WINEPREFIX="$BP" CX_ROOT="$CXR" "$CXBIN/wineserver" -k >/dev/null 2>&1 || true
sleep 1

# ---- launch -----------------------------------------------------------------
# Channels via --debugmsg: CrossOver's wrapper overwrites an exported WINEDEBUG.
echo
echo "Launching — reproduce the menu / operator view / walk around, then quit (Ctrl+C to stop)."
"$CXBIN/wine" --bottle "$BOTTLE" --debugmsg "${WINEDEBUG:-err+all,fixme-all}" --wait-children \
  --cx-app "$TARGET" $GFXARGS > "$OUT/wine-errors.txt" 2>&1
RC=$?

echo
echo "Endfield exited (rc=$RC)."
echo "Capture: $OUT/wine-errors.txt  ($(wc -l < "$OUT/wine-errors.txt" 2>/dev/null || echo 0) lines)"
[ -d "$OUT/shaders" ] && echo "Shaders: $OUT/shaders  ($(ls "$OUT/shaders" 2>/dev/null | wc -l | tr -d ' ') files)"
echo
echo "--- MoltenVK errors / warnings ---"
grep -iE "mvk-(error|warn)" "$OUT/wine-errors.txt" 2>/dev/null | head -20 || echo "(none)"
echo
echo "--- GPU / Metal faults or aborts ---"
grep -iE "Execution of the command buffer|IOGPU|fault|abort|hazard|DeviceLost|PageFault" "$OUT/wine-errors.txt" 2>/dev/null | head -20 || echo "(none)"
echo
echo "--- shader compile lines (first 20) ---"
grep -iE "Compiling Metal shader" "$OUT/wine-errors.txt" 2>/dev/null | head -20 || echo "(none)"
echo
echo "Send the capture above for analysis."
