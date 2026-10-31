# BShare virtual camera and desktop controls

The Windows 11 x64 camera component exposes **BShare (Windows Virtual Camera)** to
applications that accept system video capture devices. It exports the clean video
received by the BShare desktop app, from either the phone camera or screen. The
app's window, address text and control panel are not included.

The device has persistent system lifetime for the user who registers it. Closing
BShare does not unregister it. When an application opens the device without an
active BShare receiver, it supplies a waiting image saying **No hay dispositivo
de video conectado / No video device connected**. This does not keep the phone's
camera, a PC camera or a microphone running. Windows starts the media source when
an application requests its video.

## Connect

1. The Windows app installer installs the virtual camera automatically
   on supported Windows 11 x64 systems. A separate component installer is also
   available; see [plugins/virtual-camera](../plugins/virtual-camera/README.md). Machine-level
   registration of the source requires administrator approval; the camera device
   itself belongs to the original desktop user.
2. Start a camera or screen broadcast on the phone. In BShare on the PC, connect
   to that broadcast using Wi-Fi/LAN or select **USB** on both sides and choose
   the authorized Android USB device on the PC. USB uses debugging rather than
   tethering; see [USB setup and transport](USB_TRANSPORT.md). The phone's LAN
   IP and port are BShare's signaling address, not properties of the virtual device.
3. In OBS, add **Video Capture Device** and select **BShare (Windows Virtual
   Camera)**. In another compatible application, select it as the camera.
4. Leave the BShare receiver running while using its video. Disconnecting the
   receiver or stopping the phone broadcast returns the device to its waiting
   image. No application needs to remove and recreate the video source.

The output is 1280 × 720 at a nominal 30 FPS. Portrait and other aspect ratios
are fitted with black bars, preserving orientation and proportions. An unchanged
phone screen stays visible; the absence of a new encoded frame alone does not
mean the device has disconnected. Only one BShare receiver publishes per user
at a time.

## Camera controls on the PC

The desktop camera viewer has a persistent menu on the right, outside the video:

- **Switch camera** is the first control. It changes between the phone's front
  and rear cameras while keeping the viewer open. A **Lens** selector appears
  when Android exposes more than one camera on the current side.
- **Mirror** is next. It flips the PC viewing image horizontally, keeping
  controls and text readable. It does not change the phone capture or the
  registered virtual camera output.
- **Camera zoom** uses the phone's capture API and the range reported by the
  current camera. Android 11+ uses the device zoom-ratio API when available;
  older backends use native sensor crop or camera zoom parameters. It does not
  enlarge the received image in Flutter. Optical switching, hybrid/digital zoom
  and access to additional lenses depend on what the phone driver exposes.
  Dragging applies intermediate values, with one command in flight and only
  the latest pending value retained; releasing applies the final value.
- **White balance** offers a cool/warm slider when Camera2 exposes manual color
  correction. It freezes the camera's automatic color-correction baseline and
  adjusts its red/blue gains on the phone. The scale is relative, not calibrated
  Kelvin. **Auto** restores automatic white balance. Cameras without the required
  controls keep their advertised presets; no receiver-side color filter is used.
- **Brightness (EV compensation)** adjusts the camera's automatic exposure in
  the device's reported increments. It is disabled while manual exposure is active.
- **Exposure** offers automatic/manual selection when the camera exposes manual
  sensor controls. In manual mode, **Shutter time** (milliseconds) and **ISO**
  control the sensor; long shutter times can reduce the delivered frame rate.
- **Microphone** changes the phone's microphone, using the state confirmed by
  the phone. Grant microphone permission on the phone before enabling it from
  the PC; a network command does not open a phone permission dialog.
- **Flash** appears when the current phone camera supports it.
- **Stop sharing** ends the phone's camera broadcast for all its viewers.
- **Close viewer** disconnects only this PC and returns to camera setup.

Controls require an updated BShare app on the phone. They are scoped to the
connected viewer and current capture session. Changing a control on the phone
updates the PC menu too. Mobile viewers retain their mobile layout.

