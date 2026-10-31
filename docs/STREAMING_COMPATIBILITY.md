# Screen and camera connection checks

Discovery, signaling and video are three separate steps. Seeing a device in the
list establishes only that a discovery announcement arrived. It does not prove
that the device's HTTP listener or WebRTC media ports can be reached.

## Errors reported on Windows and Honor

The reported screenshots show an HTTP connection refusal and a 15-second TCP
connection timeout. Both happen before video negotiation. They are not evidence
of a missing codec. A refusal can indicate a stopped listener or an outdated
destination; a timeout can indicate a firewall, an unreachable address or wireless
client isolation. These possibilities must be distinguished on the affected LAN.

The `SocketException` port printed by Dart can be the client's temporary socket
port. Use the destination shown by BShare's updated error message, or the actual
HTTP request URI in diagnostic logs, when checking the receiver's port.

## Network requirements

- Both devices must be able to reach each other on the LAN. A guest Wi-Fi or an
  access point with client isolation can block this even with the same Wi-Fi name.
- The sender needs inbound TCP on the receiver port shown by BShare. The default
  is 53317; if occupied, BShare binds another port and advertises it.
- Discovery uses UDP 53318. Video uses WebRTC's dynamically allocated media ports,
  so allowing only TCP 53317 is insufficient. Windows firewall rules must allow
  the installed BShare executable's LAN traffic.
- Use the trusted private network profile for a home LAN in Windows. A rule
  restricted to private networks does not apply when Windows calls that network
  public. Do not disable the whole firewall to diagnose BShare.

After changing Wi-Fi, starting sharing again and refreshing discovery updates the
destination. Announcements now use the datagram's source address, rather than an
address retained from another adapter or an old DHCP lease. Discovery joins the
available LAN interfaces, sends a bounded query with unicast replies, and also
uses broadcast. Android holds its Wi-Fi multicast lock only while discovery is
running and releases it on Stop/destruction. Updated receivers send a departure
announcement before closing their HTTP listener; session identifiers prevent a
late departure from removing a restarted receiver. Legacy peers or a lost UDP
departure still expire after 20 seconds.

### Ethernet, Wi-Fi and interface selection

Ethernet and Wi-Fi can share the same LAN: a computer connected by cable can
discover and exchange files with a phone connected to that router by Wi-Fi,
provided the router permits traffic between them. BShare uses the local IP
address and port for both connection types.

On the affected Windows PC, Hyper-V exposed the LAN address on `vEthernet (LAN)`;
the physical Ethernet adapter had no IPv4 address of its own. BShare incorrectly
discarded every `vEthernet` adapter and reported no network. Interface selection
now uses operating-system metadata: operational state, hardware transport or a
verified physical uplink for a bridge, address prefixes, default routes and route
metrics. No PC-specific IP address or adapter label is configured in the app.
An active physical interface or a bridge with an active physical uplink can form
a LAN without a gateway or Internet access. A gateway alone does not qualify an
internal virtual interface, TAP adapter or VPN as a LAN.

The primary address follows the operating system's route preference and metric;
Wi-Fi does not automatically outrank Ethernet. An explicitly active local
hotspot retains priority when its address is requested. Android includes Ethernet
and Wi-Fi networks while excluding VPN and cellular-only networks. Linux checks
hardware, radio and bridge/bond/VLAN uplinks; macOS reads active hardware ports.
Public and link-local IPv4 addresses are accepted on eligible interfaces.

Outgoing transfer controls verify eligible source addresses with a connection
explicitly bound to that interface and that particular receiver. If no such
connection can be established, a matching
eligible subnet with the longest prefix can supply the address. A source address
belonging to an excluded virtual interface is not advertised as the control
endpoint.

Discovery uses the same eligible interfaces. Multicast and subnet broadcast use
separate sockets bound to each LAN address, and an unavailable multicast receive
membership does not disable sending on that interface. When one device announces
several endpoints, discovery retains the alternatives and selects a consistent
destination using local subnet and interface preferences. Refresh also checks the
interface configuration, so a changed secondary interface renews discovery even
when the primary IP stays the same.

