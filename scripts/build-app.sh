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
    -c 'Add :NSHighResolutionCapable bool true' \
    -c 'Add :NSPrincipalClass string NSApplication' \
    "$PLIST"
# The TypeSafe key for the desktop tree's folder suggestions. It is readable by anyone who has the app.
TYPESAFE_KEY="${TYPESAFE_API_KEY:-$(cat "$PROJECT_DIR/.typesafe-api-key" 2>/dev/null || true)}"
if [ -n "$TYPESAFE_KEY" ]; then
    /usr/libexec/PlistBuddy -c "Add :TypeSafeAPIKey string $TYPESAFE_KEY" "$PLIST"
else
    echo "warning: no TypeSafe API key (set TYPESAFE_API_KEY or create .typesafe-api-key); folder suggestions are off." >&2
fi
if grep -q '\$(' "$PLIST"; then
    echo "Unresolved build variable in Info.plist:" >&2
    grep '\$(' "$PLIST" >&2
    exit 1
fi
cp -R "$BIN_DIR/AppleTree_AppleTreeCore.bundle" "$APP_DIR/Contents/Resources/"
cp -R "$BIN_DIR/AppleTree_AppleTree.bundle" "$APP_DIR/Contents/Resources/"
cp "$PROJECT_DIR/Sources/AppleTree/Resources/AppleTree.icns" "$APP_DIR/Contents/Resources/AppleTree.icns"
# The Share menu extension. SwiftPM can't build app extensions, so it is compiled directly.
SHARE_DIR="$APP_DIR/Contents/PlugIns/AppleTreeShare.appex/Contents"
rm -rf "$APP_DIR/Contents/PlugIns"
mkdir -p "$SHARE_DIR/MacOS" "$SHARE_DIR/Resources"
swiftc -O -swift-version 6 -parse-as-library -application-extension -module-name AppleTreeShare \
    -target "$(uname -m)-apple-macos14.0" -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$SHARE_DIR/MacOS/AppleTreeShare" "$PROJECT_DIR/ShareExtension/ShareViewController.swift"
cp "$PROJECT_DIR/ShareExtension/Info.plist" "$SHARE_DIR/Info.plist"
cp "$PROJECT_DIR/Sources/AppleTree/Resources/AppleTree.icns" "$SHARE_DIR/Resources/AppleTree.icns"
# Extensions must be sandboxed. Sign it first; --deep on the app would re-sign it without its entitlements.
codesign --force --sign - --entitlements "$PROJECT_DIR/ShareExtension/ShareExtension.entitlements" \
    "$APP_DIR/Contents/PlugIns/AppleTreeShare.appex"
codesign --force --sign - "$APP_DIR"
echo "Built: $APP_DIR"
