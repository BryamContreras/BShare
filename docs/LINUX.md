# BShare on Linux

This project can run as a Flutter Linux desktop app and can create a temporary
BShare Wi-Fi network on Linux when NetworkManager is available.

## Install Linux prerequisites

Install a native Linux Flutter SDK. Do not reuse a Windows Flutter SDK from
WSL, such as `/mnt/c/flutter`; its scripts are built for Windows and can fail
inside Linux.

On Ubuntu or Debian-based distros:

```bash
sudo apt update
sudo apt install -y \
  git curl unzip xz-utils zip \
  clang cmake ninja-build pkg-config libgtk-3-dev libstdc++-12-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libgdk-pixbuf-2.0-dev \
  gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
  network-manager wpasupplicant dnsmasq-base polkitd iw
```

Then enable desktop support:

```bash
flutter config --enable-linux-desktop
flutter doctor -v
flutter pub get
```

## Check this machine

From the project root:

```bash
bash tool/linux_doctor.sh
```

The script checks:

- Flutter and Dart availability.
- Linux desktop toolchain tools.
- GTK development files.
- NetworkManager and `nmcli`.
- Wi-Fi devices managed by NetworkManager.
- Whether any Wi-Fi device reports hotspot/AP support.

## Run and build

```bash
flutter analyze
flutter test
flutter run -d linux
flutter build linux --release
```

The release bundle is generated under:

```text
build/linux/x64/release/bundle/
```

Run the built app with:

```bash
build/linux/x64/release/bundle/bshare
```

## Desktop launcher icon

When you run the binary directly, some Linux desktops may show a generic icon
in the dock because they only resolve app icons from installed `.desktop`
entries. Install BShare's launcher for the current user with:

```bash
bash tool/linux_install_launcher.sh
```

Then open BShare from your applications menu. The script installs:

```text
~/.local/share/applications/com.bshare.bshare.desktop
~/.local/share/icons/hicolor/512x512/apps/com.bshare.bshare.png
```

## Offline Wi-Fi behavior

If Linux has no LAN/Wi-Fi network when you press Start receiver, BShare tries
to create a temporary network using:

```bash
nmcli device wifi hotspot ifname <wifi-device> con-name BShare-Hotspot-* ssid BShare-* password <generated-password>
```

Stop receiver brings the connection down and deletes the temporary
`BShare-Hotspot-*` NetworkManager profile.

This requires:

- NetworkManager with `nmcli`.
- `wpasupplicant` for Wi-Fi management.
- `dnsmasq-base` for hotspot DHCP/shared IPv4 support.
- polkit (`policykit-1`/`polkitd`) so desktop users can authorize
  NetworkManager changes when required.
- A physical Wi-Fi adapter exposed to Linux.
- Adapter support for AP/hotspot mode.
- User permission through polkit, or a system configuration that allows the
  user to manage NetworkManager connections.

`nmcli` is not bundled with BShare. On Debian, Ubuntu, and desktop derivatives
it normally comes from the distro package manager through `network-manager`.
The distributable `.deb` declares these as system dependencies instead of
shipping private copies:

```text
network-manager, wpasupplicant, dnsmasq-base, polkitd
```

## Debian / Ubuntu package

The release package targets 64-bit PCs (`amd64`). Its minimum library versions
are calculated from the actual compiled bundle. CI builds on Ubuntu 22.04 and
tests installation there; bundles built on newer local systems may need newer
distributions. Runtime dependencies cover GTK 3, Flutter/WebRTC graphics support,
audio, NetworkManager, Wi-Fi management, DHCP support, and polkit. Package names
are resolved by the build distribution's package metadata.

Build a distributable package with:

```bash
bash scripts/build_deb.sh
```

The generated file is:

```text
dist/releases/BShare-<version>/linux/bshare_<version>_amd64.deb
```

Install it with APT so it resolves dependencies automatically:

```bash
sudo apt install ./bshare_<version>_amd64.deb
```

For the DEB and RPM packages, run:

```bash
bash scripts/build_releases.sh --linux-only
```

GitHub Actions also generates an RPM and checks both formats in Ubuntu and Fedora
containers. To package both formats from an existing release bundle, use
`python3 tool/packaging_linux.py`.
See [RELEASE.md](RELEASE.md) for required packaging tools and direct release downloads.

