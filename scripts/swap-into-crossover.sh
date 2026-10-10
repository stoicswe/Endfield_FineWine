#!/usr/bin/env bash
# swap-into-crossover.sh — build a patched CrossOver app for Arknights: Endfield.
#
# Produces /Applications/CrossOver_Endfield_Patch.app containing:
#   1. our patched Wine modules (the anti-cheat fixes — the reason the game runs at all)
#   2. GPTK4 / D3DMetal            (a REAL upgrade: stock CrossOver 26.3 ships D3DMetal 3.0 / GPTK3.
#                                   Point GPTK_DIR at Apple's GPTK4 redist to get D3DMetal 4. If your
#                                   SRC_APP already had GPTK4 installed, this step correctly no-ops.)
#   3. the latest MoltenVK          (optional; only used by Vulkan/DXVK/vkd3d paths, NOT by D3DMetal)
#
# Requires: /Applications/CrossOver.app at version 26.3 (ABI must match the build), and a completed
# build in build/wine-build64 (run scripts/build-wine.sh all first).
#
# Usage:
#   scripts/swap-into-crossover.sh                          # full app patch
#   scripts/swap-into-crossover.sh --help                   # all options
#   scripts/swap-into-crossover.sh --mod-chain --skip-app-patch --bottle "Arknights Endfield"
#   scripts/swap-into-crossover.sh --mod-chain-revert --skip-app-patch
#
# Every option also exists as an environment variable (see --help); a flag always wins over
# its env var.
#
# Env:
#   SRC_APP    (default /Applications/CrossOver.app)
#   DEST_APP   (default /Applications/CrossOver_Endfield_Patch.app)
#   BUNDLE_ID  (default com.codeweavers.CrossOvEF) — 25 chars matching stock CrossOver
#   GPTK_DIR   (default ~/Downloads/GPTK_4/redist/lib/external)  — set SKIP_GPTK=1 to skip
#   MVK_VER    (default 1.4.1)                                    — set SKIP_MVK=1 to skip
#
# Optional mod (EFMI) chain step — see docs/mod-injection/{07,08}*.md: points EFMI's d3dx.ini
# [System] proxy_d3d11 at the backend d3d11.dll inside the patched app, so 3DMigoto hands off to
# CrossOver's D3D11→Metal backend instead of Wine's wined3d (the default chain ends at wined3d).
#
# See docs/13-working-solution.md.

