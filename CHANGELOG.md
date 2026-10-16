# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.4.1] - 2026-10-16

### Added
- Auto-update from GitHub: the About dialog checks the latest release, picks the
  64-bit or 32-bit APK for the device, downloads it with a progress bar and
  opens the Android installer.

## [0.4.0] - 2026-10-16

### Added
- Landscape layout: gauges on the left half, voltage chart and buttons on the
  right half, with device, clock and status centered in the top bar.

## [0.3.0] - 2026-10-14

### Added
- Automatic reconnection: when the sensor disconnects (for example when the car
  is turned off) or is not found, the app retries every 15 seconds.
- Foreground service with a silent notification, so the connection and the
  reconnection loop keep working with the app in the background.
- "Clear history" action in the Bluetooth connection dialog (with confirmation).
- No scanning or retrying while Bluetooth is off; the app resumes by itself when
  Bluetooth is turned on.

### Changed
- The refresh button only reconnects; it no longer clears the stored history.

## [0.2.0] - 2026-10-14

### Added
- Analog gauge with colored status bands and a large blue digital readout.
- Charging status, rapid acceleration / deceleration counters.
- Last engine start voltage.
- Temperature sparkline (last minute).
- Device MAC with rename (stored per device).
- Colored status bands and "Volts" axis title on the voltage chart.
- About dialog and version label.
- Data simulation (play button) for UI testing without a sensor.

- App icon and small logo on the home screen.
- Per-device history stored on the phone; refresh clears it (with confirmation).
- Chart tooltip shows voltage and time.
- SoC dial colored by level (blue / orange / red).

### Changed
- Voltage is now read as a full 16-bit value.
- The real-time command is sent once; empty / acknowledge frames are ignored.

## [0.1.0] - 2026-10-14

### Added
- Home screen with the current battery voltage and a real-time chart.
- Raw data screen showing the encrypted and decrypted BLE packets (debug log).
- Bluetooth connection info dialog.
- Light / dark mode toggle.
- Automatic scan, connect and reconnect for BM6 devices.
