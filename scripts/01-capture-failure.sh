#!/usr/bin/env bash
# 01-capture-failure.sh — Milestone 1: capture Endfield's ACE failure signature under CrossOver.
#
# Purpose: launch Endfield (or its Gryphlink launcher) through CrossOver's Wine with
# WINEDEBUG logging, collect the Wine log + macOS crash report, and auto-classify the
# failure so you know whether the blocker is a *fixable missing-function abort* or a
# *categorical ACE force-quit*. See docs/09-implementation-roadmap.md (Milestone 1) and
# docs/01-ace-anticheat-and-endfield.md.
#
# Usage:
#   scripts/01-capture-failure.sh [BOTTLE] [TARGET_WINDOWS_PATH]
#
# Env overrides (all optional):
#   BOTTLE=<name>     CrossOver bottle name (auto-detected if exactly one exists)
#   TARGET=<winpath>  Windows path to launch (default: C:/Program Files/GRYPHLINK/Launcher.exe)
#   WINEDEBUG=<chans> Wine debug channels (default: +loaddll,+seh,+ntoskrnl)
#   RELAY=1           Add heavy +relay tracing. SLOW and changes timing — only if the
#                     default run is uninformative. ACE is timing-sensitive; expect
#                     different behavior under relay.
#   TIMEOUT=<secs>    Max seconds to run before killing (default: 120)
#   OUTDIR=<dir>      Output directory (default: ~/endfield-debug/<timestamp>)
#   CX_APP=<path>     Path to CrossOver.app (default: auto-detect)
#
# No sudo required. Written for macOS /bin/bash 3.2 compatibility (no bash 4 features).

set -uo pipefail

# ---- locate CrossOver.app ---------------------------------------------------
CX_APP="${CX_APP:-}"
if [ -z "$CX_APP" ]; then
  for cand in "/Applications/CrossOver Preview.app" "$HOME/Applications/CrossOver Preview.app"; do
    [ -d "$cand" ] && CX_APP="$cand" && break
  done
fi
if [ -z "$CX_APP" ] || [ ! -d "$CX_APP" ]; then
  echo "ERROR: CrossOver Preview.app not found. Set CX_APP=/path/to/CrossOver Preview.app" >&2
  exit 1
fi
CX_ROOT="$CX_APP/Contents/SharedSupport/CrossOver"
CXBIN="$CX_ROOT/bin"
if [ ! -x "$CXBIN/wine" ]; then
  echo "ERROR: CrossOver wine loader not found at $CXBIN/wine" >&2
  exit 1
fi