set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
B="$REPO/build/wine-build64"
SRC_APP="${SRC_APP:-/Applications/CrossOver.app}"
DEST_APP="${DEST_APP:-/Applications/CrossOver_Endfield_Patch.app}"
BUNDLE_ID="${BUNDLE_ID:-com.codeweavers.CrossOvEF}"
ORIG_BUNDLE_ID="com.codeweavers.CrossOver"
GPTK_DIR="${GPTK_DIR:-$HOME/Downloads/GPTK_4/redist/lib/external}"
MVK_VER="${MVK_VER:-1.4.1}"
WORK="${TMPDIR:-/tmp}/efw-swap.$$"
# The app is assembled and sealed here, then moved into place in one step: every modification
# happens on a fresh copy macOS has never registered, and a half-patched bundle is never visible
# in /Applications (App Management can also refuse edits inside an app that has been launched).
STAGE_ROOT="${TMPDIR:-/tmp}/efw-stage.$$"
STAGE="$STAGE_ROOT/$(basename "$DEST_APP")"
trap 'rm -rf "$STAGE_ROOT"' EXIT
log(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok(){  printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }

# --- optional mod (EFMI) chain step --------------------------------------------
MOD_CHAIN="${MOD_CHAIN:-0}"
MOD_CHAIN_REVERT="${MOD_CHAIN_REVERT:-0}"
MOD_BOTTLE="${MOD_BOTTLE:-Arknights Endfield}"
MOD_APP="${MOD_APP:-}"                     # resolved after the flags below are parsed
MOD_IMPORTER="${MOD_IMPORTER:-}"
MOD_CHAIN_MODE="${MOD_CHAIN_MODE:-path}"   # path | copy
MOD_BOTTLES_ROOT="${MOD_BOTTLES_ROOT:-$HOME/Library/Application Support/CrossOver/Bottles}"

# ---------------------------------------------------------------- CLI arguments
# Every flag overrides its environment-variable counterpart; --help has the full list.
usage(){
cat <<EOF
usage: scripts/swap-into-crossover.sh [options]

app patch (the Wine-module swap into a copy of CrossOver):
  --src-app PATH          CrossOver to copy (env SRC_APP; default /Applications/CrossOver.app)
  --dest-app PATH         where to write the patched copy (env DEST_APP;
                          default /Applications/CrossOver_Endfield_Patch.app)
  --bundle-id ID          bundle identifier (env BUNDLE_ID; default com.codeweavers.CrossOvEF)
  --gptk-dir PATH         Apple GPTK4 redist to install (env GPTK_DIR)
  --skip-gptk             don't touch GPTK4/D3DMetal (env SKIP_GPTK=1)
  --skip-mvk              don't refresh MoltenVK (env SKIP_MVK=1)

mod (EFMI) chain — see docs/mod-injection/:
  --mod-chain             point EFMI's d3dx.ini [System] proxy_d3d11 at the backend d3d11.dll
                          inside the patched app (env MOD_CHAIN=1)
  --mod-chain-revert      undo a previously applied chain (env MOD_CHAIN_REVERT=1)
  --bottle NAME           bottle to chain into (env MOD_BOTTLE; default "Arknights Endfield")
  --app PATH              patched app to chain against (env MOD_APP; default DEST_APP)
  --importer PATH         explicit EFMI folder (must contain d3dx.ini) instead of auto-discovery
                          (env MOD_IMPORTER)
  --chain-mode path|copy  "path": Z:\\ path into the app bundle (default). "copy": stage the
                          backend dll next to EFMI's as d3d11_cx.dll (env MOD_CHAIN_MODE)
  --bottles-root PATH     bottles directory (env MOD_BOTTLES_ROOT) — for scratch-bottle testing
  --skip-app-patch        run only the mod-chain step against an existing patched app
                          (env SKIP_APP_PATCH=1); requires --mod-chain or --mod-chain-revert

misc:
  -h, --help              this help
EOF
}
ARG_VALUE=""
arg_value(){ # $1 = option name, $2 = candidate value -> sets ARG_VALUE, or dies.
  # NB: called directly (NOT inside $(...)) so that `exit` below really stops the script.
  if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
    echo "ERROR: option '$1' needs a value (see --help)" >&2; exit 1
  fi
  case "$2" in
    -?*) echo "ERROR: option '$1' got '$2' which looks like another option (see --help)" >&2; exit 1 ;;
  esac
  ARG_VALUE="$2"
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mod-chain)           MOD_CHAIN=1; shift ;;
    --mod-chain-revert)    MOD_CHAIN_REVERT=1; shift ;;
    --skip-app-patch)      SKIP_APP_PATCH=1; shift ;;
    --skip-gptk)           SKIP_GPTK=1; shift ;;
    --skip-mvk)            SKIP_MVK=1; shift ;;
    --bottle)              arg_value "$1" "${2:-}"; MOD_BOTTLE="$ARG_VALUE"; shift 2 ;;
    --bottle=*)            MOD_BOTTLE="${1#*=}"; shift ;;
    --app)                 arg_value "$1" "${2:-}"; MOD_APP="$ARG_VALUE"; shift 2 ;;
    --app=*)               MOD_APP="${1#*=}"; shift ;;
    --importer)            arg_value "$1" "${2:-}"; MOD_IMPORTER="$ARG_VALUE"; shift 2 ;;
    --importer=*)          MOD_IMPORTER="${1#*=}"; shift ;;
    --chain-mode)          arg_value "$1" "${2:-}"; MOD_CHAIN_MODE="$ARG_VALUE"; shift 2 ;;
    --chain-mode=*)        MOD_CHAIN_MODE="${1#*=}"; shift ;;
    --bottles-root)        arg_value "$1" "${2:-}"; MOD_BOTTLES_ROOT="$ARG_VALUE"; shift 2 ;;
    --bottles-root=*)      MOD_BOTTLES_ROOT="${1#*=}"; shift ;;
    --src-app)             arg_value "$1" "${2:-}"; SRC_APP="$ARG_VALUE"; shift 2 ;;
    --src-app=*)           SRC_APP="${1#*=}"; shift ;;
    --dest-app)            arg_value "$1" "${2:-}"; DEST_APP="$ARG_VALUE"; shift 2 ;;
    --dest-app=*)          DEST_APP="${1#*=}"; shift ;;
    --bundle-id)           arg_value "$1" "${2:-}"; BUNDLE_ID="$ARG_VALUE"; shift 2 ;;
    --bundle-id=*)         BUNDLE_ID="${1#*=}"; shift ;;
    --gptk-dir)            arg_value "$1" "${2:-}"; GPTK_DIR="$ARG_VALUE"; shift 2 ;;
    --gptk-dir=*)          GPTK_DIR="${1#*=}"; shift ;;
    -h|--help)             usage; exit 0 ;;
    --)                    shift; break ;;
    -*)                    echo "ERROR: unknown option '$1' (see --help)" >&2; exit 1 ;;
    *)                     echo "ERROR: unexpected argument '$1' (see --help)" >&2; exit 1 ;;
  esac
