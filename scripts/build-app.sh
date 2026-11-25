#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release "$@"
BIN_DIR="$(swift build -c release --show-bin-path "$@")"
APP="dist/TrioPC.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/TrioPC" "$APP/Contents/MacOS/TrioPC"
cp Resources/Info.plist "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign --force --sign - "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/TrioPC-macOS.zip
echo "Built $PWD/$APP"
