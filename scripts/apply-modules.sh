#!/usr/bin/env bash
# Install packaged Wine modules and MoltenVK into a copy of CrossOver.
#
# Usage:  scripts/apply-modules.sh [MODULES_DIR]    (default: dist/endfield-wine-modules)
# Env:
#   SRC_APP   CrossOver to copy (default /Applications/CrossOver.app)
#   DEST_APP  patched copy to create, replacing any existing one (default /Applications/CrossOver_Endfield_Patch.app)
#   BUNDLE_ID bundle identifier for patched copy (default com.codeweavers.CrossOvEF)
#   GPTK      Apple Game Porting Toolkit to take D3DMetal from (optional): its .dmg, the mounted
#             volume, or its redist/lib/external directory
#   FORCE=1   apply even if the modules were built for a different CrossOver version

set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
MODULES="${1:-$REPO/dist/endfield-wine-modules}"
SRC_APP="${SRC_APP:-/Applications/CrossOver.app}"
DEST_APP="${DEST_APP:-/Applications/CrossOver_Endfield_Patch.app}"
BUNDLE_ID="${BUNDLE_ID:-com.codeweavers.CrossOvEF}"
ORIG_BUNDLE_ID="com.codeweavers.CrossOver"
GPTK="${GPTK:-}"
log(){  printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok(){   printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }
die(){  printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
gptk_mnt=""
gptk_inner_mnt=""
cleanup(){
  [ -z "$gptk_inner_mnt" ] || { hdiutil detach "$gptk_inner_mnt" -quiet 2>/dev/null || true; rmdir "$gptk_inner_mnt" 2>/dev/null || true; }
  [ -z "$gptk_mnt" ] || { hdiutil detach "$gptk_mnt" -quiet 2>/dev/null || true; rmdir "$gptk_mnt" 2>/dev/null || true; }
}
trap cleanup EXIT

log "Checking modules in $MODULES"
for f in ntdll.so kernel32.dll ntoskrnl.exe libMoltenVK.dylib CROSSOVER_VERSION SHA256SUMS; do
  [ -f "$MODULES/$f" ] || die "$MODULES/$f not found — run scripts/install-release.sh or follow README.md's source build steps"
done
( cd "$MODULES" && shasum -a 256 -c -s SHA256SUMS ) || die "checksum mismatch in $MODULES"
ok "checksums match"

[ -d "$SRC_APP" ] || die "$SRC_APP not found"
case "$DEST_APP" in *.app) ;; *) die "DEST_APP must end in .app: $DEST_APP" ;; esac
[ "$DEST_APP" != "$SRC_APP" ] || die "DEST_APP must differ from SRC_APP"

built="$(cat "$MODULES/CROSSOVER_VERSION")"
app_ver="$(defaults read "$SRC_APP/Contents/Info" CFBundleVersion 2>/dev/null || echo unknown)"
case "$app_ver." in
  "$built".*) ok "CrossOver $app_ver matches module version $built" ;;
  *) if [ "${FORCE:-0}" = "1" ]; then warn "CrossOver $app_ver; modules require $built (overridden by FORCE=1)"
     else die "$SRC_APP is CrossOver $app_ver; modules require $built for ABI compatibility (FORCE=1 to override)."; fi ;;
esac

d3dmetal_version(){ plutil -extract CFBundleShortVersionString raw "$1/D3DMetal.framework/Resources/Info.plist" 2>/dev/null || echo "(unknown version)"; }
gptk_src=""
if [ -z "$GPTK" ]; then
  for cand in /Volumes/Evaluation\ environment* /Volumes/Game\ Porting\ Toolkit*; do
    if [ -d "$cand" ]; then
      GPTK="$cand"
      log "Auto-detected mounted GPTK volume: $GPTK"
      break
    fi
  done
fi

