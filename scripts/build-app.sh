#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$PROJECT_DIR/dist/AppleTree.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/AppleTree" "$APP_DIR/Contents/MacOS/AppleTree"
# Resources/Info.plist uses Xcode build variables; fill them in and add the keys Xcode would generate.
PLIST="$APP_DIR/Contents/Info.plist"
sed -e 's/$(DEVELOPMENT_LANGUAGE)/en/' \
    -e 's/$(EXECUTABLE_NAME)/AppleTree/' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/net.tangibleidea.appletree/' \
    -e 's/$(PRODUCT_NAME)/AppleTree/' \
    "$PROJECT_DIR/Resources/Info.plist" > "$PLIST"
/usr/libexec/PlistBuddy \
    -c 'Add :CFBundleDisplayName string AppleTree' \
    -c 'Add :CFBundleIconFile string AppleTree' \
    -c 'Add :CFBundleLocalizations array' \
    -c 'Add :CFBundleLocalizations:0 string en' \
    -c 'Add :CFBundleLocalizations:1 string ko' \
    -c 'Add :LSMinimumSystemVersion string 14.0' \
    -c 'Add :LSApplicationCategoryType string public.app-category.utilities' \
    -c 'Add :NSHighResolutionCapable bool true' \
    -c 'Add :NSPrincipalClass string NSApplication' \
    "$PLIST"
if grep -q '\$(' "$PLIST"; then
    echo "Unresolved build variable in Info.plist:" >&2
    grep '\$(' "$PLIST" >&2
    exit 1
fi
cp -R "$BIN_DIR/AppleTree_AppleTreeCore.bundle" "$APP_DIR/Contents/Resources/"
cp -R "$BIN_DIR/AppleTree_AppleTree.bundle" "$APP_DIR/Contents/Resources/"
cp "$PROJECT_DIR/Sources/AppleTree/Resources/AppleTree.icns" "$APP_DIR/Contents/Resources/AppleTree.icns"
codesign --force --deep --sign - "$APP_DIR"
echo "Built: $APP_DIR"
