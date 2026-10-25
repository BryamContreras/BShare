# BShare installers and GitHub Actions

## Automated builds

The **Build installers** workflow runs the quality gate on pushes and pull
requests to `main`. A version tag such as `v1.0.4` runs the same gate, builds all
installers, verifies them, and publishes the files as individual GitHub Release
assets. To run a release build manually, select a version tag as the ref in
**Actions → Build installers → Run workflow**. The tag must match `pubspec.yaml`.
An interrupted run for the same ref is canceled when a newer run starts.

The quality job runs analysis, the Flutter regression suite, verification-tool
unit tests, and native Linux window-decoration tests. It must pass before Windows,
Linux, Android, and two native macOS architecture builds start in parallel. Linux
compiles once and packages the same bundle into both formats.

All builds use Flutter **3.44.8**, locked Dart dependencies and one shared version.
The version comes from `pubspec.yaml`; its build number is increased by the parent
workflow run number. A `v*` tag must match the semantic version in `pubspec.yaml`.
The 1.0.4 base build is 16, above the locally validated build 15; tagged CI builds
add their run number. Android ABI-specific version codes retain the existing
Flutter offsets and the permanent signing key, so previous installations can
update in place.

Download these individual files from the [latest GitHub Release](https://github.com/BryamContreras/BShare/releases/latest):

| Release file | Contents |
| --- | --- |
| `BShare-<version>-android-armv7a.apk` | Signed ARM32 APK |
| `BShare-<version>-android-arm64-v8a.apk` | Signed ARM64 APK |
| `BShare-<version>+<build>-windows-x64-setup.exe` | Windows x64 installer |
| `bshare_<version>-<build>_amd64.deb` | Debian/Ubuntu x64 package |
| `bshare-<version>-<build>.x86_64.rpm` | Fedora/RHEL x64 package |
| `BShare-<version>-macos-arm64.dmg` | Apple Silicon installer |
| `BShare-<version>-macos-x64.dmg` | Intel Mac installer |
| `SHA256SUMS.txt` | SHA-256 for every installer |

Each native build uploads its installer directly to a draft GitHub Release. A
final job checks that all seven files are present, creates `SHA256SUMS.txt`, and
publishes the Release only after every build and installer check passes. The
workflow does not create ZIP-wrapped Actions artifacts.

## License

The BShare application is distributed under the MIT License in the repository
root. Components under `third_party/` retain their upstream licenses and notices;
those files are included with the installers.

## Product identity

The product, Windows publisher/company, Linux maintainer and Android certificate
use **BShare**. Installer metadata contains no personal author name or email.
Existing third-party license notices remain included.

## Android signing

The reusable Android workflow requires all four repository Secrets:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

The release certificate subject is `CN=BShare, OU=BShare, O=BShare`. Private
material is decoded only into the runner temporary directory and ignored
`android/key.properties`; both files are removed even when a build fails. Neither
is uploaded to the GitHub Release. Keep an independent private backup of the keystore
and its passwords: future updates must use the same signing identity.

A fresh debug key is allowed only when another workflow explicitly calls the
Android reusable with `require-signing: false` and supplies no signing secrets.
Such files are named **preview**. The normal installer workflow requires release
signing. An APK signed with a new identity cannot update an older APK signed with
a different key in place.

CI produces separate ARM32 and ARM64 APKs. It verifies each APK's signature,
single-ABI native library set, 16 KB ELF/ZIP alignment where applicable, and QR
scanner constructor retention. These are build/package checks; physical device
compatibility is recorded separately in [PERFORMANCE.md](PERFORMANCE.md).

## Windows

Windows 2022 builds the x64 application and uses Inno Setup to create a per-user
installer. The required Microsoft C++ runtime DLLs are bundled next to the app;
installation does not require administrator rights. The installer creates a
Start Menu shortcut by default and shows an unchecked option for a desktop
shortcut. CI verifies both defaults, then installs, opens, closes and uninstalls
the app in an isolated directory. The installer retains BShare's existing AppId
and is not Authenticode-signed.

An additional unchecked option allows BShare on **private local networks**. It
asks Windows for administrator approval only to configure the firewall; BShare
itself continues to run as the current user. The rules apply only to that
installation's `BShare.exe`, inbound TCP and UDP, and `LocalSubnet`. TCP covers
the configurable HTTP listener; UDP covers discovery and negotiated WebRTC media
ports. They do not apply on public networks, disable the firewall or override
existing Block rules. A denied elevation or an explicit Block rule covering
Private networks is reported instead of being treated as successful setup.
Public-only Block rules are preserved and allow Private LAN setup to proceed.
`network-setup.log` records the result in the installation folder.

The elevated operation executes a payload embedded in the installer/uninstaller,
not the editable `configure-firewall.ps1` in the user's installation directory.
Its Windows firewall module is loaded from the system directory explicitly.
The helper writes no files with elevated rights; the installer records its own
state and status log with its original permissions.

CI verifies the rules' program/profile/address/protocol filters, repeat setup,
removal, Private block detection, and preservation of Public-only and unrelated
restrictions. It also
replaces the standalone helper before uninstall and checks that the embedded
payload still removes its rules. Normal uninstall asks for
administrator approval to remove rules when the option was configured. Silent
installation leaves firewall setup to the administrator, who can run this from
an elevated Windows PowerShell terminal (adjust the installation path):

```powershell
& "$env:LOCALAPPDATA\Programs\BShare\configure-firewall.ps1" -Mode Add -ProgramPath "$env:LOCALAPPDATA\Programs\BShare\BShare.exe"
```

For manual setup, run `-Mode Remove` with the same path before uninstalling to
remove only that installation's rules. The standalone helper does not create
installer state files.
On a trusted home LAN, select the Windows **Private** network profile; the
installer does not change network classifications. If an existing Block rule is
reported, review BShare's entries in Windows Defender Firewall before retrying.

To build locally with Flutter, Visual Studio C++ tools and Inno Setup installed:

```powershell
flutter pub get --enforce-lockfile
flutter build windows --release
./packaging/windows/build-installer.ps1
```

The existing `scripts/build_releases.ps1 -BuildInstaller` entry point delegates
Windows packaging to the same helper rather than duplicating its logic.

## Linux

CI builds on Ubuntu 22.04, computes dependencies from the actual ELF files, and
checks installation and removal in isolated Ubuntu 22.04 and Fedora 44 containers.
The staged package uses `/opt/bshare`, `/usr/bin/bshare`, desktop launcher and icon
paths. Relative runtime library search paths are applied only to staged copies.
The source build bundle is unchanged. The generated dependency manifest defines
the actual library minimums; binaries built on newer local systems may require
newer distributions.

For both package formats, install Python 3, `dpkg-dev`, `rpm`, `patchelf`,
`desktop-file-utils` and Flutter's normal Linux build dependencies, then run:

```bash
flutter pub get --enforce-lockfile
flutter build linux --release
python3 tool/packaging_linux.py --output dist/linux
```

For DEB only, the existing command remains supported:

```bash
bash scripts/build_deb.sh
# Reuse a completed release bundle:
bash scripts/build_deb.sh --skip-build
```

Packages go under `dist/`, which is ignored by Git. For local desktop/network
requirements see [LINUX.md](LINUX.md).

## Other native builds

The installer workflow builds on native Apple Silicon and Intel runners, checks
the executable architecture inside each DMG, and publishes separate `.dmg`
assets. Apps are ad-hoc signed but not notarized; Gatekeeper may require an
explicit user override. The local `scripts/build_releases.sh --macos-only` script
builds a DMG for the architecture of its host Mac. iOS signing and store
publication remain manual.
