# USB media transport

Android camera and screen streams can use an authorized USB debugging connection
without enabling USB tethering. Signaling and media travel through ADB's USB
transport. A cable connection is verified from the ADB server's explicit USB
connection type; a model name, plausible serial number, emulator, or wireless ADB
connection does not establish a cable connection.

The desktop selects one device and keeps its serial number and transport ID.
Forwarding commands target that fixed transport ID, so unplugging and reconnecting
cannot redirect an in-flight command to a replacement transport. USB debugging
must be enabled and the computer authorized on Android. The application does not
accept that prompt or change debugging settings itself.

Desktop installers include a pinned ADB client. When running an unpackaged build,
the desktop still needs an available ADB installation. Resolution checks an explicitly supplied path or
`BSHARE_ADB`, the application's bundled tools, `PATH`, Android SDK environment
variables and standard SDK installation directories. It does not download tools
or accept tool licenses automatically. On Windows an Android vendor may require
its USB ADB driver.

## Use a USB data cable

1. Connect the Android phone to the computer with a data cable. Enable **USB
   debugging** in Developer options and approve that computer on the unlocked
   phone. BShare does not authorize the debugging prompt for you.
2. In BShare on Android, open camera or screen sharing, select **USB**, and start
   sharing. Grant the normal camera, screen-capture or playback-audio permission
   requested by that feature.
3. Open the corresponding viewer in BShare on Windows, Linux or macOS and select
   **USB**. Choose the authorized physical phone from the list. **Refresh USB
   devices** updates an empty list or a device awaiting authorization.
4. Keep the default BShare port `53317` unless the phone shows another port.
   This is the BShare listener, not an ADB pairing or debugging port. No IP address
   or USB tethering network is entered.

An unauthorized entry means the phone still needs to approve this computer.
An offline entry needs its cable/debugging connection restored. After unplugging
and reconnecting, refresh and open a new viewer session; an old session never
silently switches to another transport or device.

USB mode sends the Android camera/screen and its enabled audio to the desktop.
It does not add USB file transfers, PC-to-phone screen capture or iOS USB capture.
Use the existing Wi-Fi/Ethernet LAN flow for those supported LAN operations.
An independently started LAN file receiver can remain active while a USB video
session restricts its own media endpoints to the cable connection.

Android screen audio requires Android 10+ and a source app that permits playback
capture. The phone microphone is not used for internal screen audio. Camera
microphone audio is separate and starts off. See [OBS and audio setup](OBS.md)
for using received video with the system virtual camera.

## Connection

1. An ephemeral ADB forward connects desktop loopback HTTP to the Android BShare
   signaling port.
2. A session-scoped TURN backend listens on desktop IPv4 loopback. An ephemeral
   ADB reverse makes that backend available on Android loopback.
3. Each WebRTC peer uses its own random TURN credentials and requires
   `iceTransportPolicy: relay`. Android's TCP-only TURN URI is loopback. The
   desktop also gets local self-address TCP endpoints described below.
4. The Android offer includes its USB relay configuration. The source accepts
   that configuration only from loopback signaling, with the existing viewer
   authorization. It applies to that peer rather than changing other sessions.

ADB listener specifications use `tcp:localhost:<port>`, not an unspecified listening
address. This matters because Android's ADB daemon may bind an unspecified TCP
listener to all interfaces, and a desktop ADB server started with `-a` can do the
same. The ADB command-line client rejects hostnames in forwarding source ports,
and the server's hostname parser rejects port zero. BShare therefore sends the
standard smart-socket forwarding request directly, selects a random high port,
and uses `norebind` with bounded retries on collisions. The request targets the
verified transport ID. It never replaces another listener.

Both encrypted media legs use TURN over TCP. The relay allocates genuine
loopback UDP addresses but forwards packets only between its two authenticated
allocations. It cannot send to a LAN address, Internet address, another loopback
service or an arbitrary UDP peer. DTLS/SRTP encryption remains between the WebRTC
peers. No public TURN service or Internet connection is involved.

