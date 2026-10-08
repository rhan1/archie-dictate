#!/bin/bash
set -euo pipefail

# D7: run Dictate at login under launchd. KeepAlive only on a crash, so Quit
# from the menu stays quit until the next login.
LABEL="com.razakhan.dictate"
APP_BIN="${DICTATE_APP_PATH:-$HOME/Applications/Dictate.app}/Contents/MacOS/Dictate"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/.claude/logs"

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
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
echo "==> Loaded $LABEL"
launchctl print "gui/$UID/$LABEL" | grep -E "^\s*(state|pid) =" || true
