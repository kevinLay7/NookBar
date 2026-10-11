#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)
APP_DIR="$PWD/build/NookBar.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN_DIR/NookBar" "$APP_DIR/Contents/MacOS/NookBar"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
SIGNING_IDENTITY="${NOOKBAR_SIGNING_IDENTITY:--}"
if [[ "$SIGNING_IDENTITY" == "-" && -f .signing-identity ]]; then
    SIGNING_IDENTITY=$(cat .signing-identity)
fi
codesign --force --sign "$SIGNING_IDENTITY" "$APP_DIR"
printf 'Built %s\n' "$APP_DIR"
