#!/usr/bin/env bash
# make-launcher-app.sh — generate a double-clickable "Arknights Endfield.app" that launches the
# game directly through the patched CrossOver, bypassing the Gryphline launcher.
#
# The launcher script is produced from patcher-app/Resources/LauncherTemplate.sh (the same
# template the FineWine Patcher.app bakes in), so the shell installers and the GUI app stay in sync.
#
# Usage:
#   scripts/make-launcher-app.sh [options]
# Options (all optional; sensible defaults):
#   --out-dir DIR     where to create "<name>.app"      (default: the patched app's folder, else /Applications)
#   --cx-app PATH     patched CrossOver.app             (default: matched by bundle id, then usual locations)
#   --bundle-id ID    patched app's bundle identifier   (default: com.codeweavers.CrossOvEF)
#   --bottle NAME     CrossOver bottle name             (default: "Arknights Endfield")
#   --target WINPATH  Windows exe to launch             (default: the Gryphline launcher, .../GRYPHLINK/Launcher.exe)
#   --gfxargs ARGS    launch args                       (default: "" — add "-force-d3d11" if --target is Endfield.exe)
#   --name NAME       launcher app name                 (default: "Arknights Endfield")
#   --force           overwrite an existing launcher app
#   --portable        build for distribution: do not require a local CrossOver app — bake the
#                     default path as a hint (the runtime template also searches at launch).
# Env: SKIP=1 to do nothing (used by the install scripts to opt out).

set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$REPO/patcher-app/Resources/LauncherTemplate.sh"

LOG(){ printf '\033[1m==>\033[0m %s\n' "$*"; }
die(){ printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

OUT_DIR=""
CX_APP=""
BUNDLE_ID="com.codeweavers.CrossOvEF" # the patched CrossOver's bundle id (used to find a renamed app)
BOTTLE="Arknights Endfield"
TARGET="C:/Program Files/GRYPHLINK/Launcher.exe"
GFXARGS=""
NAME="Arknights Endfield"
FORCE=0
PORTABLE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out-dir)  OUT_DIR="${2:-}"; shift 2 ;;
    --cx-app)   CX_APP="${2:-}";  shift 2 ;;
    --bundle-id) BUNDLE_ID="${2:-}"; shift 2 ;;
    --bottle)   BOTTLE="${2:-}";  shift 2 ;;
    --target)   TARGET="${2:-}";  shift 2 ;;
    --gfxargs)  GFXARGS="${2:-}"; shift 2 ;;
    --name)     NAME="${2:-}";    shift 2 ;;
    --force)    FORCE=1; shift ;;
    --portable) PORTABLE=1; shift ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "${SKIP:-0}" = "1" ] && { echo "make-launcher-app: SKIP=1, doing nothing"; exit 0; }
[ -f "$TEMPLATE" ] || die "template not found: $TEMPLATE"

bundle_id_of() { plutil -extract CFBundleIdentifier raw "$1/Contents/Info.plist" 2>/dev/null \
                 || defaults read "$1/Contents/Info" CFBundleIdentifier 2>/dev/null; }
is_cx_app() { [ -d "$1/Contents/SharedSupport/CrossOver/bin" ] && [ -x "$1/Contents/SharedSupport/CrossOver/bin/wine" ]; }
is_trusted_install() { case "$1" in /Applications/*|"$HOME"/Applications/*) return 0 ;; *) return 1 ;; esac; }
is_cx_candidate() { is_trusted_install "$1" || return 1; [ "$(bundle_id_of "$1")" = "$BUNDLE_ID" ] || return 1; is_cx_app "$1"; }

# Resolve the patched CrossOver app. Prefer matching the bundle identifier (the .app may be renamed),
# via Spotlight then a scan; Spotlight hits are filtered to trusted install roots + a verified payload,
# so a same-bundle-id bundle in a writable location is never selected. Falls back to the known filenames.
if [ -z "$CX_APP" ] && command -v mdfind >/dev/null 2>&1; then
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if is_cx_candidate "$c"; then CX_APP="$c"; break; fi
  done < <(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null)
fi
if [ -z "$CX_APP" ]; then
  for app in /Applications/*.app "$HOME"/Applications/*.app; do
    if is_cx_candidate "$app"; then CX_APP="$app"; break; fi
  done
fi
if [ -z "$CX_APP" ]; then
  for c in "/Applications/CrossOver_Endfield_Patch.app" \
           "$HOME/Applications/CrossOver_Endfield_Patch.app" \
           "/Applications/CrossOver.app"; do
    [ -d "$c" ] && CX_APP="$c" && break
  done
fi
if [ -z "$CX_APP" ]; then
  if [ "$PORTABLE" = "1" ]; then
    CX_APP="/Applications/CrossOver_Endfield_Patch.app" # hint only; the runtime template searches
  else
    die "patched CrossOver app not found (pass --cx-app PATH, or --portable for a shippable build)"
  fi
fi
[ "$PORTABLE" = "1" ] || [ -d "$CX_APP" ] || die "patched CrossOver app not found at $CX_APP"

# Default output directory: alongside the patched app (its parent), which is writable if the
# patcher put it there; fall back to ~/Applications or (portable) the cwd.
if [ -z "$OUT_DIR" ]; then
  if [ "$PORTABLE" = "1" ]; then
    OUT_DIR="$PWD"
  else
    OUT_DIR="$(cd "$CX_APP/.." && pwd)"
    [ -w "$OUT_DIR" ] || OUT_DIR="$HOME/Applications"
  fi
fi
mkdir -p "$OUT_DIR"

APP="$OUT_DIR/$NAME.app"
if [ -e "$APP" ] && [ "$FORCE" != "1" ]; then
  die "$APP already exists (use --force to replace)"
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Render the template (Python for safe substitution — paths may contain spaces).
python3 - "$TEMPLATE" "$APP/Contents/MacOS/launcher" "$CX_APP" "$BUNDLE_ID" "$BOTTLE" "$TARGET" "$GFXARGS" <<'PY'
import sys
tpl, out, cx, bundle, bottle, target, gfx = sys.argv[1:8]
s = open(tpl, encoding="utf-8").read()
for k, v in (("@CX_APP@", cx), ("@BUNDLE_ID@", bundle), ("@BOTTLE@", bottle),
             ("@TARGET@", target), ("@GFXARGS@", gfx)):
    s = s.replace(k, v)
open(out, "w", encoding="utf-8").write(s)
PY
chmod +x "$APP/Contents/MacOS/launcher"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>$NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$NAME</string>
	<key>CFBundleExecutable</key>
	<string>launcher</string>
	<key>CFBundleIdentifier</key>
	<string>io.github.stoicswe.EndfieldFineWine.launcher</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1.0</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

plutil -lint -s "$APP/Contents/Info.plist" >/dev/null
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

LOG "Launcher app created: $APP"
echo "  opens: $CX_APP  (bottle: $BOTTLE)"
echo "  target: $TARGET  $GFXARGS"