WSL2 is not enough for hotspot testing because it usually exposes only a
virtual Ethernet interface, not the physical Wi-Fi adapter.

## Camera, screen and USB viewing

Wi-Fi and Ethernet share the normal LAN flow. For an Android data cable, enable
USB debugging, authorize the computer, select USB on the phone and start its
camera/screen stream. Select the physical phone in the desktop USB list, using
its BShare port (normally `53317`). USB tethering and an IP field are unnecessary.
Installers include ADB; source builds can use an installed Android Platform Tools
client or `BSHARE_ADB`. Linux may need the distribution/vendor's normal udev
rules for non-root USB access. BShare does not change debugging authorization or
take over wireless/emulator transports. See [USB_TRANSPORT.md](USB_TRANSPORT.md).

The native screen fullscreen control expands the window and restores it with
Esc while the stream stays connected. Controls/cursor hide after three seconds
and return on movement. Camera adjustments remain in the separate right-hand
menu and use the phone's supported capabilities, including native zoom, white
balance, EV and manual shutter/ISO when advertised.

## Photos and recordings on this computer

The camera viewer's left panel starts with Preview. Take photo sits above the
photo folder, and Record/Stop video above the video folder. JPEG photos and
H.264/AAC MP4 files save locally in the selected destinations, initially the OS
Pictures/BShare and Videos/BShare directories. Localized/redirected XDG folders
are respected, choices persist, and directories are created when saving.

Turning preview off skips local drawing while recording and virtual-camera
publishing continue. The preview mirror and brief photo-success flash are absent
from saved media. A compact Saved footer remains outside the menu scroll and
dismisses ten seconds after each new file; its animation and the flash respect
reduced-motion settings. Files contain the received stream at its negotiated
quality, not a separate full-resolution phone photo. MP4 audio comes from the
received phone audio, otherwise silence; BShare never opens the PC microphone.
Disconnecting or replacing the source finalizes an active recording.

The Linux writer uses GStreamer/GdkPixbuf. H.264 needs `openh264enc`; AAC uses the
first available `voaacenc`, `fdkaacenc`, or `avenc_aac`. Debian/Ubuntu runtime
plugins come from `gstreamer1.0-plugins-good` and `gstreamer1.0-plugins-bad`;
`gstreamer1.0-libav` provides the libav AAC alternative. Fedora packages require
the real `openh264` codec, its GStreamer plugin and the appropriate good/bad-free
runtime plugins; the `noopenh264` ABI stub cannot encode recordings. Dependencies
must resolve from the distribution's configured repositories; BShare does not
add a codec repository automatically.
Missing encoders are reported instead of silently publishing an invalid MP4.
FFmpeg/ffprobe are used to verify test outputs; the app's recording backend uses
GStreamer rather than launching FFmpeg.

## System virtual camera

OBS uses **Video Capture Device (V4L2)** and the named **BShare Virtual Camera**.
No separate BShare OBS plugin is required. The virtual device carries video only;
configure OBS audio capture separately for the computer output playing phone
audio. Its user daemon supplies a waiting image even while BShare is closed, as
long as the configured graphical user session is active.

DEB packages install v4l2loopback driver/tools; Fedora setup uses an available
driver and does not enable additional repositories. Matching kernel headers and
the distribution's module-signature approval remain required. Secure Boot is
not bypassed. Setup keeps existing OBS/other virtual cameras intact, and older
loopback versions cannot always add a BShare device beside an already-loaded
unrelated camera. See [the Linux backend guide](../plugins/virtual-camera/linux/README.md)
for driver versions, status and cleanup behavior.

Native Linux media files were encoded and decoded under WSL, and IPC/ownership
tests exercised a simulated V4L2 device. These checks do not prove a full Flutter
Linux desktop session, a real v4l2loopback kernel device, or compatibility with
every destination app. Physical USB streaming and preview-independent local
saving were checked on Windows with an S22. The exact artifacts and remaining
limits are in [the desktop media review](performance/desktop-camera-media-review.json)
and [the USB review](performance/windows-android-usb-review.json).
