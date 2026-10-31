# BShare Virtual Camera

Windows 11 x64 (build 22000+) software camera using Media Foundation. The camera
persists across BShare sessions and restarts. Selecting it while no BShare viewer
is receiving video displays “No hay dispositivo de video conectado / No video
device connected”. It exports clean video at 1280×720, 30 fps, with aspect fit and
black bars for portrait video. The source offers NV12 and RGB32. Audio requires a
separate audio route; configure OBS audio capture separately from its video source.
On the tested Windows installation its device name is **BShare (Windows Virtual
Camera)**; Windows supplies the suffix.

Windows uses the Media Foundation component described below. Linux has a
[v4l2loopback backend and persistent waiting-image daemon](linux/README.md),
including package setup for supported desktop systems. Native Linux kernel and
camera-application compatibility still needs validation. Windows 10 virtual
camera support and macOS Camera Extensions are not provided by this component.

## Build and install

Visual Studio C++ Build Tools, Windows SDK 22000+, CMake 3.25+ and Inno Setup 6:

```powershell
./plugins/virtual-camera/scripts/build-windows.ps1 -BuildTests
./plugins/virtual-camera/scripts/package-windows.ps1
```

Run `dist/virtual-camera/packages/bshare-virtual-camera-0.1.0-windows-x64-setup.exe`.
Windows UAC elevation is required once to install the source component in Program
Files and register its unique COM class under HKLM. The installer calls the device
registration as the original user; BShare can also register that user's device on
its next startup. Registration is CurrentUser with System lifetime. It never uses
an AllUsers camera bound to one user's stream.

The application bundle includes `bshare-camera.exe` beside `BShare.exe`. Diagnostic
commands return JSON and never request elevation:

```powershell
./bshare-camera.exe --status
./bshare-camera.exe --probe 15
```

`--status` reports `supported`, `registered` (actual MF enumeration), and
`sourceRegistered` (installed machine COM class and existing source DLL).
The device is matched by its saved instance symbolic link, so translated names
and Windows' “(Windows Virtual Camera)” suffix do not affect detection.
`--install` and `--uninstall` create/remove the calling user's device. Remove a
user's device before uninstalling the system component; another Windows account
removes its own device. The system uninstaller never deletes another component's
COM registration if its DLL path belongs to a different installed version.

## Transport and lifecycle

`include/bshare_frame_publisher.h` is the header-only producer API (link advapi32).
Construct `bshare::virtual_camera::FramePublisher`, call `Publish(bgra, width,
height, stride)` on decoded video, and destroy it or call `Clear()` on detach.
Publishing only copies the latest frame; pipe I/O runs on bounded background
workers, with a 250 ms I/O deadline and cancellation before disposal. One owner
pipe prevents two producer processes from interleaving frames. Four camera host
instances can read independently.

The pipe is local-only, scoped by user SID plus a random 128-bit credential stored
in a protected HKCU key. Only that user, SYSTEM and LOCAL SERVICE have access.
Camera registration passes the credential to the media source; it is never logged.
The source additionally checks the pipe owner's SID. It generates a waiting slate
without the application, restores it immediately after pipe disconnect, and uses
a 1.5-second heartbeat timeout for suspended producers. An unchanged screen stays
visible because an active producer repeats its retained frame every 250 ms.

## Validation and provenance

CTest covers real named-pipe frames, BGRA colors, aspect ratio, unchanged video,
duplicate producer rejection, explicit clear, producer exit and shutdown. The
helper `--probe-direct DLL 15` tests COM class factory, activation, source-reader
media negotiation and actual samples without installing a system device. It is
different from `--probe`, which captures through the registered system camera.
The source lifecycle test also releases the activation object before reading
video, checks post-shutdown controls, and reactivates after `ShutdownObject`.
No frames or audio are written to disk by either probe.

The media source and activation boilerplate derives from Microsoft's MIT-licensed
[Windows-Camera sample](https://github.com/microsoft/Windows-Camera/tree/626f8b19c5f367602f2e89c6b314573d3776c9df/Samples/VirtualCamera).
`MICROSOFT-LICENSE` covers that code; Microsoft WIL headers are pinned at
`a1c0cbe1d7065aef6333399d3e25608eacdffc0f` (MIT). The Windows SDK supplies C++/WinRT.
See [MFCreateVirtualCamera](https://learn.microsoft.com/en-us/windows/win32/api/mfvirtualcamera/nf-mfvirtualcamera-mfcreatevirtualcamera)
for lifetime, access scope and minimum OS requirements.