# ---- resolve bottle ---------------------------------------------------------
BOTTLES_DIR="$HOME/Library/Application Support/CrossOver/Bottles"
BOTTLE="${BOTTLE:-${1:-}}"
if [ -z "$BOTTLE" ]; then
  count=0; single=""
  if [ -d "$BOTTLES_DIR" ]; then
    for d in "$BOTTLES_DIR"/*/; do
      [ -d "$d" ] || continue
      count=$((count + 1)); single="$(basename "$d")"
    done
  fi
  if [ "$count" -eq 1 ]; then
    BOTTLE="$single"
  else
    echo "Multiple (or zero) bottles found. Pass the bottle name explicitly." >&2
    echo "Available bottles in $BOTTLES_DIR:" >&2
    ls -1 "$BOTTLES_DIR" 2>/dev/null | sed 's/^/  - /' >&2
    exit 1
  fi
fi
BOTTLE_PATH="$BOTTLES_DIR/$BOTTLE"
if [ ! -d "$BOTTLE_PATH" ]; then
  echo "ERROR: bottle '$BOTTLE' not found at $BOTTLE_PATH" >&2
  echo "Available bottles:" >&2
  ls -1 "$BOTTLES_DIR" 2>/dev/null | sed 's/^/  - /' >&2
  exit 1
fi

# ---- resolve target exe -----------------------------------------------------
TARGET="${TARGET:-${2:-C:/Program Files/GRYPHLINK/Launcher.exe}}"

# ---- output dir -------------------------------------------------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${OUTDIR:-$HOME/endfield-debug/$STAMP}"
mkdir -p "$OUTDIR"
WINE_LOG="$OUTDIR/wine.log"
CXLOG="$OUTDIR/cxlog.txt"
MAC_LOG="$OUTDIR/macos-log.txt"
MARKER="$OUTDIR/.start_marker"
touch "$MARKER"

# ---- debug channels ---------------------------------------------------------
WINEDEBUG="${WINEDEBUG:-+loaddll,+seh,+ntoskrnl}"
if [ "${RELAY:-0}" = "1" ]; then
  WINEDEBUG="+relay,$WINEDEBUG"
fi
TIMEOUT="${TIMEOUT:-120}"

# ---- Milestone 0 inventory (also saved) ------------------------------------
INV="$OUTDIR/inventory.txt"
{
  echo "=== environment inventory ($STAMP) ==="
  echo "CrossOver Preview.app:   $CX_APP"
  echo "CFBundleShortVersionString: $(defaults read "$CX_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?')"
  echo "wine --version:  $("$CXBIN/wine" --version 2>/dev/null || echo '?')"
  echo -n "wineserver arch: "; file "$CXBIN/wineserver" 2>/dev/null | sed 's/.*: //'
  [ -x "$CXBIN/wine64" ] && { echo -n "wine64 arch:     "; file "$CXBIN/wine64" 2>/dev/null | sed 's/.*: //'; }
  echo "macOS:           $(sw_vers -productVersion 2>/dev/null)  ($(uname -m))"
  echo "CPU brand:       $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
  echo "Bottle:          $BOTTLE  ->  $BOTTLE_PATH"
  echo "Target:          $TARGET"
  echo "WINEDEBUG:       $WINEDEBUG"
  echo "Timeout:         ${TIMEOUT}s"
} | tee "$INV"
echo

# ---- help find the target if the default path is wrong ----------------------
if printf '%s' "$TARGET" | grep -qi 'GRYPHLINK'; then
  echo "Locating Endfield executables under the bottle (for reference)..."
  find "$BOTTLE_PATH/drive_c" \( -iname 'Launcher.exe' -o -iname 'Endfield.exe' -o -iname 'EM-Win64-Shipping.exe' \) 2>/dev/null \
    | sed 's/^/  found: /' | head -20
  echo "  (If the default target path is wrong, re-run with TARGET=... using one of the above,"
  echo "   converting the unix path to a C:/... windows path.)"
  echo
fi

# ---- best-effort macOS unified-log capture ---------------------------------
LOGPID=""
if command -v log >/dev/null 2>&1; then
  log stream --style compact \
    --predicate 'process CONTAINS "wine" OR process CONTAINS "Endfield" OR process CONTAINS "EM-Win64" OR process CONTAINS "ACE" OR eventMessage CONTAINS "Endfield"' \
    > "$MAC_LOG" 2>/dev/null &
  LOGPID=$!
fi

# ---- clean any lingering wine state for this prefix (best effort) -----------
WINEPREFIX="$BOTTLE_PATH" CX_ROOT="$CX_ROOT" "$CXBIN/wineserver" -k >/dev/null 2>&1 || true

# ---- launch -----------------------------------------------------------------
# CrossOver's bin/wine is a Perl wrapper that re-execs the real loader as a
# detached child, so a plain stderr redirect misses Wine's debug channels.
# CX_LOG routes ALL wine debug output to a file regardless of forking, and
# --wait-children keeps the wrapper attached until the game's children exit.
echo "Launching (up to ${TIMEOUT}s)... cxlog -> $CXLOG"
export WINEDEBUG
CX_LOG="$CXLOG" "$CXBIN/wine" --bottle "$BOTTLE" --wait-children --cx-app "$TARGET" > "$WINE_LOG" 2>&1 &
WINEPID=$!

elapsed=0
while kill -0 "$WINEPID" 2>/dev/null; do
  sleep 2; elapsed=$((elapsed + 2))
  if [ "$elapsed" -ge "$TIMEOUT" ]; then
    echo "[timeout ${TIMEOUT}s reached — stopping the process tree]"
    kill "$WINEPID" 2>/dev/null
    break
  fi
done
wait "$WINEPID" 2>/dev/null; STATUS=$?

# ---- teardown ---------------------------------------------------------------
[ -n "$LOGPID" ] && kill "$LOGPID" 2>/dev/null
WINEPREFIX="$BOTTLE_PATH" CX_ROOT="$CX_ROOT" "$CXBIN/wineserver" -k >/dev/null 2>&1 || true

# ---- collect any new macOS crash reports ------------------------------------
DIAG="$HOME/Library/Logs/DiagnosticReports"
CRASHES="$OUTDIR/crash-reports"
if [ -d "$DIAG" ]; then
  mkdir -p "$CRASHES"
  find "$DIAG" -type f -newer "$MARKER" \( -name '*.ips' -o -name '*.crash' \) 2>/dev/null \
    | grep -iE 'wine|Endfield|EM-Win64|ACE|Launcher|GRYPHLINK|preloader' \
    | while IFS= read -r f; do cp "$f" "$CRASHES/" 2>/dev/null; done
fi

# ---- classify ---------------------------------------------------------------
echo
echo "=================== FAILURE CLASSIFICATION ==================="
echo "wine exit status: $STATUS"
echo

# Prefer the CrossOver CX_LOG (has the real wine debug channels); fall back to wine.log.
SIGLOG="$CXLOG"; [ -s "$SIGLOG" ] || SIGLOG="$WINE_LOG"
echo "Primary log: $SIGLOG ($(wc -l < "$SIGLOG" 2>/dev/null | tr -d ' ') lines)"
echo

echo "--- did the game / ACE modules load? ---"
grep -oiE '(Endfield|EM-Win64-Shipping|ACE-|SGuard|sguard64|gsp_core|anticheat)[A-Za-z0-9_.-]*' "$SIGLOG" 2>/dev/null | sort -u | sed 's/^/  loaded-ish: /' | head -20
echo
echo "--- key failure signatures (grep) ---"
grep -nE 'unimplemented function|aborting|Call from|err:|unhandled|page fault|c0000|EXCEPTION|VirtualApple|wine: ' "$SIGLOG" 2>/dev/null | tail -n 60
echo

verdict="UNKNOWN — inspect $SIGLOG manually"
if grep -qE 'unimplemented function ntoskrnl\.exe' "$SIGLOG" 2>/dev/null; then
  fn="$(grep -oE 'unimplemented function ntoskrnl\.exe\.[A-Za-z0-9_]+' "$SIGLOG" | head -1)"
  verdict="FIXABLE — hit ${fn:-an ntoskrnl.exe function}. This is the em-backports family (docs/02). Proceed."
elif grep -qE 'unimplemented function msimg32\.dll\.AlphaBlend' "$SIGLOG" 2>/dev/null; then
  verdict="msimg32.dll.AlphaBlend abort — the documented Endfield abort (docs/01). Likely fixable; note it and proceed."
elif grep -qE 'unimplemented function' "$SIGLOG" 2>/dev/null; then
  fn="$(grep -oE 'unimplemented function [A-Za-z0-9_.]+' "$SIGLOG" | head -1)"
  verdict="FIXABLE — hit ${fn:-an unimplemented function}. Stub/implement it, then re-run."
elif grep -qE 'virtual_setup_exception stack overflow' "$SIGLOG" 2>/dev/null \
     && [ "$(grep -c 'code=c0000005' "$SIGLOG" 2>/dev/null)" -gt 20 ]; then
  verdict="PROTECTOR EXCEPTION LOOP — repeated EXCEPTION_ACCESS_VIOLATION (c0000005) re-entering the same SEH handler ('collided unwind') until stack overflow. Classic VMProtect/TenProtect (tpshell) anti-tamper failing under Wine's exception dispatch. This is the dw-proton int3/dispatcher problem CLASS (docs/02) — user-space fixable, NOT a kernel wall. See docs/10 (milestone 1). Next: launcher-path run + dw-proton mitigations."
elif [ -d "$CRASHES" ] && [ -n "$(ls -A "$CRASHES" 2>/dev/null)" ]; then
  verdict="Process CRASHED (macOS crash report captured, no unimplemented-function abort). Inspect crash-reports/ (risk #1, docs/08)."
elif grep -qiE 'ACE-|SGuard|anticheat|gsp_core' "$SIGLOG" 2>/dev/null; then
  verdict="ACE modules appear to load, then the process exits with no abort/crash. Likely a CATEGORICAL ACE force-quit (risk #1, docs/08) — the possible KILL signal. Inspect the last lines of $SIGLOG."
else
  verdict="No abort, no crash, no visible ACE module. Process may have exited early or been killed silently — inspect $SIGLOG and $MAC_LOG (and confirm the game is fully installed)."
fi

echo "VERDICT: $verdict"
echo
echo "--- last 15 lines of primary log ---"
tail -n 15 "$SIGLOG" 2>/dev/null
echo
echo "Artifacts saved to: $OUTDIR"
echo "  cxlog.txt        CrossOver CX_LOG — the real Wine debug channels (primary)"
echo "  wine.log         wrapper stdout/stderr (usually near-empty on CrossOver)"
echo "  macos-log.txt    macOS unified-log stream"
echo "  crash-reports/   any Endfield/ACE/wine crash reports from this run"
echo "  inventory.txt    environment inventory (milestone 0)"
echo
echo "Next: record the VERDICT in docs/09 milestone-1 notes. If FIXABLE, proceed to"
echo "milestone 2 (free spoofs) and milestone 3 (Linux bisect). If categorical force-quit, stop."
