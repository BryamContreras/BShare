# BShare

[Support development on Ko-fi](https://ko-fi.com/SoyBryam06c)

BShare is a Flutter/Dart app for local file transfers and live camera/screen viewing across devices. It discovers nearby devices over Wi-Fi or Ethernet and transfers files directly over local HTTP streams. Android phone video and audio can also use an authorized USB data cable.

Current version: **1.0.5**

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
- Screen sharing and a native desktop fullscreen viewer, with controls that hide after three seconds and Esc to return without disconnecting.
- Android screen sharing can include device playback audio (Android 10+), without recording the microphone. Apps may restrict audio capture.
- LAN screen sharing shows a copyable IP and listening port. Phone camera broadcasts start with their preview hidden and show the address as plain text below the sharing message; showing that preview hides the address. USB uses device selection and the phone's BShare port instead of a LAN IP.
- Screen capture settings: 480p, 720p, 1080p, 1440p or original size, and 15/24/30/60 FPS limits.
- Android camera and screen video over Wi-Fi/LAN or a normal USB data cable, with no USB tethering required. Camera sharing supports front/rear switching and independent capture settings (up to 60 FPS).
- System virtual camera with clean received video and an automatic waiting image on Windows 11 x64 and supported Linux installations. Desktop phone controls appear in a right-hand menu; local preview, JPEG photos and MP4 recordings have a separate left-hand panel. See [virtual camera setup](docs/VIRTUAL_CAMERA.md).
- Native phone zoom, lens selection, white balance, EV brightness and supported manual shutter/ISO controls from the computer, using the current camera's reported capabilities. Zoom and supported cool/warm white balance respond while dragging.
- On Windows and Linux, save received camera photos as JPEG and video as H.264/AAC MP4 on the computer. Turn the PC preview off while recording and virtual camera output continue. Each action appears above its own folder; a saved-file notice at the foot of the menu expires after ten seconds.
- Local transfer history with Hive.
- Local settings with SharedPreferences.

## Requirements

- Flutter stable with Dart 3.12 or newer.
- Platform toolchains for the targets you want to build.
- LAN file transfers and wireless streaming require devices on the same LAN/Wi-Fi. Android USB streaming uses a data cable, USB debugging and computer authorization instead.
- For LAN connections, firewalls must allow BShare's inbound TCP listener (default `53317`), UDP discovery on `53318`, and negotiated UDP ports for screen/camera video. The Windows installer offers optional access limited to private local networks; see [network troubleshooting](docs/STREAMING_COMPATIBILITY.md) and [firewall setup](docs/RELEASE.md#windows).
- Linux photo/video saving requires the packaged GStreamer codecs; its virtual camera additionally needs a working v4l2loopback driver. macOS has no BShare virtual-camera extension or local JPEG/MP4 backend in this release. See [desktop media support](docs/VIRTUAL_CAMERA.md#audio-and-platform-support).

Ethernet and Wi-Fi devices can share the same local network. BShare selects
active LAN interfaces using operating-system link and routing information,
including external virtual switches carrying the physical LAN. Transfer controls
use the source address for the selected receiver. See the
[interface selection notes](docs/STREAMING_COMPATIBILITY.md#ethernet-wi-fi-and-interface-selection)
for details and validation limits.

For USB camera or screen sharing, enable USB debugging in Android's Developer
options, authorize the computer, and select the connected phone in BShare's USB
device list. No phone IP address or tethering network is required. Desktop USB
uses ADB; Windows may also need the phone vendor's USB driver. See
[USB transport and setup](docs/USB_TRANSPORT.md). Physical cable validation covers
the S22 Ultra and Windows PC; Linux/macOS code and packaging do not establish
equivalent hardware coverage.

## Run

```bash
flutter pub get
flutter run
```

## Installers from GitHub Actions

Version tags such as `v1.0.5` build and publish individual installer files in
[GitHub Releases](https://github.com/BryamContreras/BShare/releases): ARM32 and
ARM64 Android APKs, a Windows installer, Linux DEB/RPM packages, and macOS ARM64
and x64 PKG installers. The build jobs upload each installer directly to a draft Release;
after all builds pass, the workflow publishes the individual files and checksums.
Release titles match the version tag, such as `v1.0.5`. An existing version can
be rebuilt through the workflow's `release_tag` input; new installers are staged
separately until validation finishes.
It does not generate ZIP installer artifacts. Pushes and pull requests run the
quality gate plus native streaming verification on Windows and Linux and an
Android release compilation. These verification builds do not publish installers. This repository is open source under the MIT License;
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

GitHub Releases include separate `.pkg` installers for Apple Silicon (`arm64`)
and Intel (`x64`). Local `scripts/build_releases.sh --macos-only` packages the
architecture of the Mac where it runs. The installer places `BShare.app` in
`/Applications`. The app is ad-hoc signed; the installer is unsigned unless a
Developer ID Installer identity is configured. These builds are not notarized,
so macOS may require approval in Privacy & Security before opening the installer.

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
- For screen audio on Android, leave **Share device audio** enabled before starting. Android requires audio recording permission for playback capture; BShare keeps the hardware microphone disabled in this mode. Permission denial or unsupported capture keeps screen video available without device audio. See [Android's playback capture limits](https://developer.android.com/media/platform/av-capture).
- In Wi-Fi/LAN mode, the displayed IP and port identify the running BShare listener, including an alternate port when the preferred one is occupied. USB mode shows the phone's BShare port and connects by selecting the physical phone, without entering an IP. WebRTC negotiates the media transport when a viewer connects.
- In OBS on Windows 11 x64 or a configured Linux system, add the BShare system virtual camera as a video capture source. The old separate OBS plugin has been removed. See the [connection guide](docs/OBS.md).
- For camera or screen video over USB, connect an Android data cable, enable USB debugging and authorize the computer. Select USB and start sharing on the phone, then select that physical phone in the computer's USB list. Keep the default BShare port unless the phone uses another port. Signaling and phone media cross the cable; the USB session does not fall back to Wi-Fi/LAN. iOS sources use Wi-Fi/LAN. See the [physical Windows/Android USB checks](docs/performance/windows-android-usb-review.json).
- For USB video in OBS, connect the phone through BShare, then select the BShare virtual camera as a video capture device. That virtual device carries video only. The desktop camera viewer can disable its local preview while continuing virtual camera output and saving photos/videos on the computer.
- The desktop camera actions panel starts with Preview, then Take photo above the photo folder and Record video above the video folder. Recording has a duration and Stop recording action. A successful photo briefly flashes the enabled local preview; this effect is absent from saved files and virtual camera output. The ten-second Saved notice and preview flash respect reduced-motion settings.
- Photo and video folders initially use the operating system's Pictures/BShare and Videos/BShare locations, including redirected directories, and are remembered separately for each desktop OS. Folders are created when saving. Saved media comes from the received stream, so its detail depends on the negotiated resolution; it is not a full-resolution phone-camera still.
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
