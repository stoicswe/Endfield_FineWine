#!/usr/bin/env bash
# build-app.sh — build "FineWine.app", the menu bar app that manages Wine prefixes.
# SwiftPM plus manual bundle assembly, like the patcher; no Xcode project.
#
# Usage:  finewine-app/scripts/build-app.sh
# Env:
#   VERSION       CFBundleShortVersionString (default 0.1.0)
#   ICON_VARIANT  which appearance of the icon to use (default Dark)
#   CODESIGN_ID   signing identity (default "-" = ad-hoc, for your own machine)
#   SKIP_TESTS=1  don't run the unit tests first
#   RUNTIME_DIR   the Wine runtime to build into the app (default ../build/finewine-runtime)
#   BUNDLE_RUNTIME  0 = build the app without a runtime; required = fail if there is none
#                 (default: add it when it exists, warn when it does not)
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # finewine-app/
APP_NAME="FineWine"
EXE="FineWine"
BUNDLE_ID="io.github.stoicswe.FineWine"
VERSION="${VERSION:-0.1.0}"
CODESIGN_ID="${CODESIGN_ID:--}"
OUT="$HERE/build"
APP="$OUT/$APP_NAME.app"

log(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok(){  printf '  \033[32m✓\033[0m %s\n' "$*"; }

if [ "${SKIP_TESTS:-0}" != "1" ]; then
  log "Running unit tests"
  # pipefail makes a failing test stop the build; grep keeps the output to the result lines.
  swift test --package-path "$HERE" 2>&1 | grep -E 'error:|Executed [0-9]+ tests' | tail -n 6
fi

log "Compiling (swift build, release)"
swift build -c release --package-path "$HERE"
BIN="$(swift build -c release --package-path "$HERE" --show-bin-path)/$EXE"
[ -x "$BIN" ] || { echo "ERROR: build produced no executable at $BIN"; exit 1; }
ok "$(file -b "$BIN")"

log "Assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXE"
# The app icon is the DARK appearance of the Icon Composer artwork in Resources/FW_Icon, on every
# system appearance. Compiling the .icon document with actool would give an icon that follows
# the system (light in light mode), so instead a plain .icns is made from the dark PNG exports
# and no asset catalog or CFBundleIconName is added. ICON_VARIANT picks another appearance.
ICON_DIR="$HERE/Resources/FW_Icon"
ICON_NAME="AppIcon"
ICON_VARIANT="${ICON_VARIANT:-Dark}"
ICON_PLIST=""
if [ -d "$ICON_DIR/Icon Exports" ]; then
  swift "$HERE/scripts/make-icns.swift" "$ICON_DIR/Icon Exports" "$ICON_VARIANT" \
    "$APP/Contents/Resources/$ICON_NAME.icns"
  ICON_PLIST=$'\t<key>CFBundleIconFile</key>\n\t<string>'"$ICON_NAME"$'</string>'
  ok "app icon ($ICON_VARIANT appearance)"
else
  echo "  ! no icon exports in $ICON_DIR — building without an icon"
fi

# The menu bar icon, loaded from the bundle at run time and drawn as a template image.
if [ -f "$HERE/Resources/MenuBarIcon.svg" ]; then
  cp "$HERE/Resources/MenuBarIcon.svg" "$APP/Contents/Resources/MenuBarIcon.svg"
  ok "menu bar icon"
fi

# LSUIElement makes FineWine a menu bar app with no Dock icon (it shows one only while its
# manager window is open). CFBundleURLTypes registers finewine://, which shortcut apps use.
# CFBundleDocumentTypes lists FineWine under "Open With" for .exe and .msi files; the rank is
# Alternate so it never becomes their default app unless the user turns that on in Settings.
# .msi has no system-declared type, so one is declared here (and named in WindowsExecutable.swift).
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
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>$BUNDLE_ID.launch</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>finewine</string>
			</array>
		</dict>
	</array>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>Windows Program</string>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
			<key>LSHandlerRank</key>
			<string>Alternate</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>com.microsoft.windows-executable</string>
				<string>io.github.stoicswe.finewine.msi-installer</string>
			</array>
		</dict>
	</array>
	<key>UTImportedTypeDeclarations</key>
	<array>
		<dict>
			<key>UTTypeIdentifier</key>
			<string>io.github.stoicswe.finewine.msi-installer</string>
			<key>UTTypeDescription</key>
			<string>Windows Installer Package</string>
			<key>UTTypeConformsTo</key>
			<array>
				<string>public.data</string>
			</array>
			<key>UTTypeTagSpecification</key>
			<dict>
				<key>public.filename-extension</key>
				<array>
					<string>msi</string>
				</array>
			</dict>
		</dict>
	</array>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>GPL-3.0-or-later — © 2026 Endfield_FineWine contributors.</string>
</dict>
</plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist"
ok "bundle + Info.plist"

# The Wine runtime goes inside the app, so that FineWine works as it is: it is listed first and
# is what new prefixes use. Its files are already signed (build-finewine-runtime.sh package).
RUNTIME_DIR="${RUNTIME_DIR:-$HERE/../build/finewine-runtime}"
if [ "${BUNDLE_RUNTIME:-1}" = "0" ]; then
  echo "  - no built-in runtime (BUNDLE_RUNTIME=0)"
elif [ -f "$RUNTIME_DIR/runtime.json" ] && [ -x "$RUNTIME_DIR/bin/wine" ]; then
  log "Adding the Wine runtime"
  # ditto keeps symbolic links, permissions and the signatures' extended attributes.
  ditto "$RUNTIME_DIR" "$APP/Contents/Resources/Runtime"
  ok "runtime $(sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' "$RUNTIME_DIR/runtime.json") ($(du -sh "$APP/Contents/Resources/Runtime" | cut -f1))"
elif [ "${BUNDLE_RUNTIME:-1}" = "required" ]; then
  echo "ERROR: no runtime at $RUNTIME_DIR (scripts/build-finewine.sh runtime)"; exit 1
else
  echo "  ! no runtime at $RUNTIME_DIR — building FineWine.app without one (scripts/build-finewine.sh runtime)"
fi

log "Signing ($CODESIGN_ID)"
if [ "$CODESIGN_ID" = "-" ]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$CODESIGN_ID" "$APP"
fi
codesign --verify "$APP"
ok "signature verifies"

log "Done -> $APP"
echo "  open \"$APP\""
