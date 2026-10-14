# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/).

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
