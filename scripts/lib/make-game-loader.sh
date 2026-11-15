#!/usr/bin/env bash
# make-game-loader.sh — make the copy of Wine's loader that macOS treats as a game.
#
# Usage: scripts/lib/make-game-loader.sh <runtime's lib/wine/aarch64-unix folder>
#
# macOS turns Game Mode on for a full-screen app that says it is a game, and it reads that
# from the Info.plist of the app bundle the running executable is in. A bare executable has no
# bundle (the Info.plist Wine embeds in its loader is not consulted for this), so the runtime
# gets a small one: "FineWine Game.app", holding a copy of the loader and an Info.plist that
# says it is a game. FineWine runs programs that use Direct3D, Vulkan or OpenGL with it
# (FINEWINE_LOADER); everything else keeps the plain loader. The loader finds the rest of
# Wine from inside the bundle (runtime patch 0011).
set -euo pipefail
DIR="$1"
[ -x "$DIR/wine" ] || { echo "make-game-loader: no loader at $DIR/wine" >&2; exit 1; }
APP="$DIR/FineWine Game.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$DIR/wine" "$APP/Contents/MacOS/wine-game"
chmod 755 "$APP/Contents/MacOS/wine-game"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>English</string>
    <key>CFBundleExecutable</key>
    <string>wine-game</string>
    <key>CFBundleIdentifier</key>
    <string>org.finewine.game</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>FineWine Game</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>NSPrincipalClass</key>
    <string>WineApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <string>1</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.games</string>
    <key>GCSupportsGameMode</key>
    <true/>
    <key>LSSupportsGameMode</key>
    <true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || { echo "make-game-loader: could not sign $APP" >&2; exit 1; }
echo "game loader: $APP"
