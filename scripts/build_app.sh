#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"
APP_NAME="BatteryCountdown"
APP_DIR="$ROOT_DIR/dist/Battery Countdown.app"

swift build -c release

BINARY_PATH="$ROOT_DIR/.build/release/$APP_NAME"
if [[ ! -f "$BINARY_PATH" ]]; then
  echo "Build failed: binary not found at $BINARY_PATH" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

echo "Built app bundle at:"
echo "  $APP_DIR"
