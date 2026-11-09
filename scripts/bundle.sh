#!/bin/sh
# Builds a release binary and wraps it in "build/Event Horizon.app" (ad-hoc signed).
set -eu

cd "$(dirname "$0")/.."

swift build -c release --product EventHorizon
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/Event Horizon.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/EventHorizon" "$APP/Contents/MacOS/EventHorizon"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Created $APP"
