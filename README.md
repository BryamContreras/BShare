# BShare

BShare is a Flutter/Dart LAN file sharing app inspired by LocalSend. It discovers nearby devices on the same WiFi/LAN and transfers files directly over local HTTP streams.

Current version: **1.0.2**

## Features

- Windows, Linux, macOS, Android, and iOS targets.
- Material 3 responsive interface.
- LAN device discovery with local multicast announcements.
- Internal HTTP receive server.
- Large-file sending and receiving through streams.
- Multiple simultaneous transfers, with live transfer speed and controls.
- Incoming transfer confirmation.
- Dedicated Transfers screen for incoming, outgoing, pending, and completed files.
- Android foreground execution for file transfers, so they can continue when the app is in the background.
- Screen sharing and a full-screen remote viewer.
- Local transfer history with Hive.
- Local settings with SharedPreferences.

## Requirements

- Flutter stable with Dart 3.12 or newer.
- Platform toolchains for the targets you want to build.
- Devices must be on the same LAN/WiFi.
- Firewalls must allow the chosen BShare port, default `53317`, and multicast discovery on `53318`.

## Run

```bash
flutter pub get
flutter run
```

## Build

### Windows

```bash
flutter build windows
```

### Linux

```bash
flutter build linux
```

For Linux desktop setup, hotspot requirements, and the environment checker,
see [docs/LINUX.md](docs/LINUX.md).

### macOS

```bash
flutter build macos
```

### Android

```bash
flutter build apk
```

For the 64-bit release APK (`arm64-v8a`):

```bash
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

The generated APK is at
`build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`.

For full release packaging, installers, and store upload notes, see
[docs/RELEASE.md](docs/RELEASE.md).

### iOS

```bash
flutter build ios
```

Open the generated iOS project in Xcode to configure signing before installing on a device.

## Notes

- BShare stores desktop downloads in `Downloads/BShare`.
- On Android, received files are saved in the device's `Download` folder by default.
- On iOS, downloads default to the app documents folder and can be changed from Settings when the platform permits folder selection.
- The protocol is documented in [PROTOCOL.md](PROTOCOL.md).

## 1.0.2

- Separate Transfers from the Receive screen and automatically open it for incoming files.
- Keep Android transfers running in the background and prevent the receiver from being stopped while transfers are active.
- Save Android downloads directly in `Download`.
- Order the Android media picker chronologically across photos and videos.
- Improve screen sharing, full-screen viewing, and the desktop navigation layout.