Validation on that Windows PC selected `172.21.53.7` on interface 11, transferred
and verified a 128 KiB file through the production HTTP services, and received a
discovery announcement through that address. Both endpoints ran on the same PC;
this initial probe does not establish connectivity to a second device. Regression
tests cover interface metadata and route selection, multiple LANs, exclusion of
internal networks, disconnected physical uplinks, and Ethernet without Wi-Fi or
a gateway. Physical Linux/macOS Ethernet and Android Ethernet validation remain
pending; phone Wi-Fi to Windows Ethernet results are recorded separately.

### S22 Ultra and Windows Ethernet checks — 2026-10-29

The S22 Ultra (SM-S908U, Android 14) ran the release APK; its installed SHA-256
matched the built APK. The phone used Wi-Fi and Windows used Ethernet on the
same LAN. Both sides discovered each other automatically. A temporary Windows
diagnostic entrypoint exercised the production transfer, signaling, WebRTC
decoder and renderer services. It was replaced with the normal application
after the checks.

| Check | Observed result |
| --- | --- |
| Windows → S22 file | 8 MiB completed; destination SHA-256 matched the source. |
| S22 → Windows file | 8 MiB completed from the production Send UI; destination SHA-256 matched the source and the control endpoint used the phone's Wi-Fi IP. |
| S22 screen → Windows | H.264 rendered at 1080×2316 with advancing decoded frames. |
| Windows screen → S22 | H.264 decoded by `c2.qti.avc.decoder`; the production viewer reported rendered dimensions up to 1920×1080. |
| Rear and front phone cameras → Windows | Both streams rendered H.264 with advancing decoded frames and completed native viewer cleanup. |

Every native media case selected the physical LAN pair `172.21.53.7` ↔
`172.21.53.37`; WSL and Default Switch were excluded from LAN selection. ADB
controlled the phone UI and checked file hashes; file and video payloads used
the actual LAN. These brief checks establish functionality on this pair, not
camera FPS or resolution guarantees. Physical Windows Wi-Fi, Linux/macOS and
Android Ethernet checks remain pending. Sanitized statistics, artifact hashes
and coverage limits are in
[the Windows/S22 review](performance/windows-ethernet-s22-review.json).

### Discovery when an adapter has no route

A separate reproduction with only the loopback interface active exposed a
discovery failure. Sending to `255.255.255.255` without a route returned zero
bytes, then Dart emitted `SocketException: Network is unreachable` and closed the
same UDP socket. Logging the error did not keep that socket open; subsequent
unicast announcements could no longer reach its listener.

The listener on UDP 53318 now only receives packets. Multicast sends on each
interface, broadcast sends and unicast replies use separately owned sockets. A
failed send closes only its transport, which is reopened on the next requested
send. Discovery queries specify the persistent reply port explicitly; queries
without that field still receive a reply at their source port. Stopping discovery
waits for pending sends and closes the listener and every outbound socket.

### Home address after returning from the background

The physical Honor test also exposed an outdated address on Home after the
router assigned new DHCP addresses while BShare was in the background. Discovery
and newly opened listeners used the current address, but Home retained its
previous network snapshot. The app now refreshes that snapshot once when returning
from a hidden or paused state. Permission dialogs that only make the app inactive
do not start another refresh, and shutdown prevents further refresh work.
Six regression cases cover these lifecycle transitions. The follow-up Android
build containing this display correction passed release/native-library and QR
checks. Version code 2015, SHA-256
`9ca37791bb3504cf2b3ee809ea345e70de6a12c50e11f0501918c3e8910a99b7`,
was installed in place on both phones with exact on-device hash matches and no
idle media resources active. One ordinary background/resume cycle per phone
preserved the app process and showed the current Home address. DHCP was not
deliberately changed again; the stale-to-current transition is covered by widget
regressions. The physical media results below apply to version code 2014.

## Video negotiation and cleanup

Android advertises the H.264 profiles and levels its WebRTC factory actually
supports. The app prefers constrained baseline H.264, followed by VP8, without
changing the advertised capabilities. Native software-codec settings no longer
advertise codecs that the selected factory cannot create.

A negotiated SDP or an incoming video track does not mark startup successful.
The viewer waits for a rendered/decoded frame. If no video arrives within 25
seconds after negotiation, it can retry once with VP8. The updated sender limits
that viewer to at most 720 pixels on the shorter edge, 1280 on the longer edge,
30 FPS and 2.5 Mbit/s. Lower configured limits are preserved. Audio remains in the
camera session. A failed network connection is reported separately and does not
trigger codec retries. A second unsuccessful video attempt stops with an error.

