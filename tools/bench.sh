#!/bin/bash
set -euo pipefail

# Existing installations can keep their identifiers outside the checkout.
BUILD_ENV="$HOME/Library/Application Support/Dictate/build.env"
if [[ -f "$BUILD_ENV" ]]; then
    source "$BUILD_ENV"
fi
DICTATE_SIGNING_IDENTITY="${DICTATE_SIGNING_IDENTITY:-Dictate Dev}"
DICTATE_BUNDLE_ID="${DICTATE_BUNDLE_ID:-dev.dictate.app}"
DICTATE_LABEL="${DICTATE_LABEL:-$DICTATE_BUNDLE_ID}"

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
SIGNING_IDENTITY_NAME="$DICTATE_SIGNING_IDENTITY"
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

# Only cloud modes need a key; local/Apple benchmarks remain usable offline.
case "$1" in
    stt-groq|stt-groq-chunked|cleanup|score-text) NEED_GROQ_KEY=1 ;;
    eval|eval-incremental) [[ "${2:-}" == "groq" ]] && NEED_GROQ_KEY=1 || NEED_GROQ_KEY=0 ;;
    *) NEED_GROQ_KEY=0 ;;
esac
if [[ "$NEED_GROQ_KEY" == 1 ]]; then
    # Key exists only in the child's environment; never echo or persist it.
    GROQ_API_KEY="$(/usr/bin/security find-generic-password -w -s groq-api -a "$(id -un)")" \
        "$BIN" "$@"
else
    "$BIN" "$@"
fi