done
case "$MOD_CHAIN_MODE" in
  path|copy) ;;
  *) echo "ERROR: --chain-mode must be 'path' or 'copy' (got '$MOD_CHAIN_MODE')" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------- preflight
DO_APP_PATCH=1
[ "${SKIP_APP_PATCH:-0}" = "1" ] && DO_APP_PATCH=0
if [ "$DO_APP_PATCH" = "0" ] && [ "$MOD_CHAIN" != "1" ] && [ "$MOD_CHAIN_REVERT" != "1" ]; then
  echo "ERROR: --skip-app-patch needs --mod-chain or --mod-chain-revert (nothing else to do)" >&2
  exit 1
fi
if [ "$DO_APP_PATCH" = "1" ]; then
  [ -d "$SRC_APP" ] || { echo "ERROR: $SRC_APP not found"; exit 1; }
  [ -f "$B/dlls/ntdll/ntdll.so" ] || { echo "ERROR: no build at $B — run scripts/build-wine.sh all first"; exit 1; }
  ver="$(defaults read "$SRC_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null)"
  [ "$ver" = "26.3" ] || warn "$SRC_APP is version '$ver', expected 26.3 — the Wine ABI must match the build."
  if [ -n "$MOD_APP" ] && [ "$MOD_APP" != "$DEST_APP" ]; then
    warn "--app points the mod chain at $MOD_APP while the patch will be created at $DEST_APP"
  fi
  [ -n "$MOD_APP" ] || MOD_APP="$DEST_APP"
else
  [ -n "$MOD_APP" ] || MOD_APP="$DEST_APP"
  [ -d "$MOD_APP/Contents/SharedSupport/CrossOver" ] \
    || { echo "ERROR: $MOD_APP is not a (patched) CrossOver app — pass --app <path to the patched app>"; exit 1; }
fi

# ---------------------------------------------------------------- 1. copy app
# Steps 1–6 are skipped entirely with SKIP_APP_PATCH=1 (e.g. to only run the mod
# chain step below against an already-patched app).
if [ "$DO_APP_PATCH" = "1" ]; then
log "Copying $SRC_APP -> $STAGE (staging)"
rm -rf "$STAGE_ROOT"; mkdir -p "$STAGE_ROOT"
# --noextattr: don't carry over Finder/iCloud xattrs (e.g. FinderInfo on a CrossOver.app that was
# unzipped inside an iCloud-synced folder) — codesign refuses to seal a bundle carrying them.
ditto --noextattr --noqtn "$SRC_APP" "$STAGE" || { echo "copy failed (permissions?)"; exit 1; }
CXR="$STAGE/Contents/SharedSupport/CrossOver"
ok "copied"

