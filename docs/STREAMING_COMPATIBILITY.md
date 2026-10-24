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
