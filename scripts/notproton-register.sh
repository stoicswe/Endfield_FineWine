#!/bin/bash
# notproton-register.sh — register a FineWine-patched CrossOver as a NotProton runner.
#
# This places the patched CrossOver into NotProton's runners directory so it appears as a
# separate Steam Play compatibility tool. Steam's per-game Compatibility selector will show
# an "Endfield FineWine" entry alongside the stock CrossOver versions.
#
# The STANDALONE workflow (scripts/swap-into-crossover.sh + scripts/launch-endfield.sh) is
# NOT affected. This is an additional, parallel integration for users who want to launch
# Endfield directly from their Steam library.
#
# How it works
# ────────────
# NotProton discovers CrossOver runners in:
#   ~/Library/Application Support/notproton/runners/crossover-<build>/CrossOver/
# and exposes them to Steam via compatibility-tool entries in:
#   ~/Library/Application Support/Steam/compatibilitytools.d/
#
# This script:
#   1. Copies the FineWine-patched CrossOver into that runners directory under a unique name.
#   2. Creates a Steam compatibility-tool entry with its own `run` script, so Steam can launch
#      games through the patched runner (inheriting all anti-cheat + Rosetta fixes).
#   3. Optionally applies NotProton's ntdll binary patch so lsteamclient loads (Steam overlay).
#
# Usage:
#   scripts/notproton-register.sh                       # auto-detect everything
#   scripts/notproton-register.sh --help                # all options
#   scripts/notproton-register.sh --app /path/to/CrossOver_Endfield_Patch.app
#   scripts/notproton-register.sh --unregister          # remove the FineWine tool entry
#
# Env:
#   APP           patched CrossOver app (default: auto-detect by bundle id)
#   BUILD_NAME    runner name (default: finewine-26.3)
#   DISPLAY_NAME  label in Steam's dropdown (default: "CrossOver 26.3 - Endfield FineWine - Rosetta")
#   FLAVOR        rosetta | fex (default: rosetta — FineWine builds are x86_64)
#   TOOL_NAME     Steam tool identifier (default: notproton-finewine-rosetta)
#   NP_SUPPORT    NotProton support dir (default: ~/Library/Application Support/notproton)
#   STEAM_ROOT    Steam dir (default: ~/Library/Application Support/Steam)
#
# Prerequisites:
#   - NotProton installed (https://github.com/NotProtonNot/NotProton)
#   - A FineWine-patched CrossOver (scripts/swap-into-crossover.sh or Patcher.app)
#   - Steam for macOS
#
# See docs/notproton.md for the full guide.

set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"

