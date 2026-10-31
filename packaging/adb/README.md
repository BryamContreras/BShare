# Bundled ADB client

BShare's direct Android USB transport uses an authorized ADB data connection.
Desktop packages include the client, so installing Android Studio or Flutter is
unnecessary. Android USB debugging and approval of the computer are still required.
The package does not install drivers, change PATH, or include fastboot and the
remaining Android SDK tools.

`manifest.json` pins Platform-Tools **37.0.0** to official Google archive URLs,
archive sizes/SHA-256, and the exact extracted file hashes. It does not follow
the mutable `latest` download links. The Windows archive suffix is `-win.zip`.
The Linux binary is x64; the macOS binary is universal x64/arm64.

| Platform | Upstream files retained |
| --- | --- |
| Windows x64 | `adb.exe`, `AdbWinApi.dll`, `AdbWinUsbApi.dll`, `NOTICE.txt`, `source.properties` |
| Linux x64 / macOS | `adb`, `NOTICE.txt`, `source.properties` |

Each payload also carries `LICENSE.adb.txt`, `BSHARE-ADB.txt` provenance and a
manifest of its files. The complete upstream `NOTICE.txt` is preserved byte for
byte, including its dependency notices; the ADB Apache license alone does not
replace that file.

## Preparing a payload

The helper needs Python 3.10+ and works independently of Flutter:

```powershell
python packaging/prepare_adb.py --platform windows --architecture x64 --destination build/windows/x64/runner/Release/tools/platform-tools --verify-executable
```

Use `--platform linux` or `--platform macos` for those targets. An optional
`--archive PATH` reads an already downloaded pinned archive. Alternatively,
`--sdk-directory PATH` accepts an installed SDK or its `platform-tools` directory
only when every retained file matches the pinned hashes. It never silently
substitutes a different SDK revision. Downloads are cached in `build/cache/adb`.

The destination must be a dedicated directory. Repeated preparation accepts a
matching BShare-owned payload; unmarked files, modified binaries and symlinks are
rejected. Extraction uses a fixed allowlist. `--verify-executable` runs only
`adb version` on the native host, without starting a server or contacting devices.

## Package integration

- Windows stages the client at `tools/platform-tools` inside its installer
  payload. The same helper can prepare a portable release or diagnostic bundle.
- Linux packages stage the client at `/opt/bshare/tools/platform-tools` and check
  its ELF dependencies. They keep its pinned bytes intact rather than applying
  the app's RPATH rewrite. The udev rule grants the active local desktop user
  access to devices exposing the Android ADB interface `ff4201`; it does not
  grant world-writable access to every USB device. Installation reloads rules;
  reconnect the cable for an already plugged-in device. The rule follows
  [systemd's interface matching and uaccess model](https://github.com/systemd/systemd/blob/main/rules.d/70-uaccess.rules.in).
- macOS stages the universal client inside
  `BShare.app/Contents/MacOS/tools/platform-tools`. It reapplies the child's code
  signature with only the sandbox/inherit entitlements, then reseals the outer
  app while preserving its metadata. Both the original and signed executable
  hashes and the signature modification are recorded beside the notices.
  `--app-signing-identity` selects the app/child identity; it is distinct from the
  PKG's `--signing-identity`. Both default development packaging and the main app
  retain App Sandbox. The parent has network client/server and USB capabilities;
  the child follows [Apple's helper inheritance requirements](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app).

Windows staging and native `adb version` were exercised locally. Linux/macOS
archive integrity and packaging logic have local regression checks; their native
build/install workflows validate the packaged client. This does not establish
physical USB-device compatibility on those two operating systems.

## Upstream licensing and sources

The [Android SDK terms, section 3.5](https://developer.android.com/studio/terms)
separate open-source SDK components from the general SDK license. The AOSP
[ADB license](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/NOTICE)
is Apache-2.0. BShare retains the exact archive's notices and an additional copy
of that source license; other components keep their own notices and licenses.
This payload is the ADB client subset, not a redistribution of the complete SDK.

Source and release information are available from the
[AOSP ADB repository](https://android.googlesource.com/platform/packages/modules/adb/)
and [Google Platform-Tools release notes](https://developer.android.com/tools/releases/platform-tools).

```powershell
python -m unittest discover -s tool -p "test_prepare_adb.py"
python -m unittest discover -s tool -p "test_packaging_*adb.py"
python -m unittest discover -s tool -p "test_packaging_macos.py"
```
