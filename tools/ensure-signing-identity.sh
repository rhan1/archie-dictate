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

LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
IDENTITY_HASH="$(
    /usr/bin/security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null \
        | awk -v name="$DICTATE_SIGNING_IDENTITY" 'index($0, "\"" name "\"") { print $2; exit }'
)"
if [[ -n "$IDENTITY_HASH" ]]; then
    echo "==> Signing identity already exists: $DICTATE_SIGNING_IDENTITY"
    exit 0
fi

echo "==> Creating signing identity: $DICTATE_SIGNING_IDENTITY"
echo "macOS will show a GUI trust/password prompt; enter your login password to trust this code-signing certificate." >&2
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dictate-signing.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
PASSWORD="$(/usr/bin/openssl rand -hex 24)"
export DICTATE_CERT_PASSWORD="$PASSWORD"

cat > "$WORK_DIR/cert.cnf" << 'CONFIG'
[req]
prompt = no
distinguished_name = subject
x509_extensions = extensions
[subject]
CN = $ENV::DICTATE_SIGNING_IDENTITY
[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
CONFIG
export DICTATE_SIGNING_IDENTITY
/usr/bin/openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -config "$WORK_DIR/cert.cnf" -keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem"
/usr/bin/openssl pkcs12 -export -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/cert.pem" \
    -name "$DICTATE_SIGNING_IDENTITY" -out "$WORK_DIR/identity.p12" -passout env:DICTATE_CERT_PASSWORD
/usr/bin/security import "$WORK_DIR/identity.p12" -k "$LOGIN_KEYCHAIN" \
    -P "$PASSWORD" -T /usr/bin/codesign
/usr/bin/security add-trusted-cert -r trustRoot -p codeSign \
    -k "$LOGIN_KEYCHAIN" "$WORK_DIR/cert.pem"
unset DICTATE_CERT_PASSWORD PASSWORD
echo "==> Signing identity ready: $DICTATE_SIGNING_IDENTITY"