# ── UI helpers ──────────────────────────────────────────────────────────────────
log(){  printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok(){   printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }
die(){  printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ── defaults ────────────────────────────────────────────────────────────────────
BUNDLE_ID="${BUNDLE_ID:-com.codeweavers.CrossOvEF}"
APP="${APP:-}"
BUILD_NAME="${BUILD_NAME:-finewine-26.3}"
DISPLAY_NAME="${DISPLAY_NAME:-CrossOver 26.3 - Endfield FineWine - Rosetta}"
FLAVOR="${FLAVOR:-rosetta}"
TOOL_NAME="${TOOL_NAME:-notproton-finewine-rosetta}"
NP_SUPPORT="${NP_SUPPORT:-$HOME/Library/Application Support/notproton}"
STEAM_ROOT="${STEAM_ROOT:-$HOME/Library/Application Support/Steam}"
UNREGISTER=0

# ── CLI ─────────────────────────────────────────────────────────────────────────
usage(){
cat <<EOF
usage: scripts/notproton-register.sh [options]

  --app PATH            FineWine-patched CrossOver app (default: auto-detect)
  --build-name NAME     runner name under notproton/runners/ (default: $BUILD_NAME)
  --display-name NAME   label shown in Steam's Compatibility dropdown (default: "$DISPLAY_NAME")
  --flavor rosetta|fex  Wine architecture (default: $FLAVOR)
  --tool-name NAME      Steam tool identifier (default: $TOOL_NAME)
  --np-support PATH     NotProton support directory (default: ~/Library/Application Support/notproton)
  --steam-root PATH     Steam directory (default: ~/Library/Application Support/Steam)
  --unregister          remove the FineWine tool entry and runner
  -h, --help            this help
EOF
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app)           APP="$2"; shift 2 ;;
    --app=*)         APP="${1#*=}"; shift ;;
    --build-name)    BUILD_NAME="$2"; shift 2 ;;
    --build-name=*)  BUILD_NAME="${1#*=}"; shift ;;
    --display-name)  DISPLAY_NAME="$2"; shift 2 ;;
    --display-name=*) DISPLAY_NAME="${1#*=}"; shift ;;
    --flavor)        FLAVOR="$2"; shift 2 ;;
    --flavor=*)      FLAVOR="${1#*=}"; shift ;;
    --tool-name)     TOOL_NAME="$2"; shift 2 ;;
    --tool-name=*)   TOOL_NAME="${1#*=}"; shift ;;
    --np-support)    NP_SUPPORT="$2"; shift 2 ;;
    --np-support=*)  NP_SUPPORT="${1#*=}"; shift ;;
    --steam-root)    STEAM_ROOT="$2"; shift 2 ;;
    --steam-root=*)  STEAM_ROOT="${1#*=}"; shift ;;
    --unregister)    UNREGISTER=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "unknown option '$1' (see --help)" ;;
  esac
done

case "$FLAVOR" in rosetta|fex) ;; *) die "FLAVOR must be 'rosetta' or 'fex' (got '$FLAVOR')" ;; esac

RUNNER_DIR="$NP_SUPPORT/runners/crossover-$BUILD_NAME"
COMPAT_DIR="$STEAM_ROOT/compatibilitytools.d"
TOOL_DIR="$COMPAT_DIR/$TOOL_NAME"

# ── unregister ──────────────────────────────────────────────────────────────────
if [ "$UNREGISTER" = "1" ]; then
  log "Unregistering FineWine from NotProton"
  removed=0
  if [ -d "$TOOL_DIR" ]; then
    rm -rf "$TOOL_DIR"
    ok "removed tool entry: $TOOL_DIR"
    removed=1
  fi
  if [ -d "$RUNNER_DIR" ]; then
    rm -rf "$RUNNER_DIR"
    ok "removed runner: $RUNNER_DIR"
    removed=1
  fi
  # Clean up tools file entry
  tools_file="$NP_SUPPORT/tools"
  if [ -f "$tools_file" ] && grep -qF "$BUILD_NAME" "$tools_file" 2>/dev/null; then
    grep -vF "$BUILD_NAME" "$tools_file" > "$tools_file.tmp" && mv -f "$tools_file.tmp" "$tools_file"
    ok "removed from tools manifest"
    removed=1
  fi
  if [ "$removed" = "0" ]; then
    warn "nothing to remove (FineWine is not registered)"
  else
    echo ""
    echo "Done. Restart Steam for the change to take effect."
  fi
  exit 0
fi

# ── preflight ───────────────────────────────────────────────────────────────────
log "Checking prerequisites"

# 1. NotProton
if [ ! -d "$NP_SUPPORT" ]; then
  warn "NotProton directory not found at $NP_SUPPORT — creating it."
  warn "Make sure NotProton is installed: https://github.com/NotProtonNot/NotProton"
  mkdir -p "$NP_SUPPORT"
fi
ok "NotProton directory: $NP_SUPPORT"

# 2. Steam
if [ ! -d "$STEAM_ROOT" ]; then
  warn "Steam directory not found at $STEAM_ROOT — creating compatibility tools directory anyway."
  mkdir -p "$STEAM_ROOT/compatibilitytools.d"
fi
ok "Steam directory: $STEAM_ROOT"

