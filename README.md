# BShare

BShare is a Flutter/Dart LAN file sharing app inspired by LocalSend. It discovers nearby devices on the same WiFi/LAN and transfers files directly over local HTTP streams.

Current version: **1.0.3**

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

Version tags such as `v1.0.3` build and publish individual installer files in
[GitHub Releases](https://github.com/BryamContreras/BShare/releases): ARM32 and
ARM64 Android APKs, a Windows installer, Linux DEB/RPM packages, and macOS ARM64
and x64 DMGs. The build jobs upload each installer directly to a draft Release;
after all builds pass, the workflow publishes the individual files and checksums.
It does not generate ZIP artifacts. Pushes to `main` run the quality gate without
building installers. This repository is open source under the MIT License;
dependency licenses remain in their respective third-party directories.

Product and installer metadata use **BShare**. Android uses a permanent signing
key stored in GitHub Secrets, with private backup kept outside the repository.
See [docs/RELEASE.md](docs/RELEASE.md) for installer names, signing and local builds.

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

GitHub Releases include separate `.dmg` installers for Apple Silicon (`arm64`)
and Intel (`x64`). Local `scripts/build_releases.sh --macos-only` packages the
architecture of the Mac where it runs. macOS apps are ad-hoc signed and are not
notarized; Gatekeeper may require opening the app from Finder's context menu.

### Android

The Android configuration uses a minimum API of 24 (Android 7) and target API 36
(Android 16). GitHub Releases provide separate ARM32 (`armeabi-v7a`) and ARM64
(`arm64-v8a`) APKs. Feature availability still depends on the OS and hardware;
creating a local hotspot requires Android 8 or newer.

Build both ARM APKs separately:

```bash
flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64
```

The generated files are `app-armeabi-v7a-release.apk` and
`app-arm64-v8a-release.apk` in `build/app/outputs/flutter-apk/`.
Each APK contains one ABI and is signed with the release key in CI.

Verify either APK's QR scanner constructors and native packaging:

```bash
python3 tool/verify_android_qr_release.py build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
python3 tool/verify_android_native_compat.py build/app/outputs/flutter-apk/app-arm64-v8a-release.apk --require-abi arm64-v8a
python3 tool/verify_android_native_compat.py build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk --require-abi armeabi-v7a
```

This inspects the compiled APK; camera behavior still requires a device test.
See the [QR diagnosis and validation notes](docs/PERFORMANCE.md#android-qr-scanner-release-diagnosis).

These are static packaging inspections; OS, hardware and 16 KB runtime
validation are recorded separately in [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

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

See [CHANGELOG.md](CHANGELOG.md) for release notes.

## License

BShare application code is available under the [MIT License](LICENSE). Third-party
components retain the licenses and notices in their own directories.
