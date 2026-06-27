# BShare

BShare is a Flutter/Dart LAN file sharing app inspired by LocalSend. It discovers nearby devices on the same WiFi/LAN and transfers files directly over local HTTP streams.

## Features

- Windows, Linux, macOS, Android, and iOS targets.
- Material 3 responsive interface.
- LAN device discovery with local multicast announcements.
- Internal HTTP receive server.
- Large-file sending and receiving through streams.
- Incoming transfer confirmation.
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

For release distribution:

```bash
flutter build appbundle
```

For full release packaging, installers, and store upload notes, see
[docs/RELEASE.md](docs/RELEASE.md).

### iOS

```bash
flutter build ios
```

Open the generated iOS project in Xcode to configure signing before installing on a device.

## Notes

- BShare stores desktop downloads in `Downloads/BShare`.
- On Android and iOS it defaults to the app documents folder and can be changed from Settings when the platform permits folder selection.
- The protocol is documented in [PROTOCOL.md](PROTOCOL.md).