The sender applies limits after its SDP has created encodings. WebRTC may adapt
resolution and frame rate under load. A new offer from the same viewer replaces
its earlier sender peer; stopping the viewer explicitly releases that peer.
Older releases without the Stop endpoint use ICE cleanup. Abandoned offers have
a finite deadline. Metadata requests and statistics samples remain sequential.

Desktop capture now reports a native startup failure instead of publishing a
stream that never started. Android encoder workers are released after use, and
frame scaling checks both dimensions and releases temporary buffers on errors.

### First frame from an unchanged Android screen

Additional device tests exposed a media startup issue after signaling had
succeeded. A second viewer joining an existing Android screen broadcast received
zero frames for 25 seconds while the screen remained unchanged. In a native
Linux receiver observation, the first frame arrived after 40.91 seconds. These
observations describe the affected build before the static-frame correction;
they are not performance results for the corrected build.

Android's screen surface can stop producing frames when its contents do not
change. A new encoder/viewer then needs a current frame even though capture and
ICE are already active. The correction schedules a refresh of the latest valid
texture at most once per second while capture is idle, with a fresh monotonic
timestamp so WebRTC can accept the repeated image. It does not replay a texture
before its first valid frame. Stop cancels the refresh task, and rotation moves
it to the replacement capture surface.

On the S22, three successive viewers of the untouched screen received their first
frame in 3.281, 2.757 and 2.280 seconds. The native Linux viewer received it in
3.31 seconds without retrying the codec, and portrait/landscape rotation passed.
The resource audit then found unused fallback-encoder workers surviving Stop.
Metadata queries now avoid creating those workers. A follow-up S22 test with the
final APK at 1080p/30 FPS received the first frames in 4.314, 3.268 and 2.869 seconds
and left zero encoder workers after every viewer closed, without restarting the
Android process. A camera session also released its encoder worker on viewer Stop.
The original Honor/Windows screenshots identify earlier HTTP signaling failures;
this subsequently reproduced first-frame issue is separate evidence and does not
establish the cause of those photographed errors.

## Android playback audio and broadcast addresses — 2026-10-30

Screen sharing can include the Android device's playback audio on Android 10 or
newer. The option starts enabled and can be disabled before capture. Android
requires `RECORD_AUDIO` permission and screen-capture consent for this API.
BShare captures playback with `AudioPlaybackCaptureConfiguration` using the same
`MediaProjection` as the screen. Its WebRTC recording device stays virtual, so
this mode does not open the hardware microphone. Camera microphone sharing
remains a separate, explicit control.

