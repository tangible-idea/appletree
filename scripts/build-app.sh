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
cp -R "$BIN_DIR/AppleTree_AppleTree.bundle" "$APP_DIR/Contents/Resources/"
cp "$PROJECT_DIR/Sources/AppleTree/Resources/AppleTree.icns" "$APP_DIR/Contents/Resources/AppleTree.icns"
codesign --force --deep --sign - "$APP_DIR"
echo "Built: $APP_DIR"
