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
    swift build "${args[@]}" "${SWIFT_EXTRA_FLAGS[@]}"
    BIN_DIRS+=("$(swift build "${args[@]}" --show-bin-path)")
done

lipo_product() {
    local name=$1 dest=$2
    lipo -create -output "$dest" $(for dir in "${BIN_DIRS[@]}"; do echo "$dir/$name"; done)
}

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo_product Bullpen "$APP/Contents/MacOS/Bullpen"
lipo_product bp "$OUT/bp"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"

# Ad-hoc signature for local runs. Developer ID signing + notarization come later (PLAN §4.4).
codesign --force --sign - --options runtime "$APP"
codesign --force --sign - --options runtime "$OUT/bp"

lipo -info "$APP/Contents/MacOS/Bullpen" "$OUT/bp"
echo "Built $APP and $OUT/bp ($VERSION)"