Only audio that the producing app permits Android to capture is available.
Games, music and video can use supported playback usages; protected content,
calls or an app's restrictive capture policy can remain silent. A successfully
started audio track cannot prove that every currently playing app is capturable.
See [Android's playback capture documentation](https://developer.android.com/media/platform/av-capture).
Unsupported versions, denied audio permission or a capture startup failure keep
screen video available and show the corresponding audio status. An audio-only
failure does not stop the screen session; stopping or replacing that session
releases playback capture and its audio track.

Screen broadcasts display a copyable IP and the actual bound HTTP listener
port. Camera broadcasts show plain address text below the message that the
camera is still being shared, without a copy action; showing the preview hides
that address. Multiple eligible LAN addresses can appear. USB mode instead shows
the phone's BShare port and connects by selecting the physical phone on the PC;
no phone IP or tethering network is needed. The LAN address is the viewer's
signaling endpoint, not a fixed media port. Camera broadcasts start with the local preview hidden, while
camera capture, transmission and its controls remain active.

Physical validation used an Android 14 Samsung S22 Ultra over Wi-Fi and the
Windows PC over Ethernet on the same LAN. The source was a test app generating
440 Hz, 880 Hz and silence in successive two-second segments, without microphone
permission. No audio recordings or video frames were retained.

| Receiver | Observed result |
| --- | --- |
| PC browser/WebAudio | Advancing video and 1,657,440 received audio samples; both tones and silence detected, with maximum PCM RMS 0.20985. |
| Native Windows production media service | Continuous rendered H.264 video at 1080×2316; 263 decoded frames, 999 Opus packets and 959,040 decoded audio samples with increasing audio energy. |
| Camera after stopping screen audio | Camera started with the preview hidden and the real IP/port visible; the native Windows receiver rendered 245 H.264 frames. With the camera microphone off, no audio RTP remained from screen playback capture. |

Both receivers used the direct Ethernet/Wi-Fi LAN route, not an ADB media tunnel.
Android reported the playback recording source as `REMOTE_SUBMIX`, rather than
the hardware microphone. These brief checks establish real playback PCM and
native media reception on this hardware; they are not audio quality, latency,
A/V synchronization or universal application-compatibility benchmarks.
The sanitized report is [s22-screen-audio-review.json](performance/s22-screen-audio-review.json).

## Android to Windows over a USB data cable — 2026-10-30

Camera and screen sharing support an authorized Android USB debugging connection
without USB tethering. Select USB on the phone and computer, start sharing on
the phone, and select it from the computer's physical USB device list. Android
must authorize the computer; wireless ADB and emulators are excluded. Keep the
default BShare port unless the phone uses a different listener port.

Signaling and the phone's media cross the cable. Both peers require relay-only
WebRTC and advertise only loopback relay candidates. The PC's internal TURN
backend is reached through an ADB reverse on Android loopback. Desktop SDK
sockets also use bounded self-address listeners owned by the same PC; those
listeners reject nonlocal sources. They do not create a phone-to-PC LAN media
fallback. USB-only broadcasts reject LAN access to their camera/screen metadata,
negotiation and control routes; file transfers retain their own permissions.

Physical checks used a Samsung S22 Ultra with Wi-Fi disabled and a native
Windows receiver. Camera video, remote capture controls, camera switching,
microphone audio and cleanup passed. Screen reception decoded H.264 at
1080 by 2316 with 540 advancing frames over nine seconds, an observed final
60 FPS and no dropped frames; Opus audio also arrived. The selected camera and
screen paths used relay-to-relay candidates at `127.0.0.1` over TCP. These are
observations on the tested hardware, rather than universal frame-rate or
latency guarantees. No raw media was retained.

See [windows-android-usb-review.json](performance/windows-android-usb-review.json)
for the physical evidence and [USB transport details](USB_TRANSPORT.md) for
protocol and ownership checks. Linux/macOS transport and packaging code do not
establish physical USB coverage on those systems. In OBS on Windows, USB video
can be supplied through BShare's video-only virtual camera. OBS requires no
separate BShare plugin; the desktop receiver opens the USB phone.

## Physical Honor, S22 and Linux checks — 2026-10-24

Both phones ran Android 14: an Honor WDY-LX3 with MagicOS 8 and a Samsung S22 Ultra
(SM-S908U). They used the same production APK, version 1.0.3, version code 2014,
SHA-256 `cf28db1d4a4ac5be139645f4a2976e24d00f2dbb23055bb48e0bd0042af217da`.
The follow-up Home-address correction was not part of that tested APK.

| Path | Result and evidence |
| --- | --- |
| Honor screen → S22 | H.264 decoded with `c2.qti.avc.decoder`; the renderer followed 720×1612 → 1612×720 → 720×1612. Its first rendered frame arrived 0.574 s after codec negotiation. |
| S22 screen → Honor | H.264 decoded with `c2.mtk.avc.decoder`; native codec metrics cover 1080×2316 → 2316×1080 → 1080×2316. One sender encoder worker remained active across rotation; closing the viewer released it. |
| Honor screen → native Linux | H.264/FFmpeg rendered the first frame in 2.806 s; the first recorded statistics contained 37 decoded frames at 720×1612. This Linux case checked portrait; the phone-to-phone case checked rotation. |
| S22 screen → native Linux | H.264/FFmpeg rendered the first frame in 4.808 s without a codec retry; portrait → landscape → portrait sizes were observed. |
| Synthetic Linux source → S22 | Automatic discovery and H.264 decoding passed; the first recorded sample contained 29 decoded frames at 640×360. |
| Synthetic Linux source → Honor | VP8 was rendered through the production viewer after automatic discovery, with one offer and no error. Sender statistics recorded 1777 encoded frames and adaptation up to 1280×720 at a configured 24 FPS. These are producer counts, not Honor decoded-frame counts. |
| Honor camera → native Linux | The unmodified Linux camera UI discovered the phone automatically, without entering an address or pressing Refresh. H.264/FFmpeg rendered video; the first recorded sample contained 10 decoded frames. The native Stop control and window close completed normally. |

The first long Honor camera test decoded 2550 H.264 frames at an observed 28.72
FPS before the LAN addresses changed. Frames last advanced at 87.542 s; the old
address then became unreachable and remote Stop failed. That entire trial remains
marked **failed because of the network interruption**, despite successful video
beforehand. It is separate from the completed trial after reconnecting both phones
at their current addresses.

The completed Honor camera trial ran for 146.38 s and received 2146 decoded H.264
frames, with an observed average of 15.03 FPS and adaptation up to 1920×1080.
Switching rear → front → rear, enabling/disabling the rear flash, and hiding the
local preview preserved the connection. The front camera correctly disabled its
unavailable flash control. Configured 30 FPS is a limit; these observations do not
establish a constant capture rate under other lighting, load or network conditions.

With the microphone enabled using Android's “Only this time” permission, the
muted browser receiver counted 6,900,480 audio samples. Android reported an active
48 kHz recording client that was not silenced. The measured audio energy was zero,
so this verifies audio transport rather than audible content or acoustic quality.
No video frames, photos or audio recordings were retained.

After 73.32 s without interaction with the preview hidden, the black camera overlay
appeared while the Honor remained awake. The same peer received another 902 decoded
frames and 3,495,360 audio samples during that interval. The final two seconds of
the camera trial still had advancing video. Remote viewer Stop returned HTTP 200;
browser media, temporary profiles and test helpers were closed.

Normal source Stop left both phones without BShare foreground services, active
camera clients, projection, CPU/Wi-Fi/multicast locks, encoder/decoder/capture
workers or screen/camera signaling listeners. Screen and camera settings remained
1080p/30 FPS, the rear camera was selected, microphone/flash were off, and each
phone's original rotation settings were restored. The sanitized results are in
[honor-compatibility-review.json](performance/honor-compatibility-review.json).

## Validation and remaining hardware coverage

Desktop automation uses GitHub's `windows-2022` runner and Ubuntu 22.04 with an
isolated X11 display. Native Linux reception was also checked over Wi-Fi from the
physical S22. These results do not establish capture support for every Wayland
compositor or performance on the reported Windows PC.

Regression tests cover network discovery, exclusive HTTP listeners, destination
error reporting, SDP profiles/RTX/audio preservation, zero-frame recovery,
single-peer replacement, stop/cancellation and native codec/encoder cleanup.

`tool/webrtc_interop_probe.py` exercises real video from a browser fixture through
the built native application's signaling, decoder and renderer. Its synthetic
video avoids recording the user's desktop. Use `--help` for the available modes.
Results must record the tested binary hash, platform, negotiated codec, decoded
frames and cleanup outcome.

The browser source has a separate, bounded 45-second startup budget. Two Windows
CI attempts exceeded the previous 15-second limit before BShare launched or any
offer was sent. The probe now records browser launch/readiness, native launch and
cleanup timing, and fails early if the source exits or reports a fatal error.
Late readiness does not turn a failed startup into a pass. This budget does not
extend the native media verification deadline or trigger automatic retries.

Successful builds and these tests do not establish operation on every Android
vendor, GPU, Windows PC or router. Honor/S22 screen streaming in both directions,
rotation and Honor camera reception on Linux now have physical evidence. Both
physical Android devices ran API 34; the configured minimum API 24 and target API
36 do not establish physical coverage of Android 7–16. The reported low-resource
Windows PC remains unavailable for an end-to-end test. Windows CI results cover
the hosted runner, not that PC's codec, firewall or network behavior.

## Primary references

- [WebRTC video codec requirements, RFC 7742](https://datatracker.ietf.org/doc/html/rfc7742)
- [WebRTC Android decoder factories and software fallback](https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/android/api/org/webrtc/DefaultVideoDecoderFactory.java)
- [Android Wi-Fi multicast lock](https://developer.android.com/reference/android/net/wifi/WifiManager.MulticastLock)
