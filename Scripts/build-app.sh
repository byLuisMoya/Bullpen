#!/usr/bin/env bash
# Builds a Universal (arm64 + x86_64) Bullpen.app and the `bp` CLI into ./build.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/env.sh

CONFIG=${CONFIG:-release}
ARCHS=(arm64 x86_64)
OUT=build
APP="$OUT/Bullpen.app"
VERSION=$(sed -n 's/.*static let version = "\(.*\)"/\1/p' Sources/BPCore/Bullpen.swift)

rm -rf "$OUT" && mkdir -p "$OUT"
BIN_DIRS=()
for arch in "${ARCHS[@]}"; do
    args=(-c "$CONFIG" --triple "$arch-apple-macosx14.0" --scratch-path ".build/$arch")
    swift build "${args[@]}" ${SWIFT_EXTRA_FLAGS[@]+"${SWIFT_EXTRA_FLAGS[@]}"}
    BIN_DIRS+=("$(swift build "${args[@]}" --show-bin-path)")
done

lipo_product() {
    local name=$1 dest=$2
    lipo -create -output "$dest" $(for dir in "${BIN_DIRS[@]}"; do echo "$dir/$name"; done)
}

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo_product Bullpen "$APP/Contents/MacOS/Bullpen"
lipo_product bpd "$APP/Contents/MacOS/bpd"
lipo_product bp "$APP/Contents/MacOS/bp"   # used by agent hooks
lipo_product bp "$OUT/bp"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/AppIcon-halloween.png Resources/AppIcon-christmas.png "$APP/Contents/Resources/"
# Local builds get the demo script ("Probar con una demo"); releases (DIST=1) don't.
if [[ "${DIST:-0}" != "1" ]]; then cp Scripts/demo.sh "$APP/Contents/Resources/demo.sh"; fi

# No Apple Developer ID: signed with a fixed self-signed certificate (Scripts/signing-identity.sh)
# so every version keeps the same identity and macOS doesn't ask for Keychain and privacy
# permissions again after each update. Ad-hoc only when the certificate isn't there; releases need it.
IDENTITY=${BULLPEN_SIGN_IDENTITY:-Bullpen Self-Signed}
SIGNING_KEYCHAIN="$HOME/Library/Keychains/bullpen-signing.keychain-db"
if [[ -f "$SIGNING_KEYCHAIN" ]] && security find-certificate -c "$IDENTITY" "$SIGNING_KEYCHAIN" >/dev/null 2>&1; then
    security unlock-keychain -p bullpen "$SIGNING_KEYCHAIN"
    SIGN=(--sign "$IDENTITY" --keychain "$SIGNING_KEYCHAIN")
elif [[ "${DIST:-0}" == "1" ]]; then
    echo "Falta el certificado de firma: ejecuta Scripts/signing-identity.sh" >&2
    exit 1
else
    echo "warning: sin certificado de firma, firma ad-hoc (los permisos se pedirán de nuevo)" >&2
    SIGN=(--sign -)
fi
codesign --force "${SIGN[@]}" --options runtime "$APP/Contents/MacOS/bpd"
codesign --force "${SIGN[@]}" --options runtime "$APP/Contents/MacOS/bp"
codesign --force "${SIGN[@]}" --options runtime "$APP"
codesign --force "${SIGN[@]}" --options runtime "$OUT/bp"

lipo -info "$APP/Contents/MacOS/Bullpen" "$APP/Contents/MacOS/bpd" "$OUT/bp"
echo "Built $APP and $OUT/bp ($VERSION)"
