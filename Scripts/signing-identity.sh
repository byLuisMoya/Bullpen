#!/usr/bin/env bash
# Creates, once, the self-signed certificate Bullpen is signed with, in a keychain of its own
# (~/Library/Keychains/bullpen-signing.keychain-db, password "bullpen") so `codesign` can use it
# without asking for the login password.
# Without an Apple Developer ID, an ad-hoc signature changes with every build, and macOS then
# treats each update as a new app: Keychain items and privacy permissions ask again. A fixed
# certificate keeps the app's identity, so "Permitir siempre" survives updates.
set -euo pipefail
NAME=${BULLPEN_SIGN_IDENTITY:-Bullpen Self-Signed}
KEYCHAIN="$HOME/Library/Keychains/bullpen-signing.keychain-db"
PASSWORD=bullpen

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "$NAME ya existe"
    exit 0
fi
[ -f "$KEYCHAIN" ] || security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"   # no auto-lock
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
# In the search list, so codesign finds the identity by name.
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KEYCHAIN"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/cert.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
# The Keychain only reads PKCS#12 with the old algorithms.
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$NAME" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -passout pass:bullpen -out "$work/id.p12"
security import "$work/id.p12" -k "$KEYCHAIN" -P bullpen -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
echo "Creado $NAME"
