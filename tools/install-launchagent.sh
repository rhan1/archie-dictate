#!/bin/bash
set -euo pipefail

# Safe check-only mode exits before sourcing config or touching launchd/processes.
FORCE=0
CHECK_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --check-only) CHECK_ONLY=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done
check_mute_pending() {
    local state_path="${DICTATE_MUTED_STATE_FILE:-$HOME/Library/Application Support/Dictate/muted.state}"
    if [[ "$FORCE" != 1 && -e "$state_path" ]]; then
        echo "dictation in progress or mute pending — retry in a few seconds" >&2
        return 3
    fi
}
check_mute_pending || exit 3
if [[ "$CHECK_ONLY" == 1 ]]; then exit 0; fi

# Existing installations can keep their identifiers outside the checkout.
BUILD_ENV="$HOME/Library/Application Support/Dictate/build.env"
if [[ -f "$BUILD_ENV" ]]; then
    source "$BUILD_ENV"
fi
DICTATE_SIGNING_IDENTITY="${DICTATE_SIGNING_IDENTITY:-Dictate Dev}"
DICTATE_BUNDLE_ID="${DICTATE_BUNDLE_ID:-dev.dictate.app}"
DICTATE_LABEL="${DICTATE_LABEL:-$DICTATE_BUNDLE_ID}"

# D7: run Dictate at login under launchd. KeepAlive only on a crash, so Quit
# from the menu stays quit until the next login.
LABEL="$DICTATE_LABEL"
APP_BIN="${DICTATE_APP_PATH:-$HOME/Applications/Dictate.app}/Contents/MacOS/Dictate"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/Dictate"

if [[ ! -x "$APP_BIN" ]]; then
    echo "ERROR: $APP_BIN missing — run tools/make-app.sh first." >&2
    exit 1
fi
mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"

cat > "$PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$APP_BIN</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>Crashed</key>
		<true/>
	</dict>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardErrorPath</key>
	<string>$LOG_DIR/dictate.stderr.log</string>
	<key>StandardOutPath</key>
	<string>$LOG_DIR/dictate.stderr.log</string>
</dict>
</plist>
PLIST
plutil -lint "$PLIST"

# Re-bootstrap cleanly if an older copy is loaded.
check_mute_pending || exit 3
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
for ((i = 0; i < 25; i++)); do
    if ! launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
        break
    fi
    sleep 0.2
done
launchctl bootstrap "gui/$UID" "$PLIST"
echo "==> Loaded $LABEL"
launchctl print "gui/$UID/$LABEL" | grep -E "^\s*(state|pid) =" || true
