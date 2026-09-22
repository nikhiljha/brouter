#!/usr/bin/env bash
# Render .github/assets/icon.html and build Resources/brouter.icns. Needs Google Chrome.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$CHROME" --headless=new --hide-scrollbars --default-background-color=00000000 \
    --window-size=1024,1024 --force-device-scale-factor=1 \
    --screenshot="$TMP/icon.png" "file://$ROOT/.github/assets/icon.html" 2>/dev/null

ICONSET="$TMP/brouter.iconset"
mkdir "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$TMP/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$TMP/icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/brouter.icns"
echo "wrote Resources/brouter.icns"