Camera adjustments currently have Android Camera2 and Camera1 backends. Other
phone/capture backends report unsupported adjustments. Camera2 replies use
capture-result readback; changing zoom, white balance, EV or flash preserves
the other settings. Switching cameras re-reads the new device's ranges and
current settings. Only public camera IDs are offered; a phone's stock camera
app may access vendor-only lenses or zoom ranges unavailable to BShare.

The sidebar contains the controls only. The registered virtual camera remains
available to OBS and other applications without a device-status block in this
menu.

## Audio and platform support

This camera device exports video. It does not create a virtual microphone or
route phone playback audio to another application's microphone input. BShare
plays received audio through the computer's output; configure audio capture in
OBS separately. See [the OBS setup guide](OBS.md).

The left actions panel in the desktop camera viewer starts with **Preview**,
then **Take photo** above the photo folder and **Record video** above the video
folder. Recording changes the latter action to **Stop recording** and shows the
elapsed time. Both menus scroll in short windows; narrow windows allow horizontal
scrolling to reach both panels without placing controls over the image.
Turning preview off skips Flutter texture drawing while the native recording
and virtual camera consumers continue receiving frames. Photos use JPEG and
videos use MP4 with H.264 video and AAC audio. Recording includes received phone
audio when present, otherwise silence; it never opens the PC microphone.
Destination folders default to the operating system's Pictures/BShare and
Videos/BShare, honor redirected/localized OS directories and persist separately.
Stopping or disconnecting the viewer finalizes the recording before its peer is
closed. All media files are saved on the computer, without capture/save commands
to the phone. Mirror changes only the local preview; saved photos and videos use
the received orientation without applying the preview mirror.

After each new file, a **Saved:** footer shows the path for ten seconds. Its
heading is larger than the compact path, and the footer remains visible while
the actions menu scrolls. A subtle fade/slide/size transition shows and dismisses
the notice; ordinary recording-duration updates do not restart its lifetime.
Taking a photo also briefly flashes the enabled local preview. Reduced-motion
settings suppress both effects. The flash is a UI confirmation, not an exposure
change, and is absent from photos, recordings and virtual camera output.

Photos and recordings save the received stream, not a separate full-resolution
still from the phone. Their resolution and frame rate depend on the negotiated
stream. The selected directories are created when saving; choosing a folder can
start from its existing parent if the default BShare subfolder is not present.

On Windows, BShare receives audio through the multimedia output instead of
opening the default communications route. This avoids asking Windows to lower
other applications' volume. Explicit output selections are retained. BShare
does not change the global Communications preference or other audio sessions.

The Windows virtual-camera backend requires Windows 11 x64 (build 22000 or newer).
Windows 10 can still run BShare's receiver and controls, but does not gain that
Windows 11 virtual-camera API. Linux uses the separate v4l2loopback backend below.
Local JPEG/MP4 saving uses WIC/Media Foundation on Windows and GStreamer on Linux;
Linux needs the matching H.264 and AAC encoder plugins. macOS Camera Extensions
and local JPEG/MP4 saving are not supplied in this release. Compatibility with a particular
destination app must be checked on that app; a successful native capture test
does not establish support in every video application.

## Linux installation

Linux DEB/RPM packages install a named **BShare Virtual Camera**, its setup unit
and a user daemon. The daemon keeps the camera visible with a waiting image
while the desktop session is active, including after BShare closes. Received
camera or screen video replaces that image; the virtual device remains video
only. Choose it as an ordinary V4L2 camera in OBS or another camera application.

DEB installs v4l2loopback's DKMS driver/tools through the distribution package
manager. Matching kernel headers and an accepted kernel-module signature are
required. Fedora setup uses an available v4l2loopback installation; it does not
enable additional repositories automatically. Installation configures only
BShare's named device and services and does not unload an existing OBS camera's
module. The user daemon drops video when its user leaves the active graphical
session.

