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

# Builds ~/Applications/Dictate.app from the Dictate product.
#
# The toolchain is PINNED to the 6.3.3 release: a .build made
# by the Command Line Tools' 6.2.4 makes the 6.3.3 test runner discover zero
# tests while exiting 0, which looks exactly like a pass.
SW="$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

echo "==> Building Dictate release binary ($SW)..."
"$SW" build -c release --product Dictate

RELEASE_BIN="$("$SW" build -c release --product Dictate --show-bin-path)/Dictate"
if [[ ! -f "$RELEASE_BIN" ]]; then
    echo "ERROR: Release binary not found at $RELEASE_BIN" >&2
    exit 1
fi

APP_PATH="${DICTATE_APP_PATH:-$HOME/Applications/Dictate.app}"
CONTENTS="$APP_PATH/Contents"
MACOS="$CONTENTS/MacOS"

echo "==> Assembling bundle at $APP_PATH..."
# Start from an empty Contents so a rebuild never leaves stale files inside a signed bundle.
rm -rf "$CONTENTS"
mkdir -p "$MACOS" "$CONTENTS/Resources"
cp "$RELEASE_BIN" "$MACOS/Dictate"
cp "$REPO_DIR/Resources/vocab-hints.sample.txt" "$CONTENTS/Resources/vocab-hints.sample.txt"
chmod +x "$MACOS/Dictate"

# LSUIElement: menu-bar only, no Dock icon. The microphone usage string must be
# in place BEFORE codesign seals the bundle.
cat << PLIST > "$CONTENTS/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>Dictate</string>
	<key>CFBundleExecutable</key>
	<string>Dictate</string>
	<key>CFBundleIdentifier</key>
	<string>$DICTATE_BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Dictate</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>Dictate records only while you dictate (between ⌥⌥ and the finishing ⌥ tap) and sends the audio to Groq for transcription, with Apple's on-device recognition as a fallback. Nothing is saved.</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

# A STABLE signing identity, not ad-hoc: macOS ties the Accessibility and
# Microphone grants to the signature, and a fresh ad-hoc signature on every
# rebuild revokes them. tools/ensure-signing-identity.sh can create the default
# self-signed "Dictate Dev" identity; override it through build.env or the environment.
SIGNING_IDENTITY_NAME="$DICTATE_SIGNING_IDENTITY"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
SIGNING_IDENTITY_HASH="$(
    /usr/bin/security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null \
        | awk -v name="$SIGNING_IDENTITY_NAME" 'index($0, "\"" name "\"") { print $2; exit }'
)"

if [[ -n "$SIGNING_IDENTITY_HASH" ]]; then
    echo "==> Codesigning with persistent identity: $SIGNING_IDENTITY_NAME"
    /usr/bin/codesign --force --deep --sign "$SIGNING_IDENTITY_HASH" "$APP_PATH"
else
    echo "WARNING: '$SIGNING_IDENTITY_NAME' unavailable; falling back to ad-hoc (TCC grants will not survive rebuilds)." >&2
    /usr/bin/codesign --force --deep --sign - "$APP_PATH"
fi

echo "==> Bundle complete: $APP_PATH"
/usr/bin/codesign -dv "$APP_PATH" 2>&1 | grep -E "Identifier|Authority|Signature" || true
