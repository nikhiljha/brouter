#!/usr/bin/env bash
# Assemble build/brouter.app from the SwiftPM build product.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/brouter.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --package-path "$ROOT"

BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/brouter"
if [ ! -x "$BIN" ]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/brouter"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
"$BIN" configure-bundle "$APP"
if [ -f "$ROOT/Resources/brouter.icns" ]; then
    cp "$ROOT/Resources/brouter.icns" "$APP/Contents/Resources/brouter.icns"
fi
# Mark as a proper bundle for LaunchServices.
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> ad-hoc code signing"
codesign --force --sign - --identifier com.nikhiljha.brouter "$APP"

echo "==> done: $APP"
