#!/usr/bin/env bash
# make-appicon.sh — (re)generate Resources/AppIcon.icns from Resources/appicon/appicon-source.png.
# Run this only when the source art changes; the resulting AppIcon.icns is committed and used by
# build-app.sh. Uses Apple tools only (swift + iconutil), no third-party image libraries.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"          # patcher-app/
SRC="${1:-$HERE/Resources/appicon/appicon-source.png}"
OUT="$HERE/Resources/AppIcon.icns"
MARGIN="${MARGIN:-0.06}"
WORK="$(mktemp -d)/AppIcon.iconset"
trap 'rm -rf "$(dirname "$WORK")"' EXIT

[ -f "$SRC" ] || { echo "ERROR: source image not found: $SRC"; exit 1; }
echo "==> Rendering iconset from $SRC (margin $MARGIN)"
swift "$HERE/scripts/make-appicon.swift" "$SRC" "$WORK" "$MARGIN"
echo "==> Packing $OUT"
iconutil -c icns "$WORK" -o "$OUT"
echo "  wrote $OUT ($(stat -f '%z' "$OUT") bytes)"
