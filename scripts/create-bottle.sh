#!/usr/bin/env bash
# create-bottle.sh — create the CrossOver bottle Arknights: Endfield runs in, configured the way
# this project's working setup uses it (or re-apply that configuration to an existing bottle).
#
# GUI equivalent: CrossOver → New bottle (Windows 11 64-bit), then the bottle's Advanced Settings:
# Graphics = D3DMetal, DLSS = on, MSync = on. (Leave High Resolution Mode off — the game renders a
# white screen with it.)
#
# Usage:
#   scripts/create-bottle.sh            # create the bottle (an existing bottle is left untouched)
#   UPDATE=1 scripts/create-bottle.sh   # re-apply the settings to an existing bottle
#
# Env:
#   BOTTLE   (default "Arknights Endfield" — the name the other scripts expect)
#   BACKEND  (default d3dmetal; one of d3dmetal | dxmt | dxvk | wined3d)
#   APP      (CrossOver app whose tools to use; default: the patched copy, else /Applications/CrossOver.app)
#
# The settings are [EnvironmentVariables] keys in the bottle's cxbottle.conf — the same keys the
# CrossOver 26 GUI writes (see docs/06):
#   CX_GRAPHICS_BACKEND   d3dmetal | dxmt | dxvk | wined3d   (key absent = "Auto")
#   WINEMSYNC=1           MSync
#   D3DM_ENABLE_METALFX=1 "DLSS" for D3DMetal (DLSS calls are served by MetalFX)
#   DXMT_ENABLE_NVEXT=1   the same toggle for DXMT
# ROSETTA_ADVERTISE_AVX needs no setting: CrossOver's wine wrapper already sets it to 1.
#
# Written for macOS /bin/bash 3.2.

set -uo pipefail
BOTTLE="${BOTTLE:-Arknights Endfield}"
BACKEND="${BACKEND:-d3dmetal}"
APP="${APP:-}"
if [ -z "$APP" ]; then
  for c in "/Applications/CrossOver_Endfield_Patch.app" \
           "$HOME/Applications/CrossOver_Endfield_Patch.app" \
           "/Applications/CrossOver.app"; do
    [ -d "$c" ] && APP="$c" && break
  done
fi
CXR="$APP/Contents/SharedSupport/CrossOver"
[ -x "$CXR/bin/cxbottle" ] || { echo "ERROR: CrossOver not found — set APP=/path/to/CrossOver.app" >&2; exit 1; }
case "$BACKEND" in
  d3dmetal|dxmt|dxvk|wined3d) ;;
  *) echo "ERROR: BACKEND must be d3dmetal, dxmt, dxvk or wined3d (got '$BACKEND')" >&2; exit 1 ;;
esac
BP="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE"
CONF="$BP/cxbottle.conf"

# key/value pairs to apply
SETTINGS=(CX_GRAPHICS_BACKEND "$BACKEND" WINEMSYNC 1)
case "$BACKEND" in
  d3dmetal) SETTINGS+=(D3DM_ENABLE_METALFX 1) ;;
  dxmt)     SETTINGS+=(DXMT_ENABLE_NVEXT 1) ;;
esac

show_settings(){
  grep -E '^"(CX_GRAPHICS_BACKEND|WINEMSYNC|D3DM_ENABLE_METALFX|DXMT_ENABLE_NVEXT)"' "$CONF" 2>/dev/null \
    | sed 's/^/  /' || echo "  (none set — CrossOver defaults: graphics Auto, MSync off, DLSS off)"
}

if [ -d "$BP" ]; then
  if [ "${UPDATE:-0}" != "1" ]; then
    echo "Bottle '$BOTTLE' already exists — leaving it untouched. Its current settings:"
    show_settings
    echo "Re-run with UPDATE=1 to apply: ${SETTINGS[*]}"
    exit 1
  fi
  [ -f "$CONF" ] || { echo "ERROR: $CONF not found" >&2; exit 1; }
  BACKUP="$CONF.bak-$(date +%Y%m%d-%H%M%S)"
  cp -p "$CONF" "$BACKUP" || { echo "ERROR: could not back up $CONF" >&2; exit 1; }
  # Edit with CrossOver's own config writer (the one its bottle templates use for these keys),
  # so the file keeps CrossOver's format and comments.
  /usr/bin/perl -I"$CXR/lib/perl" -MCXRWConfig -e '
    my ($file, @kv) = @ARGV;
    my $conf = CXRWConfig->new($file) or die "could not read $file\n";
    while (my ($key, $value) = splice(@kv, 0, 2)) {
      $conf->set("EnvironmentVariables", $key, $value);
    }
    $conf->save() or die "could not save $file\n";
  ' "$CONF" "${SETTINGS[@]}" || { echo "ERROR: could not update $CONF (backup: $BACKUP)" >&2; exit 1; }
  echo "Updated bottle '$BOTTLE' (previous config saved as $(basename "$BACKUP")):"
  echo "  If CrossOver is open, reopen the bottle's page to see the new settings."
else
  params=()
  i=0
  while [ "$i" -lt "${#SETTINGS[@]}" ]; do
    params+=(--param "EnvironmentVariables:${SETTINGS[$i]}=${SETTINGS[$((i + 1))]}")
    i=$((i + 2))
  done
  echo "Creating bottle '$BOTTLE' (Windows 11 64-bit) with $APP…"
  "$CXR/bin/cxbottle" --bottle "$BOTTLE" --create --template win11_64 \
    --description "Arknights: Endfield (Endfield_FineWine)" "${params[@]}" \
    || { echo "ERROR: cxbottle failed to create '$BOTTLE'" >&2; exit 1; }
  echo "Created bottle '$BOTTLE':"
fi
show_settings

cat <<EOF

Next:
  1. Install the Gryphline launcher into the bottle. Download the Windows launcher from
     https://endfield.gryphline.com, then either use CrossOver → "$BOTTLE" → Install Application
     into Bottle, or run:
       "$CXR/bin/wine" --bottle "$BOTTLE" --wait-children ~/Downloads/GRYPHLINK_<version>.exe
     Keep the default install location (C:\\Program Files\\GRYPHLINK).
  2. Log in to the launcher, download the game, and start it with the dropdown next to Start →
     "Launch with DirectX 11" (DX12 renders a white screen; Vulkan is experimental,
     see docs/graphics-performance.md).
EOF