The native Windows SDK binds its outgoing TURN socket to a local interface.
Windows rejects a socket bound to an Ethernet address when connecting to
`127.0.0.1`. For that desktop leg, the relay also binds explicit self-address
listeners on up to seven IPv4 addresses owned by this PC. They accept only
connections whose source address also belongs to this PC; no wildcard listener
is opened. A socket can therefore connect to its own local address without
sending media to another machine. The loopback backend remains a fallback.
Each endpoint uses a separate ICE server entry, within the SDK's eight-entry
limit. The phone always reaches the backend through USB and its loopback reverse.
Both advertised relay candidates remain `127.0.0.1`; self-address endpoints do
not introduce host/LAN candidates or a phone-to-PC LAN fallback.

The relay implements standard long-term TURN credentials with random passwords,
per-connection nonces, HMAC-SHA1 message integrity, allocation refresh,
CreatePermission, Send/Data indications and ChannelBind/ChannelData. It limits
clients, allocations, frames, pending output and idle opening time. Each role can
hold one allocation, giving two allocations per USB session. It is an internal
USB transport component, not a general-purpose public TURN server.

Closing the session closes its relay and removes only the ADB mappings it owns.
Cleanup checks the selected transport and mapping destinations. It never runs
`--remove-all`, kills the ADB server or connects another device for cleanup.

## Offline behavior and validation

The pinned WebRTC m144 allocator falls back to an any-address network when no
network interfaces are available. That permits a TCP connection to the loopback
TURN backend without requiring a Wi-Fi or Ethernet address. Relay-only policy
and loopback relay candidates prevent a direct LAN media fallback. Physical checks must
still establish video reception with Wi-Fi/tethering disabled and record the
selected relay candidate pair; a successful signaling request alone is not proof
that media crossed the cable.

TCP preserves packet order, so cable congestion can delay later media packets.
This transport does not establish a universal latency advantage over a good LAN.

Run the isolated core tests with:

```powershell
flutter test test/services/usb_adb_transport_service_test.dart test/services/usb_turn_relay_test.dart
```

Tests use mocked ADB commands and loopback sockets rather than a phone or emulator.
The smart-socket regression covers fragmented acknowledgments, the transport
selection handshake and an occupied port. A physical cable smoke test also
confirmed that session open and close create and remove the two owned mappings;
this is separate from receiving actual video over the cable.
The TURN relay was also checked against an independent `aioice` client for
authenticated TCP allocation, bidirectional ChannelData, invalid credentials and
allocation limits. These core checks do not establish a physical USB video test.
The desktop self-address path was separately checked with a client socket bound
to its own Ethernet IP; allocation returned a loopback relay address while the
mapped address correctly reflected that local socket.
The sanitized core results are recorded in
[usb-turn-relay-review.json](performance/usb-turn-relay-review.json).

The completed physical Windows/S22 review separately establishes camera video,
internal screen audio, phone controls and screen fullscreen while the phone's
Wi-Fi was disabled, with relay-to-relay selected candidates and normal cleanup.
See [windows-android-usb-review.json](performance/windows-android-usb-review.json).
Local recording and preview-independent virtual-camera output have their own
[desktop capture review](performance/desktop-camera-media-review.json).
Those reports identify their tested artifacts, including pre-release 1.0.4
builds; they do not certify every phone, Linux/macOS hardware configuration or
the subsequently generated v1.0.5 installer files.

## Primary references

- [AOSP ADB device schema: connection type and transport ID](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/proto/adb_host.proto)
- [AOSP ADB host services and protobuf tracking](https://android.googlesource.com/platform/packages/modules/adb/+/HEAD/docs/dev/services.md)
- [AOSP ADB socket binding behavior](https://android.googlesource.com/platform/packages/modules/adb/+/refs/tags/android-mainline-11.0.0_r31/socket_spec.cpp)
- [AOSP ADB command reference](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/user/adb.1.md)
- [WebRTC m144 allocator: any-address network fallback](https://github.com/webrtc-sdk/webrtc/blob/m144_release/p2p/client/basic_port_allocator.cc)
- [TURN protocol, RFC 8656](https://www.rfc-editor.org/rfc/rfc8656.html)
- [AOSP ADB license notice](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/NOTICE)
- [Android SDK license: open-source component exception](https://developer.android.com/studio/terms)
