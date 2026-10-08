#!/bin/bash
set -uo pipefail

# Existing installations can keep their identifiers outside the checkout.
BUILD_ENV="$HOME/Library/Application Support/Dictate/build.env"
if [[ -f "$BUILD_ENV" ]]; then
    source "$BUILD_ENV"
fi
DICTATE_SIGNING_IDENTITY="${DICTATE_SIGNING_IDENTITY:-Dictate Dev}"
DICTATE_BUNDLE_ID="${DICTATE_BUNDLE_ID:-dev.dictate.app}"
DICTATE_LABEL="${DICTATE_LABEL:-$DICTATE_BUNDLE_ID}"

# Removes the Dictate LaunchAgent; pass --delete-app to also remove the bundle.
# Prints every step it takes. To go back to Wispr Flow afterwards:
#   open -a "Wispr Flow"   (and re-add it under System Settings > General > Login Items)
LABEL="$DICTATE_LABEL"
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
echo "logs left in place: $HOME/Library/Logs/Dictate/dictate.log"