Driver/header/signing problems are reported as unavailable; Secure Boot is not
bypassed. Linux production IPC, waiting-image continuity and V4L2 ownership
guards passed native WSL tests with a simulated output device. A real Linux
v4l2loopback device and destination applications have not been exercised here.
See [the Linux backend guide](../plugins/virtual-camera/linux/README.md) for
setup behavior, supported dependencies and validation limits.

## Screen latency

Screen capture adds Android display composition and capture before encoding.
The negotiated dimensions can also differ from camera capture, even with the
same quality setting. Internal audio adds its own capture/playback buffering
and audio/video synchronization. A static-screen refresh interval is not a
delay applied to moving frames.

The Android sender skips painting its hidden screen preview while still
reporting size and rotation. This removes unused rendering work; it does not
remove WebRTC's adaptive buffers or guarantee a particular end-to-end delay.
Receiver jitter-buffer and decoding statistics describe only part of the path
and must not be presented as a phone-to-display latency measurement.

The desktop screen viewer's fullscreen button expands the native window to the
monitor bounds. Its controls and cursor hide after three seconds without input,
return on mouse movement, and Esc restores the normal window without stopping
the remote stream. Closing the viewer restores the original window state.

The implementation uses the [Microsoft virtual camera API](https://learn.microsoft.com/en-us/windows/win32/api/mfvirtualcamera/nf-mfvirtualcamera-mfcreatevirtualcamera)
and retains the license for the [Microsoft Windows Camera source sample](https://github.com/microsoft/Windows-Camera/tree/master/Samples/VirtualCamera).

## Verified behavior

The physical S22 over Wi-Fi sent video to the Windows PC on Ethernet. One system
capture consumer received live video and then the exact waiting frame after the
PC stopped the phone broadcast, without recreating that consumer. The receiver
closed normally and the camera stayed registered and capturable. The normal app
entrypoint was rebuilt and passed a separate startup/close check.

The final installed component also delivered 151 DirectShow samples in five
seconds at 1280 × 720, YUY2, with a declared 30 FPS. This verifies the capture
backend used by OBS's Video Capture Device; it does not claim that a new source
was added to the user's existing OBS scene. OBS was left open and unchanged.

See [the system-camera report](performance/windows-virtual-camera-review.json)
and [phone-control report](performance/virtual-camera-controls-review.json) for
artifact hashes, earlier diagnostic assumptions, physical cleanup and coverage
limits. No images or audio recordings were retained.

Native camera adjustments were subsequently verified on the physical S22:
the main camera advertised 0.6–10× and the tested secondary rear/front cameras
advertised 1–8×. HAL capture results confirmed zoom, white balance, EV, manual
shutter/ISO and preservation when toggling flash. The Windows receiver also
adjusted these controls while the system camera continued supplying frames.
See [the phone hardware-control report](performance/s22-camera-capture-controls-review.json)
and [the Windows control report](performance/windows-camera-capture-controls-review.json).

Live mouse-drag zoom and native cool/warm color correction have separate
[Windows UI](performance/windows-live-camera-ui-review.json) and
[S22 HAL](performance/s22-realtime-camera-controls-review.json) evidence.
The [combined review](performance/realtime-controls-audio-latency-review.json)
records the final artifacts, audio-ducking comparison, bounded receiver timing
samples and their measurement limits.

Direct USB camera, internal screen audio and fullscreen behavior were checked
between the physical S22 and Windows while the phone's Wi-Fi was disabled.
See [the USB and fullscreen review](performance/windows-android-usb-review.json).

Local JPEG photos and H.264/AAC MP4 recordings were verified with the physical
S22 over USB, including preview disabled and finalization when disconnecting.
The virtual camera delivered live frames while Flutter preview was disabled and
returned to its waiting image after cleanup. Native Windows and Linux tests also
decoded synthetic audio/video files. See [the desktop capture review](performance/desktop-camera-media-review.json)
for artifact hashes and the remaining Linux runtime coverage limits.
