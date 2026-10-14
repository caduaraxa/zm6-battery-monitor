# ZM6 Battery Monitor

Android app (Flutter) that reads voltage from **BM6 BLE battery monitors**
directly over the phone's Bluetooth, no vendor app required.

This project is a Flutter port of
[JeffWDH/bm6-battery-monitor](https://github.com/JeffWDH/bm6-battery-monitor)
(Python). The BLE protocol was implemented from that project.

## Features

- Current battery voltage (V)
- Real-time voltage chart (last 120 samples)
- Raw data screen: TX / RX packets, decrypted payload and parsed values
- Bluetooth connection info (status, device name, address)
- Light / dark mode
- Auto-connects to the first device advertising as `BM6`

## How it works

1. Scans for a BLE device named `BM6`.
2. Writes the AES-128 encrypted command `d1550700...` to characteristic `FFF3`.
3. Subscribes to notifications on `FFF4` and decrypts each 16-byte packet.
4. Packets starting with `d15507` carry the readings:
   voltage (`byte 7` low nibble + `byte 8`, / 100), temperature (`byte 4`,
   sign in `byte 3`) and state of charge (`byte 6`).

The command is re-sent every 3 seconds to keep the data flowing.

## Requirements

- Android 6.0+ (tested on Android 16, arm64)
- [Flutter](https://docs.flutter.dev/get-started/install) 3.x
- A BM6 battery monitor

## Build

```
flutter pub get
flutter build apk --release --target-platform android-arm64
```

The APK is generated at `build/app/outputs/flutter-apk/app-release.apk`.

## Permissions

On first launch the app asks for Bluetooth and location access. Android
requires location permission for BLE scanning; the location is not used.

## Versioning

[Semantic Versioning](https://semver.org/). The version lives in `pubspec.yaml`
(`version: MAJOR.MINOR.PATCH+BUILD`). See [CHANGELOG.md](CHANGELOG.md).

## Credits

- [JeffWDH/bm6-battery-monitor](https://github.com/JeffWDH/bm6-battery-monitor) - original Python implementation
- [KrystianD/bm2-battery-monitor](https://github.com/KrystianD/bm2-battery-monitor/blob/master/.docs/reverse_engineering.md)
- [doubleagent.net - BM2 BLE protocol](https://doubleagent.net/bm2-reversing-the-ble-protocol-of-the-bm2-battery-monitor/)

## License

[MIT](LICENSE)
