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
#   --cx-app PATH     patched CrossOver.app             (default: first of the usual locations)
#   --bottle NAME     CrossOver bottle name             (default: "Arknights Endfield")
#   --target WINPATH  Windows exe to launch             (default: the Gryphline launcher, .../GRYPHLINK/Launcher.exe)
#   --gfxargs ARGS    launch args                       (default: "" — add "-force-d3d11" if --target is Endfield.exe)
#   --name NAME       launcher app name                 (default: "Arknights Endfield")
#   --force           overwrite an existing launcher app
# Env: SKIP=1 to do nothing (used by the install scripts to opt out).

set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$REPO/patcher-app/Resources/LauncherTemplate.sh"

LOG(){ printf '\033[1m==>\033[0m %s\n' "$*"; }
die(){ printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

OUT_DIR=""
CX_APP=""
BOTTLE="Arknights Endfield"
TARGET="C:/Program Files/GRYPHLINK/Launcher.exe"
GFXARGS=""
NAME="Arknights Endfield"
FORCE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out-dir)  OUT_DIR="${2:-}"; shift 2 ;;
    --cx-app)   CX_APP="${2:-}";  shift 2 ;;
    --bottle)   BOTTLE="${2:-}";  shift 2 ;;
    --target)   TARGET="${2:-}";  shift 2 ;;
    --gfxargs)  GFXARGS="${2:-}"; shift 2 ;;
    --name)     NAME="${2:-}";    shift 2 ;;
    --force)    FORCE=1; shift ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "${SKIP:-0}" = "1" ] && { echo "make-launcher-app: SKIP=1, doing nothing"; exit 0; }
[ -f "$TEMPLATE" ] || die "template not found: $TEMPLATE"

# Resolve the patched CrossOver app.
if [ -z "$CX_APP" ]; then
  for c in "/Applications/CrossOver_Endfield_Patch.app" \
           "$HOME/Applications/CrossOver_Endfield_Patch.app" \
           "/Applications/CrossOver.app"; do
    [ -d "$c" ] && CX_APP="$c" && break
  done
fi
[ -n "$CX_APP" ] && [ -d "$CX_APP" ] || die "patched CrossOver app not found (pass --cx-app PATH)"

# Default output directory: alongside the patched app (its parent), which is writable if the
# patcher put it there; fall back to ~/Applications.
if [ -z "$OUT_DIR" ]; then
  OUT_DIR="$(cd "$CX_APP/.." && pwd)"
  [ -w "$OUT_DIR" ] || OUT_DIR="$HOME/Applications"
fi
mkdir -p "$OUT_DIR"

APP="$OUT_DIR/$NAME.app"
if [ -e "$APP" ] && [ "$FORCE" != "1" ]; then
  die "$APP already exists (use --force to replace)"
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Render the template (Python for safe substitution — paths may contain spaces).
python3 - "$TEMPLATE" "$APP/Contents/MacOS/launcher" "$CX_APP" "$BOTTLE" "$TARGET" "$GFXARGS" <<'PY'
import sys
tpl, out, cx, bottle, target, gfx = sys.argv[1:7]
s = open(tpl, encoding="utf-8").read()
for k, v in (("@CX_APP@", cx), ("@BOTTLE@", bottle), ("@TARGET@", target), ("@GFXARGS@", gfx)):
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
