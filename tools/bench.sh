#!/bin/bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: tools/bench.sh <DictateBench args…>" >&2
    exit 2
fi

SW="$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"
"$SW" build -c release --product DictateBench
BIN="$("$SW" build -c release --product DictateBench --show-bin-path)/DictateBench"

# Match make-app.sh's persistent login-keychain identity lookup.
SIGNING_IDENTITY_NAME="${DICTATE_SIGNING_IDENTITY:-Archie Dev}"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
SIGNING_IDENTITY_HASH="$(
    /usr/bin/security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null \
        | awk -v name="$SIGNING_IDENTITY_NAME" 'index($0, "\"" name "\"") { print $2; exit }'
)"
if [[ -n "$SIGNING_IDENTITY_HASH" ]]; then
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY_HASH" "$BIN"
else
    echo "WARNING: '$SIGNING_IDENTITY_NAME' unavailable; falling back to ad-hoc signing." >&2
    /usr/bin/codesign --force --sign - "$BIN"
fi

# Keys exist only in the child's environment; do not echo or persist them.
GROQ_API_KEY="$(/usr/bin/security find-generic-password -w -s groq-api -a razakhan)" \
OPENAI_API_KEY="$(/usr/bin/security find-generic-password -w -s openai-api -a razakhan)" \
    "$BIN" "$@"
