#!/usr/bin/env bash
# build-app.sh — build "FineWine Patcher.app" (SwiftPM + manual bundle assembly; no Xcode needed,
# only the Command Line Tools).
#
# The app bundles the three pre-built patched Wine modules as its payload, so a completed
# Wine build must exist first:  scripts/build-wine.sh all   (from the repo root)
#
# Usage:  patcher-app/scripts/build-app.sh
# Env:
#   PAYLOAD_DIR             where to find the built modules
#                           (default: <repo>/build/wine-build64, the build-wine.sh output tree;
#                            a flat directory holding ntdll.so/kernel32.dll/ntoskrnl.exe also works)
#   CODESIGN_ID             signing identity (default "-" = ad-hoc; set your "Developer ID
#                           Application: …" identity for notarizable builds)
#   ALLOW_MISSING_PAYLOAD=1 build without payload (smoke-test builds only — the app will
#                           refuse to patch, and says so in its UI)
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # patcher-app/
REPO="$(cd "$HERE/.." && pwd)"
APP_NAME="FineWine Patcher"
EXE="FineWinePatcher"
BUNDLE_ID="io.github.stoicswe.FineWinePatcher"
VERSION="1.0.0"
PAYLOAD_DIR="${PAYLOAD_DIR:-$REPO/build/wine-build64}"
CODESIGN_ID="${CODESIGN_ID:--}"
OUT="$HERE/build"
APP="$OUT/$APP_NAME.app"

log(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok(){  printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------- 1. compile
log "Compiling (swift build, release)"
swift build -c release --package-path "$HERE"
BIN="$(swift build -c release --package-path "$HERE" --show-bin-path)/$EXE"
[ -x "$BIN" ] || { echo "ERROR: build produced no executable at $BIN"; exit 1; }
ok "$(file -b "$BIN")"

# ---------------------------------------------------------------- 2. assemble bundle
log "Assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/licenses" \
         "$APP/Contents/Resources/payload/x86_64-unix" \
         "$APP/Contents/Resources/payload/x86_64-windows"
cp "$BIN" "$APP/Contents/MacOS/$EXE"
cp "$HERE/Resources/licenses/"*.txt "$APP/Contents/Resources/licenses/"

ICON_PLIST=""
if [ -f "$HERE/Resources/AppIcon.icns" ]; then
  cp "$HERE/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  ICON_PLIST=$'\t<key>CFBundleIconFile</key>\n\t<string>AppIcon</string>'
  ok "app icon"
else
  warn "Resources/AppIcon.icns not found — building without an icon (run scripts/make-appicon.sh)"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleExecutable</key>
	<string>$EXE</string>
$ICON_PLIST
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>MIT — © 2026 Endfield_FineWine contributors. Bundled Wine modules: LGPL-2.1-or-later.</string>
</dict>
</plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist"
ok "bundle skeleton + Info.plist"

# ---------------------------------------------------------------- 3. payload
log "Staging the pre-built Wine modules (payload) from $PAYLOAD_DIR"
find_module(){ # flat-name  tree-relative-path
  if   [ -f "$PAYLOAD_DIR/$2" ]; then echo "$PAYLOAD_DIR/$2"
  elif [ -f "$PAYLOAD_DIR/$1" ]; then echo "$PAYLOAD_DIR/$1"
  else echo ""; fi
}
NTDLL="$(find_module ntdll.so dlls/ntdll/ntdll.so)"
KERNEL32="$(find_module kernel32.dll dlls/kernel32/x86_64-windows/kernel32.dll)"
NTOSKRNL="$(find_module ntoskrnl.exe dlls/ntoskrnl.exe/x86_64-windows/ntoskrnl.exe)"

if [ -z "$NTDLL" ] || [ -z "$KERNEL32" ] || [ -z "$NTOSKRNL" ]; then
  if [ "${ALLOW_MISSING_PAYLOAD:-0}" = "1" ]; then
    warn "payload modules not found — building WITHOUT payload (smoke test only)"
  else
    echo "ERROR: payload modules not found under $PAYLOAD_DIR"
    echo "       Run scripts/build-wine.sh all first (or set PAYLOAD_DIR)."
    exit 1
  fi
else
  P="$APP/Contents/Resources/payload"
  cp "$NTDLL"    "$P/x86_64-unix/ntdll.so"
  cp "$KERNEL32" "$P/x86_64-windows/kernel32.dll"
  cp "$NTOSKRNL" "$P/x86_64-windows/ntoskrnl.exe"

  # Pre-add the lib64 rpath to ntdll.so HERE, at app-build time, so end users of the
  # patcher never need Xcode tools installed. CrossOver's ntdll dlopens cxcompatdb.so,
  # which resolves @rpath/libgnutls through ntdll.so's own LC_RPATH — without this
  # rpath D3DMetal never engages (see scripts/swap-into-crossover.sh).
  NT="$P/x86_64-unix/ntdll.so"
  if otool -l "$NT" >/dev/null 2>&1; then
    if ! otool -l "$NT" | grep -A2 LC_RPATH | grep -q 'lib64'; then
      install_name_tool -add_rpath "@loader_path/../../../lib64" "$NT"
    fi
    otool -l "$NT" | grep -A2 LC_RPATH | grep -q 'lib64' \
      || { echo "ERROR: could not add the lib64 rpath to ntdll.so"; exit 1; }
    ok "ntdll.so LC_RPATH → lib64 (required for D3DMetal)"
  elif [ "${ALLOW_MISSING_PAYLOAD:-0}" = "1" ]; then
    warn "ntdll.so is not a Mach-O (dummy payload?) — skipping the rpath step"
  else
    echo "ERROR: $NTDLL is not a Mach-O binary"; exit 1
  fi

  for f in "$P/x86_64-unix/ntdll.so" "$P/x86_64-windows/kernel32.dll" "$P/x86_64-windows/ntoskrnl.exe"; do
    codesign --force --sign "$CODESIGN_ID" "$f" 2>/dev/null || true
  done
  ok "payload staged: ntdll.so, kernel32.dll, ntoskrnl.exe"
fi

# ---------------------------------------------------------------- 4. sign
log "Signing ($CODESIGN_ID)"
if [ "$CODESIGN_ID" = "-" ]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$CODESIGN_ID" "$APP"
fi
codesign --verify "$APP"
ok "signature verifies"

# ---------------------------------------------------------------- 5. done
log "Done -> $APP"
cat <<EOF

Next:
  open "$APP"

Notes:
  - Ad-hoc-signed builds are for your own machine. To distribute, re-run with
    CODESIGN_ID="Developer ID Application: …" and notarize, or tell users to
    right-click -> Open on first launch.
  - If you distribute the built app, the bundled Wine modules are LGPL-2.1:
    publish the patches + exact CrossOver source used (see patcher-app/README.md).
EOF