# ---------------------------------------------------------------- 2. patched Wine
log "Swapping in our patched Wine modules (the anti-cheat fixes)"
swap(){ # src  dst-rel
  local dst="$CXR/$2"
  # Move (not copy) the original aside so each swapped module is a fresh file: overwriting a Mach-O
  # in place can trip the kernel's per-vnode code-signature cache. PE modules need no signature of
  # their own (none do in stock CrossOver) — the bundle seal in step 5 covers them.
  mv -f "$dst" "$dst.cxorig" 2>/dev/null || true
  cp "$1" "$dst" && ok "$2"
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
fi
codesign --force --sign - "$NT" 2>/dev/null || { echo "ERROR: failed to ad-hoc sign ntdll.so"; exit 1; }
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
      # Replace rather than merge, so no stale D3DMetal 3.0 files linger inside the framework;
      # CrossOver's own copy is kept as external.cxorig. --noextattr/--noqtn: files from a
      # downloaded DMG carry quarantine/Finder xattrs that would break the bundle seal.
      rm -rf "$DEST_GPTK.cxorig"; mv "$DEST_GPTK" "$DEST_GPTK.cxorig"
      ditto --noextattr --noqtn "$GPTK_DIR/" "$DEST_GPTK/" && ok "installed GPTK4 D3DMetal"
      # Apple's signatures survive the copy; only fall back to ad-hoc if they don't verify
      codesign --verify "$DEST_GPTK/libd3dshared.dylib" 2>/dev/null \
        || codesign --force --sign - "$DEST_GPTK/libd3dshared.dylib" 2>/dev/null
      codesign --verify --deep --strict "$DEST_GPTK/D3DMetal.framework" 2>/dev/null \
        || codesign --force --deep --sign - "$DEST_GPTK/D3DMetal.framework" 2>/dev/null
    fi
  else warn "apple_gptk/external not found in this CrossOver — skipping"; fi
else
  warn "GPTK_DIR not found ($GPTK_DIR) — skipping. NOTE: stock CrossOver 26.3 ships D3DMetal 3.0; install Apple GPTK4 for D3DMetal 4."
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

# ---------------------------------------------------------------- 5. patch bundle ID & launcher seeds
log "Patching bundle ID ($BUNDLE_ID) & seed launcher helper archives"
[ "${#BUNDLE_ID}" -eq "${#ORIG_BUNDLE_ID}" ] || {
  echo "ERROR: BUNDLE_ID must be exactly ${#ORIG_BUNDLE_ID} characters (same length as $ORIG_BUNDLE_ID)"
  exit 1
}

# Update main Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$STAGE/Contents/Info.plist" 2>/dev/null \
  || defaults write "$STAGE/Contents/Info" CFBundleIdentifier "$BUNDLE_ID"
ok "CFBundleIdentifier -> $BUNDLE_ID"

# Patch seed launcher helper archives in Contents/Resources
for helper in "Menu Helper" "Bottle Helper"; do
  cpbz2="$STAGE/Contents/Resources/$helper.cpbz2"
  if [ -f "$cpbz2" ]; then
    hwork="${TMPDIR:-/tmp}/efw-hwork.$$.$RANDOM"
    mkdir -p "$hwork"
    (
      cd "$hwork"
      bzip2 -dc "$cpbz2" | cpio -idm 2>/dev/null
      if [ -f "Contents/Info.plist" ]; then
        sed -i '' "s/$ORIG_BUNDLE_ID/$BUNDLE_ID/g" "Contents/Info.plist" 2>/dev/null || true
      fi
      bin="Contents/MacOS/$helper"
      if [ -f "$bin" ]; then
        python3 -c "
with open('$bin', 'rb') as f: data = f.read()
target = b'$ORIG_BUNDLE_ID\x00'
rep = b'$BUNDLE_ID\x00'
if target in data:
    data = data.replace(target, rep)
    with open('$bin', 'wb') as f: f.write(data)
"
        codesign --force --sign - "$bin" 2>/dev/null || true
      fi
      find . | cpio -o -H odc 2>/dev/null | bzip2 -c > "$cpbz2.tmp"
      mv -f "$cpbz2.tmp" "$cpbz2"
    )
    rm -rf "$hwork"
    ok "patched $helper.cpbz2"
  fi
done

# ---------------------------------------------------------------- 6. sign / unquarantine
# Re-seal the outer bundle ad-hoc rather than just deleting its seal: when the copy carries a
# com.apple.provenance xattr (e.g. it was made from a shell spawned by a downloaded app instead
# of Terminal), macOS checks the bundle's signature at first exec, and a missing/broken seal gets
# every binary inside SIGKILLed with a '"CrossOver_Endfield_Patch" is damaged' dialog.
# No --deep: nested binaries keep CodeWeavers' signatures (wineloader/wineserver already carry
# disable-library-validation, so they load our ad-hoc ntdll.so). The main executable keeps its
# entitlements but drops the hardened runtime, whose library validation would reject
# CodeWeavers-signed frameworks under an ad-hoc signature.
log "Re-sealing the bundle with an ad-hoc signature so the modified files load"
xattr -drs com.apple.quarantine "$STAGE" 2>/dev/null || true
# codesign refuses to seal "detritus": even ditto --noextattr leaves a FinderInfo xattr on the
# bundle directory itself, and a CrossOver.app unzipped in an iCloud-synced folder carries more.
xattr -rd com.apple.FinderInfo "$STAGE" 2>/dev/null || true
xattr -rd com.apple.ResourceFork "$STAGE" 2>/dev/null || true
codesign --force --sign - --preserve-metadata=entitlements --timestamp=none "$STAGE" \
  || { echo "ERROR: codesign failed to re-seal the patched app"; exit 1; }
codesign --verify --deep --strict "$STAGE" \
  || { echo "ERROR: the patched app does not verify — macOS would report it as damaged"; exit 1; }
ok "bundle signature valid (ad-hoc)"

log "Installing -> $DEST_APP"
if [ -e "$DEST_APP" ]; then
  # App Management can refuse in-place deletion of an app that has already been launched;
  # fall back to moving it to the Trash (renaming the bundle itself is still allowed).
  rm -rf "$DEST_APP" 2>/dev/null || mv "$DEST_APP" "$HOME/.Trash/$(basename "$DEST_APP" .app)-$(date +%Y%m%d-%H%M%S).app" \
    || { echo "ERROR: can't remove the old $DEST_APP — move it to the Trash, then re-run"; exit 1; }
fi
mv "$STAGE" "$DEST_APP" || { echo "ERROR: couldn't move the patched app into place"; exit 1; }
CXR="$DEST_APP/Contents/SharedSupport/CrossOver"
ok "installed"

# ---------------------------------------------------------------- 7. verify
log "Verify"
echo "  bundle id:  $(plutil -extract CFBundleIdentifier raw "$DEST_APP/Contents/Info.plist" 2>/dev/null || defaults read "$DEST_APP/Contents/Info" CFBundleIdentifier 2>/dev/null)"
echo "  wineserver: $("$CXR/bin/wineserver" --version 2>&1 | head -1)"
for f in lib/wine/x86_64-unix/ntdll.so lib/wine/x86_64-windows/kernel32.dll lib/wine/x86_64-windows/ntoskrnl.exe; do
  printf '  %-42s %s bytes\n' "$(basename "$f")" "$(stat -f '%z' "$CXR/$f" 2>/dev/null)"
done
echo "  MoltenVK:   $(strings -a "$CXR/lib64/libMoltenVK.dylib" 2>/dev/null | grep -oE '^1\.[0-9]+\.[0-9]+$' | sort -u | head -1)"
echo "  D3DMetal:   $(plutil -extract CFBundleShortVersionString raw "$CXR/lib64/apple_gptk/external/D3DMetal.framework/Resources/Info.plist" 2>/dev/null)"

else
  CXR="$MOD_APP/Contents/SharedSupport/CrossOver"
  log "App patch skipped (SKIP_APP_PATCH=1) — operating on the existing $MOD_APP"
fi

# ---------------------------------------------------------------- 7. mod (EFMI) chain — optional
# Points EFMI's d3dx.ini [System] proxy_d3d11 at the *backend* d3d11.dll inside the patched app,
# so 3DMigoto hands off to CrossOver's D3D11→Metal backend instead of Wine's wined3d. Without it,
# 3DMigoto's default "original" resolution (C:\Windows\system32\d3d11.dll) ends at wined3d on
# every backend. Mechanism: docs/mod-injection/07-load-ordering-and-chaining.md
# Plan:       docs/mod-injection/08-patcher-integration-plan.md
mod_backend_rel(){ # backend -> d3d11.dll path relative to the CrossOver root
  case "$1" in
    d3dmetal) printf '%s' "lib64/apple_gptk/wine/x86_64-windows/d3d11.dll" ;;
    dxmt)     printf '%s' "lib/dxmt/x86_64-windows/d3d11.dll" ;;
    dxvk)     printf '%s' "lib/dxvk/x86_64-windows/d3d11.dll" ;;
    *)        return 1 ;;
  esac
}
mod_backend_from_conf(){ # $1 = cxbottle.conf  (active backend first, configured one as fallback)
  local v
  v=$(sed -n 's/.*"CX_ACTIVE_GRAPHICS_BACKEND"[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -1)
  [ -n "$v" ] || v=$(sed -n 's/.*"CX_GRAPHICS_BACKEND"[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -1)
  printf '%s' "$v"
}
mod_bottle_path(){ # mac path -> in-bottle windows path (drive Z:)
  printf 'Z:%s' "$(printf '%s' "$1" | tr / '\\')"
}
mod_find_efmi(){ # $1 = bottle root; prints the EFMI folder (mac path) or exits non-zero
  python3 - "$1" "${MOD_IMPORTER:-}" <<'PY'
import glob, json, os, sys
bp, override = sys.argv[1], sys.argv[2]
def win2mac(p):
    p = (p or "").strip().strip('"')
    if len(p) >= 2 and p[1] == ":":
        link = os.path.join(bp, "dosdevices", p[0].lower())
        rest = p[2:].replace("\\", "/").lstrip("/")
        if os.path.isdir(link):
            real = os.path.realpath(link)
            return os.path.normpath(os.path.join(real, rest) if rest else real)
    return ""
cands = []
if override:
    cands.append(override)
for cfg in glob.glob(os.path.join(bp, "drive_c", "users", "*", "AppData", "Roaming",
                                  "XXMI Launcher", "XXMI Launcher Config.json")):
    try:
        j = json.load(open(cfg, encoding="utf-8"))
        p = j.get("Importers", {}).get("EFMI", {}).get("Importer", {}).get("importer_path", "")
        m = win2mac(p)
        if m: cands.append(m)
    except Exception:
        pass
for d in glob.glob(os.path.join(bp, "drive_c", "users", "*", "AppData", "Roaming",
                                "XXMI Launcher", "EFMI")):
    cands.append(d)
for c in cands:
    if os.path.isfile(os.path.join(c, "d3dx.ini")):
        print(c); sys.exit(0)
sys.exit(1)
PY
}
# Edit ONLY the [System] section's proxy_d3d11 line (+ our marker). Everything else in the
# file stays byte-identical, including CRLF line endings (the split-on-\n trick keeps the
# trailing \r attached to each line).
#
# Normalising invariant: after this runs there is EXACTLY ONE active `proxy_d3d11` in [System]
# (ours), which makes re-runs true no-ops:
#   * commented example lines (;proxy_d3d11=...) are KEPT, ours goes right after the first one;
#   * any *active* proxy_d3d11 line is removed; the first one's text is printed to stdout as
#     "REPLACED=<line>" so the caller can record it for an exact revert;
#   * if the section has neither, ours is inserted right after the [System] header.
mod_edit_ini(){ # $1 = d3dx.ini  $2 = target  $3 = backend  $4 = short sha  -> prints REPLACED=<line>
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
path, target, backend, sha8 = sys.argv[1:5]
text = open(path, encoding="utf-8", newline="").read()   # newline="" keeps CRLF intact
lines = text.split("\n")          # a trailing "\r" (CRLF files) stays attached to each line
def core(s):  return s[:-1] if s.endswith("\r") else s
def tail(s):  return "\r" if s.endswith("\r") else ""
def kind(c):
    t = c.strip()
    commented = t.startswith(";")
    while t.startswith(";"):
        t = t[1:].lstrip()
    if not t.lower().startswith("proxy_d3d11"):
        return None
    rest = t[len("proxy_d3d11"):]
    if not (rest and (rest[0] == "=" or rest[0] in " \t")):
        return None
    return "commented" if commented else "active"
marker = "; FineWine chain: backend=%s target_sha256=%s" % (backend, sha8)
lines = [l for l in lines if not core(l).strip().startswith("; FineWine chain:")]
out, in_sys, replaced, replaced_at, first_example = [], False, "", None, None
for ln in lines:
    c = core(ln); s = c.strip()
    if s.lower().startswith("[system]"):
        in_sys = True
    elif s.startswith("[") and s.endswith("]"):
        in_sys = False
    if in_sys:
        k = kind(c)
        if k == "commented" and first_example is None:
            first_example = len(out)          # insert right after the documented example
        if k == "active":
            if replaced_at is None:
                val = c.split("=", 1)[1].strip() if "=" in c else ""
                if val.lower() != target.lower():
                    # a genuinely different (user-set) chain — remember it for the exact revert
                    replaced, replaced_at = c.strip(), len(out)
            continue                          # drop it — there must be exactly one active key
    out.append(ln)
if first_example is not None:
    at = first_example + 1
elif replaced_at is not None:
    at = replaced_at                           # put ours back where the replaced line was
else:
    hdr = next((i for i, l in enumerate(out) if core(l).strip().lower().startswith("[system]")), None)
    if hdr is None:
        print("ERROR: no [System] section in d3dx.ini", file=sys.stderr); sys.exit(1)
    at = hdr + 1
eol = tail(out[at - 1]) if at > 0 else ""
out[at:at] = ["proxy_d3d11 = " + target + eol, marker + eol]
open(path, "w", encoding="utf-8", newline="").write("\n".join(out))
print("REPLACED=" + replaced)
PY
}
# Undo ONLY the lines we added (proxy line + marker). If the apply replaced an active
# proxy_d3d11 line, $2 is its original text and it is re-inserted exactly where ours was.
# Falls back to the pre-chain backup when XXMI has since rewritten d3dx.ini (marker gone).
mod_unedit_ini(){ # $1 = d3dx.ini  [$2 = original line to re-insert]
  python3 - "$1" "${2:-}" <<'PY'
import re, sys
path, reinsert = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8", newline="").read()   # newline="" keeps CRLF intact
lines = text.split("\n")
def core(s):  return s[:-1] if s.endswith("\r") else s
def tail(s):  return "\r" if s.endswith("\r") else ""
def is_proxy(c):
    t = c.strip()
    while t.startswith(";"):
        t = t[1:].lstrip()
    if not t.lower().startswith("proxy_d3d11"):
        return False
    rest = t[len("proxy_d3d11"):]
    return bool(rest) and (rest[0] == "=" or rest[0] in " \t")
out, i, removed, insert_at, insert_tail = [], 0, 0, None, ""
while i < len(lines):
    c = core(lines[i])
    if c.strip().startswith("; FineWine chain:"):
        removed += 1; i += 1; continue
    if is_proxy(c) and i + 1 < len(lines) and core(lines[i+1]).strip().startswith("; FineWine chain:"):
        if insert_at is None:
            insert_at, insert_tail = len(out), tail(c)
        removed += 2; i += 2; continue
    out.append(lines[i]); i += 1
if removed == 0:
    print("no chain lines found", file=sys.stderr); sys.exit(1)
if reinsert:
    out.insert(insert_at if insert_at is not None else len(out), reinsert + insert_tail)
open(path, "w", encoding="utf-8", newline="").write("\n".join(out))
PY
}
mod_chain_apply(){
  local BP="$MOD_BOTTLES_ROOT/$MOD_BOTTLE" backend rel src importer ini sha target mode
  BP="${BP%\/}"
  [ -f "$BP/cxbottle.conf" ] || { echo "ERROR: bottle '$MOD_BOTTLE' not found at $BP (set MOD_BOTTLE or MOD_BOTTLES_ROOT)"; exit 1; }
  log "Mod chain: bottle '$MOD_BOTTLE'"
  backend="$(mod_backend_from_conf "$BP/cxbottle.conf")"
  if ! rel="$(mod_backend_rel "$backend")"; then
    ok "backend '${backend:-none}' (wined3d) already IS the system d3d11 — no chain needed, skipping"
    return 0
  fi
  src="$CXR/$rel"
  [ -f "$src" ] || { echo "ERROR: the backend d3d11.dll is missing from the patched app: $src"; exit 1; }
  importer="$(mod_find_efmi "$BP")" \
    || { echo "ERROR: could not locate the EFMI folder (no XXMI Launcher config and no default EFMI dir with d3dx.ini). Set MOD_IMPORTER=<path to the EFMI folder>."; exit 1; }
  ini="$importer/d3dx.ini"
  sha="$(shasum -a 256 "$src" | cut -d' ' -f1)"
  if [ "$MOD_CHAIN_MODE" = "copy" ] || [ "$(readlink "$BP/dosdevices/z:" 2>/dev/null)" != "/" ]; then
    [ "$(readlink "$BP/dosdevices/z:" 2>/dev/null)" = "/" ] \
      || warn "bottle dosdevices/z: does not map to / — falling back to copy mode"
    mode="copy"
    cp -f "$src" "$importer/d3d11_cx.dll"
    target="d3d11_cx.dll"
    ok "staged the backend d3d11.dll next to EFMI (d3d11_cx.dll, sha256 ${sha:0:12}…)"
  else
    mode="path"
    target="$(mod_bottle_path "$src")"
    ok "target: $target"
  fi
  [ -f "$ini.cxorig" ] || cp -p "$ini" "$ini.cxorig"
  local replaced
  replaced="$(mod_edit_ini "$ini" "$target" "$backend" "${sha:0:12}")" || { echo "ERROR: failed to edit $ini"; exit 1; }
  replaced="${replaced#REPLACED=}"
  grep -F "proxy_d3d11 = $target" "$ini" >/dev/null && grep -F "FineWine chain: backend=$backend" "$ini" >/dev/null \
    || { echo "ERROR: $ini does not contain the chain after editing"; exit 1; }
  {
    printf 'app_path = %s\n' "$MOD_APP"
    printf 'backend = %s\n' "$backend"
    printf 'mode = %s\n' "$mode"
    printf 'target = %s\n' "$target"
    printf 'target_sha256 = %s\n' "$sha"
    printf 'applied_at = %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    [ -n "$replaced" ] && printf 'replaced_line = %s\n' "$replaced"
  } > "$importer/d3dx.ini.finewine-chain"
  ok "wrote $importer/d3dx.ini.finewine-chain"
  cat <<EOF3

Mod chain applied -> $ini
  backend : $backend
  target  : $target

Verify it works: launch Endfield via XXMI, then check "$importer/d3d11_log.txt" for
  "Proxy loading active, Forcing load_library_redirect=0"
(experiments L1–L5 in docs/mod-injection/06-experiment-plan.md).

Note: XXMI rewrites d3dx.ini when it updates EFMI (overwrite_ini=True). If the chain
disappears after an update, re-run this step (MOD_CHAIN=1) or disable "overwrite ini"
in XXMI's settings.
EOF3
}
mod_chain_revert(){
  local BP="$MOD_BOTTLES_ROOT/$MOD_BOTTLE" importer ini
  [ -f "$BP/cxbottle.conf" ] || { echo "ERROR: bottle '$MOD_BOTTLE' not found at $BP"; exit 1; }
  importer="$(mod_find_efmi "$BP")" \
    || { echo "ERROR: could not locate the EFMI folder. Set MOD_IMPORTER=<path to the EFMI folder>."; exit 1; }
  ini="$importer/d3dx.ini"
  log "Mod chain revert: $ini"
  if grep -F "FineWine chain:" "$ini" >/dev/null 2>&1; then
    local replaced=""
    if [ -f "$importer/d3dx.ini.finewine-chain" ]; then
      replaced="$(sed -n 's/^replaced_line = //p' "$importer/d3dx.ini.finewine-chain")"
    fi
    mod_unedit_ini "$ini" "$replaced" && ok "removed the chain lines from d3dx.ini"
  elif [ -f "$ini.cxorig" ]; then
    warn "no FineWine marker in d3dx.ini (rewritten by XXMI?) — restoring the pre-chain backup instead"
    cp -p "$ini.cxorig" "$ini"
  else
    warn "nothing to revert (no marker, no backup)"; return 0
  fi
  rm -f "$importer/d3d11_cx.dll" "$importer/d3dx.ini.finewine-chain"
  ok "reverted (pre-chain backup kept at $ini.cxorig)"
}
if [ "${MOD_CHAIN_REVERT:-0}" = "1" ]; then
  mod_chain_revert
elif [ "${MOD_CHAIN:-0}" = "1" ]; then
  mod_chain_apply
fi

cat <<EOF

Done -> $DEST_APP

Next:
  1. First time only: create the bottle with scripts/create-bottle.sh, then install the Gryphline
     launcher into it and let it download Endfield (README → "Before the first launch").
  2. Start the game from the launcher with the dropdown next to Start → "Launch with DirectX 11".
     DX12 does NOT work for this game (white screen); Vulkan is experimental, see
     docs/graphics-performance.md.
  3. See docs/13-working-solution.md for troubleshooting.

Optional — mods (XXMI / EFMI): install XXMI Launcher + EFMI inside the bottle, then run
  scripts/swap-into-crossover.sh --mod-chain --skip-app-patch --bottle "Arknights Endfield"
to chain EFMI's d3d11.dll onto this app's D3D11→Metal backend (see docs/mod-injection/).
EOF