if [ -n "$GPTK" ]; then
  gptk_root="$GPTK"
  if [ -f "$GPTK" ]; then
    gptk_mnt="$(mktemp -d)"
    hdiutil attach -readonly -nobrowse -noverify -mountpoint "$gptk_mnt" "$GPTK" >/dev/null </dev/null \
      || die "couldn't mount $GPTK"
    gptk_root="$gptk_mnt"
  fi
  for d in "$gptk_root/redist/lib/external" "$gptk_root"; do
    if [ -f "$d/libd3dshared.dylib" ] && [ -d "$d/D3DMetal.framework" ]; then gptk_src="$d"; break; fi
  done
  # If gptk_root has an inner DMG (e.g. "Evaluation environment...dmg" inside "Game Porting Toolkit"):
  if [ -z "$gptk_src" ]; then
    for inner in "$gptk_root"/Evaluation\ environment*.dmg "$gptk_root"/*.dmg; do
      if [ -f "$inner" ]; then
        gptk_inner_mnt="$(mktemp -d)"
        if hdiutil attach -readonly -nobrowse -noverify -mountpoint "$gptk_inner_mnt" "$inner" >/dev/null </dev/null; then
          for d in "$gptk_inner_mnt/redist/lib/external" "$gptk_inner_mnt"; do
            if [ -f "$d/libd3dshared.dylib" ] && [ -d "$d/D3DMetal.framework" ]; then gptk_src="$d"; break 2; fi
          done
        fi
      fi
    done
  fi
  [ -n "$gptk_src" ] || die "no D3DMetal found in $GPTK (expected redist/lib/external/D3DMetal.framework)"
  ok "GPTK D3DMetal $(d3dmetal_version "$gptk_src") found"
fi

mvk_version(){ LC_ALL=C tr '\0' '\n' < "$1" | LC_ALL=C awk '!v && /^[0-9]+\.[0-9]+\.[0-9]+$/ { v = $0 } END { print (v ? v : "(unknown version)") }'; }
mvk_src="$MODULES/libMoltenVK.dylib"
mvk_type="$(file -b "$mvk_src")"
case "$mvk_type" in
  *"dynamically linked shared library x86_64"*) ;;
  *) die "$mvk_src is not an x86_64 dynamic library: $mvk_type" ;;
esac
[ -f "$SRC_APP/Contents/SharedSupport/CrossOver/lib64/libMoltenVK.dylib" ] \
  || die "$SRC_APP has no lib64/libMoltenVK.dylib to replace"
ok "MoltenVK $(mvk_version "$mvk_src") found"

log "Copying $SRC_APP -> $DEST_APP"
rm -rf "$DEST_APP"
cp -a "$SRC_APP" "$DEST_APP"
CXR="$DEST_APP/Contents/SharedSupport/CrossOver"

log "Installing patched Wine modules"
swap(){ # module  path-under-lib/wine
  local dst="$CXR/lib/wine/$2"
  [ -f "$dst" ] || die "Wine module missing: $dst"
  cp "$dst" "$dst.cxorig"
  cp "$MODULES/$1" "$dst"
  ok "$2"
}
swap ntdll.so     x86_64-unix/ntdll.so
swap kernel32.dll x86_64-windows/kernel32.dll
swap ntoskrnl.exe x86_64-windows/ntoskrnl.exe
codesign --force --sign - "$CXR/lib/wine/x86_64-unix/ntdll.so"

if [ -n "$gptk_src" ]; then
  log "Installing GPTK D3DMetal"
  DEST_GPTK="$CXR/lib64/apple_gptk/external"
  [ -d "$DEST_GPTK" ] || die "$DEST_GPTK not found in this CrossOver"
  cp -a "$DEST_GPTK" "$DEST_GPTK.cxorig"
  ditto "$gptk_src" "$DEST_GPTK"   # merges over CrossOver's copy
  codesign --force --sign - "$DEST_GPTK/libd3dshared.dylib" 2>/dev/null
  codesign --force --deep --sign - "$DEST_GPTK/D3DMetal.framework" 2>/dev/null
  ok "D3DMetal $(d3dmetal_version "$DEST_GPTK")"
fi

log "Installing MoltenVK"
DEST_MVK="$CXR/lib64/libMoltenVK.dylib"
[ -f "$DEST_MVK" ] || die "$DEST_MVK not found in this CrossOver"
cp "$DEST_MVK" "$DEST_MVK.cxorig"
cp "$mvk_src" "$DEST_MVK"
codesign --force --sign - "$DEST_MVK"
ok "MoltenVK $(mvk_version "$DEST_MVK") (was $(mvk_version "$DEST_MVK.cxorig"))"

log "Patching bundle ID ($BUNDLE_ID) & seed launcher helper archives"
[ "${#BUNDLE_ID}" -eq "${#ORIG_BUNDLE_ID}" ] || die "BUNDLE_ID must be exactly ${#ORIG_BUNDLE_ID} characters (same length as $ORIG_BUNDLE_ID)"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$DEST_APP/Contents/Info.plist" 2>/dev/null \
  || defaults write "$DEST_APP/Contents/Info" CFBundleIdentifier "$BUNDLE_ID"
ok "CFBundleIdentifier -> $BUNDLE_ID"

for helper in "Menu Helper" "Bottle Helper"; do
  cpbz2="$DEST_APP/Contents/Resources/$helper.cpbz2"
  if [ -f "$cpbz2" ]; then
    hwork="$(mktemp -d)"
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

log "Removing bundle seal and quarantine"
rm -rf "$DEST_APP/Contents/_CodeSignature" "$DEST_APP/Contents/CodeResources"
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true

cat <<EOF

Created $DEST_APP

Open the app. If macOS blocks it, choose "Open Anyway" in System Settings -> Privacy & Security.
Enable MSync in the bottle's advanced settings.
EOF