# BShare installers and GitHub Actions

## Automated builds

The **Build installers** workflow runs on pushes to `main`, version tags such as
`v1.0.2`, and **Actions → Build installers → Run workflow**. Pull requests run the
same quality gate without accessing Android signing secrets or creating installers.
A newer run for the same branch cancels the previous run.

The quality job runs analysis, the Flutter regression suite, verification-tool
unit tests, and native Linux window/control tests. Only after it passes do the
three reusable platform workflows build in parallel. Linux compiles once and
packages the same bundle into both formats.

All builds use Flutter **3.44.8**, locked Dart dependencies and one shared version.
The version comes from `pubspec.yaml`; its build number is increased by the parent
workflow run number. A `v*` tag must match the semantic version in `pubspec.yaml`.

Open a completed run and download these artifacts:

| Artifact | Contents | Retention |
| --- | --- | --- |
| `BShare-Windows-x64` | Windows x64 installer EXE and SHA-256 | 30 days |
| `bshare-linux-x64` | amd64 DEB, x86_64 RPM and dependency/hash manifest | 14 days |
| `BShare-Android` | Signed universal APK, SHA-256, signature/native/QR reports | 30 days |
| `BShare-Windows-verification` | Installation, launch and uninstall logs | 14 days |

Artifacts remain attached to the Actions run. This workflow does not publish a
GitHub Release or upload to an app store.

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
is uploaded as an artifact. Keep an independent private backup of the keystore
and its passwords: future updates must use the same signing identity.

A fresh debug key is allowed only when another workflow explicitly calls the
Android reusable with `require-signing: false` and supplies no signing secrets.
Such files are named **preview**. The normal installer workflow requires release
signing. An APK signed with a new identity cannot update an older APK signed with
a different key in place.

The APK includes ARM32, ARM64 and x86_64 AOT builds. CI verifies signatures, complete
native ABI sets, 64-bit ELF/ZIP alignment, and retained QR scanner constructors.
These are build/package checks; physical device compatibility is recorded
separately in [PERFORMANCE.md](PERFORMANCE.md).

## Windows

Windows 2022 builds the x64 application and uses Inno Setup to create a per-user
installer. The required Microsoft C++ runtime DLLs are bundled next to the app;
installation does not require administrator rights. CI silently installs into an
isolated directory, opens the installed app, closes it, and uninstalls it. The
installer retains BShare's existing AppId and is not Authenticode-signed.

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

The existing `scripts/build_releases.sh --macos-only` script builds macOS on a
Mac. iOS signing and store publication remain manual; the installer workflow does
not build or publish those platforms.
