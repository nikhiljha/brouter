#!/usr/bin/env bash
# Build, install brouter.app, register it, and start the launchd agent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.nikhiljha.brouter"
UID_NUM="$(id -u)"
LOG="$HOME/Library/Logs/brouter.log"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# 1) Build the .app bundle.
"$ROOT/scripts/bundle.sh" release

# 2) Choose an install location (prefer /Applications, fall back to ~/Applications).
DEST_DIR="/Applications"
if [ ! -w "$DEST_DIR" ]; then
    DEST_DIR="$HOME/Applications"
    mkdir -p "$DEST_DIR"
fi
DEST="$DEST_DIR/brouter.app"

echo "==> installing to $DEST"
# Stop a running agent before replacing the bundle.
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
rm -rf "$DEST"
cp -R "$ROOT/build/brouter.app" "$DEST"

# 3) Register with LaunchServices so it shows up as a browser option.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    echo "==> registering with LaunchServices"
    # Drop the build/ copy so there aren't two apps with the same bundle id
    # (a duplicate registration breaks setting the default browser).
    "$LSREGISTER" -u "$ROOT/build/brouter.app" 2>/dev/null || true
    "$LSREGISTER" -f "$DEST"
fi

# 4) Install + load the LaunchAgent.
echo "==> installing LaunchAgent ($PLIST)"
mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$LOG")"
sed -e "s#__APP__#$DEST#g" -e "s#__LOG__#$LOG#g" \
    "$ROOT/LaunchAgents/$LABEL.plist" > "$PLIST"

if launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>/dev/null; then
    :
else
    launchctl load -w "$PLIST" 2>/dev/null || true
fi
launchctl kickstart -k "gui/$UID_NUM/$LABEL" 2>/dev/null || true

echo ""
echo "brouter installed and running."
echo "  App:    $DEST"
echo "  Agent:  $PLIST"
echo "  Log:    $LOG"
echo "  Config: $("$DEST/Contents/MacOS/brouter" config-path)"
echo ""
echo "Make it your default browser with EITHER:"
echo "  \"$DEST/Contents/MacOS/brouter\" set-default \"$DEST\""
echo "  (or)  System Settings → Desktop & Dock → Default web browser → brouter"
