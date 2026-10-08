#!/bin/bash
set -uo pipefail

# Removes the Dictate LaunchAgent; pass --delete-app to also remove the bundle.
# Prints every step it takes. To go back to Wispr Flow afterwards:
#   open -a "Wispr Flow"   (and re-add it under System Settings > General > Login Items)
LABEL="com.razakhan.dictate"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="${DICTATE_APP_PATH:-$HOME/Applications/Dictate.app}"

if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
    launchctl bootout "gui/$UID/$LABEL" && echo "booted out gui/$UID/$LABEL"
else
    echo "not loaded: gui/$UID/$LABEL"
fi
pkill -x Dictate 2>/dev/null && echo "killed running Dictate" || echo "no Dictate process running"

if [[ -f "$PLIST" ]]; then
    rm -f "$PLIST" && echo "removed $PLIST"
else
    echo "no plist at $PLIST"
fi

if [[ "${1:-}" == "--delete-app" ]]; then
    if [[ -d "$APP" ]]; then
        rm -rf "$APP" && echo "deleted $APP"
    else
        echo "no app at $APP"
    fi
else
    echo "kept $APP (pass --delete-app to remove it)"
fi
echo "logs left in place: ~/.claude/logs/dictate.log"
