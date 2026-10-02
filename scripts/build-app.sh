#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$PROJECT_DIR/dist/AppleTree.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/AppleTree" "$APP_DIR/Contents/MacOS/AppleTree"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp -R "$BIN_DIR/AppleTree_AppleTreeCore.bundle" "$APP_DIR/Contents/Resources/"
ICON_DIR="$PROJECT_DIR/.build/AppleTree.iconset"
mkdir -p "$ICON_DIR"
swift "$PROJECT_DIR/scripts/MakeIcon.swift" "$ICON_DIR/icon_512x512@2x.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_DIR/icon_512x512@2x.png" --out "$ICON_DIR/icon_${size}x${size}.png" >/dev/null
    if [ "$size" != 512 ]; then
        double=$((size * 2))
        sips -z "$double" "$double" "$ICON_DIR/icon_512x512@2x.png" --out "$ICON_DIR/icon_${size}x${size}@2x.png" >/dev/null
    fi
done
iconutil -c icns "$ICON_DIR" -o "$APP_DIR/Contents/Resources/AppleTree.icns"
codesign --force --deep --sign - "$APP_DIR"
echo "Built: $APP_DIR"
