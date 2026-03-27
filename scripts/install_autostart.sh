#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"
APP_NAME="BatteryCountdown"
APP_BUNDLE="$ROOT_DIR/dist/Battery Countdown.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/com.charlie.batterycountdown.plist"
LOG_DIR="$ROOT_DIR/logs"

if [[ ! -x "$APP_EXECUTABLE" ]]; then
  echo "App executable not found at:" >&2
  echo "  $APP_EXECUTABLE" >&2
  echo "Build the app first with ./scripts/build_app.sh" >&2
  exit 1
fi

mkdir -p "$LAUNCH_AGENTS_DIR"
mkdir -p "$LOG_DIR"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.charlie.batterycountdown</string>
    <key>ProgramArguments</key>
    <array>
        <string>${APP_EXECUTABLE}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <array>
        <string>Aqua</string>
    </array>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>WorkingDirectory</key>
    <string>${ROOT_DIR}</string>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/launchagent.out.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/launchagent.err.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
launchctl kickstart -k "gui/$(id -u)/com.charlie.batterycountdown"

echo "Installed login launch agent:"
echo "  $PLIST_PATH"
