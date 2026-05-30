#!/usr/bin/env bash
# Stop the agent and remove the installed app + LaunchAgent.
set -euo pipefail

LABEL="com.nikhiljha.brouter"
UID_NUM="$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> stopping agent"
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true

echo "==> removing LaunchAgent"
rm -f "$PLIST"

for DEST in "/Applications/brouter.app" "$HOME/Applications/brouter.app"; do
    if [ -d "$DEST" ]; then
        echo "==> removing $DEST"
        rm -rf "$DEST"
    fi
done

echo "Done. Set a new default browser in System Settings → Desktop & Dock."
