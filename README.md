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
- Screen capture settings: 480p, 720p, 1080p, 1440p or original size, and 15/24/30/60 FPS limits.
- Phone camera video over Wi-Fi or a USB tethering network, with front/rear switching and independent camera settings (up to 60 FPS).
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

## Installers from GitHub Actions

The **Build installers** workflow generates a Windows EXE, Linux DEB/RPM and a
signed universal Android APK on pushes to `main` or a manual run. Its shared
quality gate finishes before the three platform builds start. Download installers
from the completed run's **Artifacts** section.

Product and installer metadata use **BShare**. Android uses a permanent signing
key stored in GitHub Secrets, with private backup kept outside the repository.
See [docs/RELEASE.md](docs/RELEASE.md) for artifact names, signing and local builds.

## Build

### Windows

```bash
flutter build windows
```

### Linux

```bash
flutter build linux
```

To generate the distributable Debian/Ubuntu package for 64-bit PCs:

```bash
bash scripts/build_deb.sh
```

The package declares the library versions required by its actual build. CI builds
on Ubuntu 22.04 and checks DEB/RPM installation on Ubuntu and Fedora. Local builds
on newer systems can require newer distributions. Install the DEB with
`sudo apt install ./bshare_<version>_amd64.deb`.

For Linux desktop setup, hotspot requirements, and the environment checker,
see [docs/LINUX.md](docs/LINUX.md).

### macOS

```bash
flutter build macos
```

### Android

The Android configuration uses a minimum API of 24 (Android 7) and target API 36
(Android 16). Available release architectures are ARM32 (`armeabi-v7a`), ARM64
(`arm64-v8a`) and x64 (`x86_64`). Feature availability still depends on the OS and
hardware; creating a local hotspot requires Android 8 or newer.

For a universal release APK containing those three architectures:

```bash
flutter build apk --release --target-platform android-arm,android-arm64,android-x64
```

For the 64-bit release APK (`arm64-v8a`):

```bash
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

The generated APK is at
`build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`.

Verify that release optimization retains the constructors used by the Android
QR scanner:

```bash
python3 tool/verify_android_qr_release.py build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

This inspects the compiled APK; camera behavior still requires a device test.
See the [QR diagnosis and validation notes](docs/PERFORMANCE.md#android-qr-scanner-release-diagnosis).

Check native ABI coverage and ELF/ZIP packaging for 16 KB page-size devices:

```bash
python3 tool/verify_android_native_compat.py build/app/outputs/flutter-apk/app-release.apk --require-abi armeabi-v7a --require-abi arm64-v8a --require-abi x86_64
```

This is a packaging inspection. OS, hardware and 16 KB runtime validation are
recorded separately in [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

For full release packaging, installers, and store upload notes, see
[docs/RELEASE.md](docs/RELEASE.md).

### iOS

```bash
flutter build ios
```

Open the generated iOS project in Xcode to configure signing before installing on a device.

## Notes

- On mobile, open **Share screen** or **Device camera** from Home. Both are also available in the desktop menu; the mobile menu keeps Home, Send, Receive and Transfers. The desktop sidebar fills the window height and scrolls in short windows.
- For camera video over Wi-Fi, start sharing on the phone, then open Device camera on the computer, select the phone and choose Watch camera. The microphone starts off and can be enabled from the broadcast controls to send audio with video.
- For camera video over USB, connect a data cable and enable USB tethering on Android. Select USB on both devices, then enter the phone's displayed USB address and port on the computer. A working wired network is required; the USB option does not switch to Wi-Fi when it is missing. USB interface detection is implemented for Android sources and Linux/Windows/macOS receivers; iOS sources currently use Wi-Fi.
- Camera resolution/FPS settings are separate from screen sharing. Configure the rear/front profiles in Settings. The chosen profile applies on the next camera start or camera switch. Original size lets the camera driver choose its format; supported cameras and actual cadence depend on the device.
- During camera sharing, the mobile display stays awake and dims after one minute without touch input. Touch the dark overlay to restore it; camera video continues. Stop sharing restores display state and releases a receiver started for that stream, while an independently started file receiver remains available.
- Send, Devices and Screen start discovery automatically. The initial/manual search indicator runs for 12 seconds; discovery continues listening afterward.
- Change screen capture resolution and frame rate in Settings before starting the next transmission. Resolution limits the shorter edge without stretching or upscaling; WebRTC can lower quality or frame rate according to source, device and connection conditions.
- Both Back controls return through visited tabs and close finished file selectors without reopening them. Returning Home clears that navigation history.
- BShare stores desktop downloads in `Downloads/BShare`.
- On Android, received files are saved in the device's `Download` folder by default.
- Android shared-folder access uses storage permission through Android 10 and all-files access from Android 11. Denial keeps the selected destination unchanged; camera/screen signaling does not request file access. Wi-Fi and notification requests are gated by OS version and operation.
- The local `flutter_background` fork keeps the file-transfer service non-sticky: if Android kills the app after a permission change, it must be explicitly started again. A native service cannot resume a lost Dart receiver by itself. Stop releases the service's CPU and Wi-Fi locks.
- On iOS, downloads default to the app documents folder and can be changed from Settings when the platform permits folder selection.
- QR scanning uses `mobile_scanner`, which already integrates ML Kit on Android and Apple Vision on iOS. Android includes the barcode model in the app.
- The protocol is documented in [PROTOCOL.md](PROTOCOL.md).
- Reproducible benchmarks and lifecycle validation are documented in [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## 1.0.2

- Separate Transfers from the Receive screen and automatically open it for incoming files.
- Keep Android transfers running in the background and prevent the receiver from being stopped while transfers are active.
- Save Android downloads directly in `Download`.
- Order the Android media picker chronologically across photos and videos.
- Improve screen sharing, full-screen viewing, and the desktop navigation layout.
