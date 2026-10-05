#!/bin/bash
# Builds the release app and places a downloadable zip plus its metadata in public/downloads/.
set -euo pipefail
SITE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "$SITE_DIR/.." && pwd)"
OUT_DIR="$SITE_DIR/public/downloads"

bash "$ROOT_DIR/scripts/build-app.sh"
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/AppleTree.zip"
ditto -c -k --keepParent "$ROOT_DIR/dist/AppleTree.app" "$OUT_DIR/AppleTree.zip"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT_DIR/dist/AppleTree.app/Contents/Info.plist")"
BYTES="$(stat -f%z "$OUT_DIR/AppleTree.zip")"
SHA="$(shasum -a 256 "$OUT_DIR/AppleTree.zip" | cut -d' ' -f1)"
cat > "$OUT_DIR/release.json" <<JSON
{ "version": "$VERSION", "bytes": $BYTES, "sha256": "$SHA" }
JSON
echo "Packaged: $OUT_DIR/AppleTree.zip ($BYTES bytes, v$VERSION)"
