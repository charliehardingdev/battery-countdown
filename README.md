# Battery Countdown

Battery Countdown is a lightweight macOS menu bar utility that replaces the
default battery readout with a custom live estimate based on real battery
telemetry and recent usage history.

It stays quiet most of the time, then only shows a yellow bottom-right overlay
when the battery is in its final 30 seconds.

## Features

- Live menu bar time estimate based on current usage trends
- Custom battery glyph and compact menu bar layout
- Rich menu with confidence, trend, recent history, and power snapshot details
- Significant-energy app list using live process heuristics
- Learns over time from recent discharge history to refine estimates
- Final-30-seconds warning overlay in yellow
- Optional launch at login

## How It Estimates Battery Time

The app reads raw battery telemetry from `AppleSmartBattery`, blends live power
draw with observed drain across short and long windows, and applies learned
calibration buckets from prior discharge sessions. The visible estimate is
stabilized so it reacts to real changes without jumping wildly from moment to
moment.

## Build

```bash
cd /Users/charlie/charlie-dev-projects-misc/BatteryCountdown
./scripts/build_app.sh
```

## Run

```bash
open "/Users/charlie/charlie-dev-projects-misc/BatteryCountdown/dist/Battery Countdown.app"
```

Use the menu bar item named `Battery Countdown` to quit the app.

## Start At Login

```bash
cd /Users/charlie/charlie-dev-projects-misc/BatteryCountdown
./scripts/install_autostart.sh
```

To remove the login item later:

```bash
cd /Users/charlie/charlie-dev-projects-misc/BatteryCountdown
./scripts/uninstall_autostart.sh
```

## Open Source

This project is released under the MIT license. See [LICENSE](LICENSE).
