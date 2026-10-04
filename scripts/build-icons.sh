#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCE_DIR="$PROJECT_DIR/Sources/AppleTree/Resources"
ICONSET_DIR="$PROJECT_DIR/.build/AppIcon.iconset"
ASSET_DIR="$RESOURCE_DIR/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICONSET_DIR" "$ASSET_DIR"

swift "$PROJECT_DIR/scripts/MakeIcon.swift" "$ICONSET_DIR/icon_512x512@2x.png"
for size in 16 32 128 256 512; do
    for scale in 1 2; do
        pixels=$((size * scale))
        suffix=""
        if [ "$scale" = 2 ]; then suffix="@2x"; fi
        filename="icon_${size}x${size}${suffix}.png"
        if [ "$pixels" != 1024 ]; then
            sips -z "$pixels" "$pixels" "$ICONSET_DIR/icon_512x512@2x.png" --out "$ICONSET_DIR/$filename" >/dev/null
        fi
        cp "$ICONSET_DIR/$filename" "$ASSET_DIR/$filename"
    done
done

python3 - "$ASSET_DIR" <<'PY'
import json
import sys
from pathlib import Path
asset = Path(sys.argv[1])
info = {"author": "xcode", "version": 1}
images = []
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        suffix = "@2x" if scale == 2 else ""
        images.append({"filename": f"icon_{size}x{size}{suffix}.png", "idiom": "mac",
                       "scale": f"{scale}x", "size": f"{size}x{size}"})
(asset / "Contents.json").write_text(json.dumps({"images": images, "info": info}, indent=2) + "\n")
(asset.parent / "Contents.json").write_text(json.dumps({"info": info}, indent=2) + "\n")
PY

iconutil -c icns "$ICONSET_DIR" -o "$RESOURCE_DIR/AppleTree.icns"
echo "Updated AppIcon assets and AppleTree.icns"
