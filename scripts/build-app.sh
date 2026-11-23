#!/usr/bin/env bash
# Builds release binaries and assembles an ad-hoc signed "Permission Popups.app" in dist/.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Permission Popups.app"
ARCHS=(--arch arm64 --arch x86_64)

if ! swift build -c release "${ARCHS[@]}"; then
    echo "note: universal build failed; falling back to the host architecture" >&2
    ARCHS=()
    swift build -c release
fi
BIN_DIR=$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN_DIR/PermissionApp" "$BIN_DIR/permission-hook" "$APP/Contents/MacOS/"

codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"
echo "Built $APP"
