# Use BShare in OBS

BShare uses a system virtual camera. No separate OBS plugin, IP field or port
field is required in OBS.

1. Install BShare on the computer. On Windows 11 x64, the installer automatically
   installs the virtual camera component. On Linux, see the driver requirements
   in [virtual camera setup](VIRTUAL_CAMERA.md).
2. Share the phone's camera or screen and connect to it in the BShare desktop
   app over Wi-Fi/LAN or [USB debugging](USB_TRANSPORT.md).
3. In OBS, add a **Video Capture Device** source (Windows) or **Video Capture
   Device (V4L2)** source (Linux). Select the BShare camera.
4. Leave the BShare receiver connected. The virtual camera supplies clean video
   without the app's controls. Without a connected broadcast it supplies the
   waiting image instead.

In the desktop camera viewer, turn off **Preview** in the left actions panel to
stop drawing the local video while the virtual camera continues supplying OBS.
You can still take photos and record received video to the computer. JPEG photos
and H.264/AAC MP4 recordings use separate folders, initially the operating system's
Pictures/BShare and Videos/BShare directories. These actions save nothing on the
phone. The mirror switch affects the local preview only.

**Take photo** appears above the photo folder; **Record video** (or **Stop
recording**) appears above the video folder. Recording shows its elapsed time.
A Saved notice stays at the foot of the actions panel for ten seconds after each
new file, including while the menu scrolls. A successful photo briefly flashes
the enabled local preview. The flash and notification animation respect reduced
motion and never appear in the virtual camera or saved media. Saved images use
the received stream's resolution rather than a separate full-resolution phone
photo.

The virtual camera is a video device. It does not create a virtual microphone.
BShare plays received phone audio through the computer's output; include that
output in OBS audio capture if required. Desktop MP4 recordings include received
phone audio when available, otherwise silence. They never open the PC microphone.
For Android screen audio, playback capture requires Android 10+ and the source
app must permit capture. Camera microphone audio is sent only when enabled on
the phone. Receiving audio in BShare does not add an OBS audio source automatically.

Local JPEG/MP4 saving is implemented on Windows and Linux. Linux additionally
needs the packaged GStreamer encoders; its virtual camera requires a working
v4l2loopback setup. macOS has no BShare virtual camera or local media-saving
backend in this release. See [platform support and verification limits](VIRTUAL_CAMERA.md#audio-and-platform-support).

The old BShare OBS plugin has been removed from this repository. Existing users
of that plugin should remove its separate installation and replace its source
with the system video capture source. This change does not modify OBS scenes.
