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

For the complete Linux release (bundle, `.tar.gz`, and `.deb`), run:

```bash
bash scripts/build_releases.sh --linux-only
```

GitHub Actions also generates an RPM and checks it on Fedora 44. To package both
formats from an existing release bundle, use `python3 tool/packaging_linux.py`.
See [RELEASE.md](RELEASE.md) for required packaging tools and Actions artifacts.

WSL2 is not enough for hotspot testing because it usually exposes only a
virtual Ethernet interface, not the physical Wi-Fi adapter.
