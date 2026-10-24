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

Physical verification of this correction is pending. It must include a viewer
joining an untouched screen, a second viewer, Stop, rotation and resource cleanup.
The original Honor/Windows screenshots identify earlier HTTP signaling failures;
this subsequently reproduced first-frame issue is separate evidence and does not
establish the cause of those photographed errors.

## Validation and remaining hardware coverage

Regression tests cover network discovery, exclusive HTTP listeners, destination
error reporting, SDP profiles/RTX/audio preservation, zero-frame recovery,
single-peer replacement, stop/cancellation and native codec/encoder cleanup.

`tool/webrtc_interop_probe.py` exercises real video from a browser fixture through
the built native application's signaling, decoder and renderer. Its synthetic
video avoids recording the user's desktop. Use `--help` for the available modes.
Results must record the tested binary hash, platform, negotiated codec, decoded
frames and cleanup outcome.

Successful builds and these tests do not establish operation on every Android
vendor, GPU, Windows PC or router. The reported low-resource Windows PC and Honor
MagicOS 8 still require an end-to-end test on their LAN. Record both directions
(Windows to phone, phone to Windows, S22 to Honor and Honor to S22), camera and
screen, and Stop/rotation before marking that hardware verified.

## Primary references

- [WebRTC video codec requirements, RFC 7742](https://datatracker.ietf.org/doc/html/rfc7742)
- [WebRTC Android decoder factories and software fallback](https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/android/api/org/webrtc/DefaultVideoDecoderFactory.java)
- [Android Wi-Fi multicast lock](https://developer.android.com/reference/android/net/wifi/WifiManager.MulticastLock)