# 3. Find the FineWine-patched CrossOver
bundle_id_of(){ plutil -extract CFBundleIdentifier raw "$1/Contents/Info.plist" 2>/dev/null \
                || defaults read "$1/Contents/Info" CFBundleIdentifier 2>/dev/null; }
is_cx_app(){ [ -d "$1/Contents/SharedSupport/CrossOver/bin" ] && [ -x "$1/Contents/SharedSupport/CrossOver/bin/wine" ]; }

if [ -z "$APP" ]; then
  # Try mdfind first (fast)
  if command -v mdfind >/dev/null 2>&1; then
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      if [ "$(bundle_id_of "$c")" = "$BUNDLE_ID" ] && is_cx_app "$c"; then
        APP="$c"; break
      fi
    done < <(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null)
  fi
  # Fallback: scan known locations
  if [ -z "$APP" ]; then
    for c in "/Applications/CrossOver_Endfield_Patch.app" \
             "$HOME/Applications/CrossOver_Endfield_Patch.app"; do
      if [ -d "$c" ] && is_cx_app "$c"; then APP="$c"; break; fi
    done
  fi
fi
[ -d "$APP" ] || die "FineWine-patched CrossOver not found. Build it first (scripts/swap-into-crossover.sh) or pass --app PATH"
is_cx_app "$APP" || die "$APP is not a CrossOver app"
CXR="$APP/Contents/SharedSupport/CrossOver"
ok "patched CrossOver: $APP"

# Verify it has our patched modules
for f in lib/wine/x86_64-unix/ntdll.so lib/wine/x86_64-windows/kernel32.dll lib/wine/x86_64-windows/ntoskrnl.exe; do
  [ -f "$CXR/$f" ] || die "patched module missing: $f — is this a FineWine-patched CrossOver?"
done
ok "patched Wine modules present"

# 4. Find an existing NotProton run script to copy
np_run_script=""
if [ -d "$COMPAT_DIR" ]; then
  for d in "$COMPAT_DIR"/notproton-* "$COMPAT_DIR"/notproton; do
    if [ -f "$d/run" ] && [ -x "$d/run" ]; then
      np_run_script="$d/run"
      break
    fi
  done
