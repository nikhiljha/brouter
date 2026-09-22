#!/usr/bin/env bash
# Build dist/brouter-<version>-arm64.dmg. Needs Apple Silicon, uv, and Google Chrome.
# The app is built against an empty config, so it only declares http and https.
set -euo pipefail

VERSION="${1:?usage: scripts/dmg.sh <version>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/brouter.app"
DMG="$ROOT/dist/brouter-$VERSION-arm64.dmg"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ "$(uname -m)" = "arm64" ] || { echo "error: build on Apple Silicon" >&2; exit 1; }

BROUTER_CONFIG="$TMP/no-config.js" VERSION="$VERSION" "$ROOT/scripts/bundle.sh" release
[ "$(lipo -archs "$APP/Contents/MacOS/brouter")" = "arm64" ] || { echo "error: expected an arm64 binary" >&2; exit 1; }

echo "==> rendering DMG background"
for scale in 1 2; do
    "$CHROME" --headless=new --hide-scrollbars --window-size=640,400 --force-device-scale-factor=$scale \
        --screenshot="$TMP/background@${scale}x.png" "file://$ROOT/.github/assets/dmg-background.html" 2>/dev/null
done
tiffutil -cathidpicheck "$TMP/background@1x.png" "$TMP/background@2x.png" -out "$TMP/background.tiff" >/dev/null

echo "==> building $DMG"
mkdir -p "$ROOT/dist"
rm -f "$DMG"
uvx --from dmgbuild==1.6.7 dmgbuild -s "$ROOT/scripts/dmg-settings.py" \
    -D app="$APP" -D background="$TMP/background.tiff" brouter "$DMG"

# Keep LaunchServices from treating the build/ copy as a second brouter.app.
"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" \
    -u "$APP" 2>/dev/null || true

echo "==> done: $DMG"
