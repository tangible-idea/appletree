#!/bin/bash
# Builds the release app and places a drag-to-Applications dmg plus its metadata in public/downloads/.
set -euo pipefail
SITE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "$SITE_DIR/.." && pwd)"
OUT_DIR="$SITE_DIR/public/downloads"
DMG="$OUT_DIR/AppleTree.dmg"

bash "$ROOT_DIR/scripts/build-app.sh"
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/AppleTree.zip" "$DMG"

# The dmg window shows the app next to an Applications shortcut to drag it onto.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$ROOT_DIR/dist/AppleTree.app" "$STAGING/AppleTree.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname AppleTree -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT_DIR/dist/AppleTree.app/Contents/Info.plist")"
BYTES="$(stat -f%z "$DMG")"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
cat > "$OUT_DIR/release.json" <<JSON
{ "version": "$VERSION", "bytes": $BYTES, "sha256": "$SHA" }
JSON
echo "Packaged: $DMG ($BYTES bytes, v$VERSION)"