fi
# Also check inside subdirectories (NotProton groups tools under a parent dir)
if [ -z "$np_run_script" ] && [ -d "$COMPAT_DIR/notproton" ]; then
  for d in "$COMPAT_DIR/notproton"/*/; do
    if [ -f "${d}run" ] && [ -x "${d}run" ]; then
      np_run_script="${d}run"
      break
    fi
  done
fi

# ── 1. stage the runner ────────────────────────────────────────────────────────
log "Staging runner: crossover-$BUILD_NAME"
if [ -d "$RUNNER_DIR/CrossOver" ]; then
  warn "runner already exists — replacing"
  rm -rf "$RUNNER_DIR"
fi
mkdir -p "$RUNNER_DIR"

# Copy the full CrossOver support tree. This is everything Wine, D3DMetal, MoltenVK,
# cxbottle, DXMT, etc. — including our patched anti-cheat modules.
# ditto is used for efficient macOS copies (preserves resource forks, permissions).
ditto --noextattr --noqtn "$CXR" "$RUNNER_DIR/CrossOver" \
  || die "failed to copy CrossOver to $RUNNER_DIR/CrossOver"
ok "copied CrossOver internals ($(du -sh "$RUNNER_DIR/CrossOver" | cut -f1))"

# Verify critical executables are present and functional
for f in bin/wine bin/wineserver lib/wine/x86_64-unix/ntdll.so; do
  [ -f "$RUNNER_DIR/CrossOver/$f" ] || die "critical file missing after copy: $f"
done
ok "runner verified"

# ── 2. create the Steam compatibility tool entry ───────────────────────────────
log "Creating Steam compatibility tool: $TOOL_NAME"
mkdir -p "$TOOL_DIR"

# Write the build name (compat_run.sh reads this to locate the runner)
printf '%s\n' "$BUILD_NAME" > "$TOOL_DIR/build"

# Write the flavor (rosetta or fex)
printf '%s\n' "$FLAVOR" > "$TOOL_DIR/flavor"

# Write toolmanifest.vdf — tells Steam how to invoke the tool
cat > "$TOOL_DIR/toolmanifest.vdf" <<'VDF'
"manifest"
{
  "version" "2"
  "commandline" "/run %verb%"
}
VDF
ok "toolmanifest.vdf"

# Write compatibilitytool.vdf — tells Steam this tool exists and what it converts
cat > "$TOOL_DIR/compatibilitytool.vdf" <<VDF
"compatibilitytools"
{
  "compat_tools"
  {
    "$TOOL_NAME"
    {
      "install_path" "."
      "display_name" "$DISPLAY_NAME"
      "from_oslist" "windows"
      "to_oslist" "macos"
    }
  }
}
VDF
ok "compatibilitytool.vdf → \"$DISPLAY_NAME\""

# Write the run script. If NotProton has an existing one, use it (preferred — it
# handles all Steam integration, prefix management, lsteamclient, and the full
# compatibility shim). Otherwise, write a self-contained run script that provides
# the essential Steam → Wine bridge.
if [ -n "$np_run_script" ]; then
  cp "$np_run_script" "$TOOL_DIR/run"
  chmod +x "$TOOL_DIR/run"
  ok "run script (copied from existing NotProton tool)"
else
  warn "no existing NotProton run script found — writing a standalone bridge script"
  warn "this script provides basic Steam → Wine bridging; install NotProton for full integration"
  cat > "$TOOL_DIR/run" <<'RUNSCRIPT'
#!/bin/sh
# FineWine Steam compatibility tool — run script.
#
# A standalone bridge that lets Steam launch Windows games through the
# FineWine-patched CrossOver. For full integration (prefix management,
# Steam overlay, lsteamclient), install NotProton and re-register.
set -e

verb="$1"
shift || true

case "$verb" in
  getcompatpath)
    printf '%s\n' "$STEAM_COMPAT_DATA_PATH"
    exit 0
    ;;
esac

# cxcompatdb resolves its database through CX_HOME.
export CX_HOME="$HOME/Library/Application Support/CrossOver"
np_support="$HOME/Library/Application Support/notproton"

CDPATH=''
np_tool_dir=$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || np_tool_dir=""
np_build=""
np_flavor=""
if [ -n "$np_tool_dir" ] && [ -r "$np_tool_dir/build" ]; then
  read -r np_build < "$np_tool_dir/build" || np_build=""
fi
if [ -n "$np_tool_dir" ] && [ -r "$np_tool_dir/flavor" ]; then
  read -r np_flavor < "$np_tool_dir/flavor" || np_flavor=""
fi

CX_ROOT="$np_support/runners/crossover-$np_build/CrossOver"
export CX_ROOT

# GPTK / D3DMetal shared library
if [ -f "$CX_ROOT/lib64/apple_gptk/external/libd3dshared.dylib" ]; then
  export CX_APPLEGPTK_LIBD3DSHARED_PATH="$CX_ROOT/lib64/apple_gptk/external/libd3dshared.dylib"
fi

# Select wine loader and server based on flavor
wine_unix="$CX_ROOT/lib/wine/aarch64-unix"
WINELOADER="$wine_unix/wine.app/Contents/MacOS/wine"
WINESERVER="$CX_ROOT/bin/wineserver-arm64"
if [ "$np_flavor" = rosetta ] || [ ! -x "$WINELOADER" ] || [ ! -x "$WINESERVER" ]; then
  wine_unix="$CX_ROOT/lib/wine/x86_64-unix"
  WINELOADER="$wine_unix/wine"
  WINESERVER="$CX_ROOT/bin/wineserver"
  [ -x "$WINESERVER" ] || WINESERVER="$CX_ROOT/bin/wineserver-x86"
fi
export WINELOADER WINESERVER

export WINEDLLPATH="$CX_ROOT/lib/wine/x86_64-windows:$wine_unix${WINEDLLPATH:+:$WINEDLLPATH}"
export PATH="$CX_ROOT/bin:$PATH"

# Rosetta AVX advertisement (CrossOver sets this too)
export ROSETTA_ADVERTISE_AVX="${ROSETTA_ADVERTISE_AVX:-1}"

# SteamAppId / SteamGameId
case "$verb" in
  waitforexitandrun)
    app_id="${STEAM_COMPAT_APP_ID:-}"
    case "$app_id" in ''|0) app_id="${SteamAppId:-}" ;; esac
    [ -n "${SteamAppId:-}" ] || export SteamAppId="$app_id"
    [ -n "${SteamGameId:-}" ] || export SteamGameId="$app_id"
    ;;
esac

# Log file
log=/dev/null
if [ -n "${STEAM_COMPAT_DATA_PATH:-}" ]; then
  log="$STEAM_COMPAT_DATA_PATH/finewine-run.log"
fi
{
  echo "=== finewine run $(date) ==="
  echo "verb=$verb"
  echo "CX_ROOT=$CX_ROOT"
  echo "WINELOADER=$WINELOADER"
  echo "STEAM_COMPAT_DATA_PATH=${STEAM_COMPAT_DATA_PATH:-}"
  echo "args:"; for a in "$@"; do printf '  [%s]\n' "$a"; done
} >> "$log" 2>&1 || true

# Set up prefix directory
if [ -n "${STEAM_COMPAT_DATA_PATH:-}" ]; then
  export WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx"
  mkdir -p "$WINEPREFIX"
fi

case "$verb" in
  run|waitforexitandrun)
    # Kill stale wineserver so anti-cheat starts fresh
    "$WINESERVER" -k > /dev/null 2>&1 || true
    sleep 1

    # Launch the game
    "$WINELOADER" "$@" >> "$log" 2>&1
    ;;
  *)
    # Other verbs (getcompatpath handled above)
    "$WINELOADER" "$@" >> "$log" 2>&1 || true
    ;;
esac
RUNSCRIPT
  chmod +x "$TOOL_DIR/run"
  ok "run script (standalone bridge)"
fi

# ── 3. register in NotProton's tools manifest ──────────────────────────────────
log "Registering in NotProton tools manifest"
tools_file="$NP_SUPPORT/tools"
if [ -f "$tools_file" ]; then
  # Remove any previous FineWine entry
  if grep -qF "$BUILD_NAME" "$tools_file" 2>/dev/null; then
    grep -vF "$BUILD_NAME" "$tools_file" > "$tools_file.tmp" && mv -f "$tools_file.tmp" "$tools_file"
    ok "removed previous entry"
  fi
  # Append our entry.
  # Format: <tool_name>\t<build>\t<flavor>\t<display_name>  (tab-separated)
  printf '%s\t%s\t%s\t%s\n' "$TOOL_NAME" "$BUILD_NAME" "$FLAVOR" "$DISPLAY_NAME" >> "$tools_file"
  ok "added to $tools_file"
else
  warn "tools file not found — NotProton will still discover the runner, but won't show it in its own UI until restarted"
fi

# ── 4. attempt NotProton's ntdll binary patch (optional) ───────────────────────
log "NotProton ntdll-patch (for lsteamclient / Steam overlay)"
np_apply="$NP_SUPPORT/ntdll-patch"
runner_ntdll="$RUNNER_DIR/CrossOver/lib/wine/x86_64-unix/ntdll.so"
if [ -x "$np_apply" ] && [ -f "$runner_ntdll" ]; then
  if "$np_apply" "$runner_ntdll" > /dev/null 2>&1; then
    # Re-sign after patching
    codesign --force --sign - "$runner_ntdll" 2>/dev/null || true
    ok "ntdll binary patch applied → lsteamclient will load (Steam overlay works)"
  else
    warn "ntdll binary patch failed (byte patterns differ in our rebuilt ntdll.so)"
    warn "Steam overlay / lsteamclient won't load, but the game itself works fine"
    warn "this is expected — FineWine's ntdll.so is rebuilt from source"
  fi
elif [ -d "$NP_SUPPORT" ]; then
  # Look for the patch tool in alternate locations
  found_patch=0
  for cand in "$NP_SUPPORT/ntdll-patch/apply.py" "$NP_SUPPORT/ntdll-apply"; do
    if [ -f "$cand" ]; then
      if python3 "$cand" "$runner_ntdll" > /dev/null 2>&1; then
        codesign --force --sign - "$runner_ntdll" 2>/dev/null || true
        ok "ntdll binary patch applied via $cand"
        found_patch=1
      else
        warn "ntdll patch at $cand failed (byte pattern mismatch with our rebuilt ntdll.so)"
      fi
      break
    fi
  done
  if [ "$found_patch" = "0" ]; then
    warn "NotProton's ntdll-patch tool not found — Steam overlay won't be available"
    warn "the game launches and plays normally without it"
  fi
fi

# ── 5. create FineWine-specific defaults ───────────────────────────────────────
# Set Endfield-optimal defaults for this runner (users can override in Steam launch options)
defaults_file="$NP_SUPPORT/defaults-override-$BUILD_NAME-rosetta"
if [ ! -f "$defaults_file" ]; then
  cat > "$defaults_file" <<'DEFAULTS'
CX_GRAPHICS_BACKEND=d3dmetal
D3DM_ENABLE_METALFX=1
WINEMSYNC=1
ROSETTA_ADVERTISE_AVX=1
DEFAULTS
  ok "wrote Endfield-optimal defaults → $defaults_file"
else
  ok "defaults file already exists — not overwritten"
fi

# ── 6. verify & print summary ──────────────────────────────────────────────────
log "Verify"
echo "  tool name:    $TOOL_NAME"
echo "  display name: $DISPLAY_NAME"
echo "  build:        $BUILD_NAME"
echo "  flavor:       $FLAVOR"
echo "  runner:       $RUNNER_DIR/CrossOver/"
echo "  tool dir:     $TOOL_DIR/"
echo "  wineserver:   $("$RUNNER_DIR/CrossOver/bin/wineserver" --version 2>&1 | head -1)"
for f in lib/wine/x86_64-unix/ntdll.so lib/wine/x86_64-windows/kernel32.dll lib/wine/x86_64-windows/ntoskrnl.exe; do
  printf '  %-42s %s bytes\n' "$(basename "$f")" "$(stat -f '%z' "$RUNNER_DIR/CrossOver/$f" 2>/dev/null)"
done
gptk_ver="$(plutil -extract CFBundleShortVersionString raw "$RUNNER_DIR/CrossOver/lib64/apple_gptk/external/D3DMetal.framework/Resources/Info.plist" 2>/dev/null || echo "not installed")"
echo "  D3DMetal:     $gptk_ver"

cat <<EOF

Done → "$DISPLAY_NAME" is now available as a Steam Play compatibility tool.

Next steps:
  1. Restart Steam (quit and reopen).
  2. In Steam → Settings → Compatibility, you can set this as the default tool, or:
  3. Right-click Arknights: Endfield → Properties → Compatibility →
     "Force the use of a specific Steam Play compatibility tool" →
     select "$DISPLAY_NAME".
  4. Add  -force-d3d11  to the game's Launch Options (Properties → General)
     for the best graphics path (DX12 doesn't work; Vulkan is also supported).
  5. Launch the game from Steam.

Standalone mode (scripts/launch-endfield.sh) still works independently.
See docs/notproton.md for the full guide and troubleshooting.
EOF
