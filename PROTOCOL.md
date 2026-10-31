# BShare local protocol

BShare transfers files and streams media over a local LAN/Wi-Fi network. Android
camera and screen streaming can also use an authorized USB debugging connection.
LAN media uses direct WebRTC candidates; USB media uses a private TURN/TCP relay
on the receiving PC. No cloud account, public relay or Internet connection is
required.

## Discovery

Devices announce themselves on multicast address `224.0.0.251:53318` using UTF-8 JSON packets. The service identifier is `_bshare._tcp.local`, mirroring the mDNS/Zeroconf service name used by BShare-compatible clients.

Announcement payload:

```json
{
  "service": "_bshare._tcp.local",
  "id": "device-uuid",
  "name": "Laptop",
  "platform": "Windows",
  "ip": "192.168.1.20",
  "port": 53317,
  "lastSeen": "2026-06-20T12:00:00.000"
}
```

Clients discard their own ID and treat devices not seen for roughly 20 seconds as stale.

## HTTP API

Each receiving device starts a local HTTP server on the preferred port, default `53317`.

### Health check

`GET /api/ping`

Response:

```json
{"ok": true}
```

### File transfer

`POST /api/transfers`

Headers:

- `content-length`: file size in bytes when known.
- `content-type`: `application/octet-stream`.
- `x-bshare-file-name`: URI-encoded file name.
- `x-bshare-file-size`: file size in bytes.
- `x-bshare-sender-id`: sender device UUID.
- `x-bshare-sender-name`: URI-encoded sender display name.

Body:

Raw file bytes streamed directly from disk. Senders must not buffer complete files in memory. Receivers must stream directly to the configured download directory.

Responses:

- `200` or `201`: accepted and saved.
- `403`: rejected by receiver.
- `404`: unknown endpoint.
- `500`: interrupted or failed while writing.

### Screen and camera streaming

Screen and camera broadcasts reuse the local HTTP listener for signaling. The
displayed port is the listener's actual bound port, which may differ from the
preferred `53317` when it is occupied. WebRTC negotiates the media transport;
this listener is not an RTSP or raw video stream.

| Operation | Screen | Camera |
| --- | --- | --- |
| Active stream metadata | `GET /api/screen/metadata` | `GET /api/camera/metadata` |
| WebRTC negotiation | `POST /api/screen/offer` | `POST /api/camera/offer` |
| Release one viewer | `POST /api/screen/stop-viewer` | `POST /api/camera/stop-viewer` |
| Control the broadcasting camera | — | `POST /api/camera/control` |

Metadata responds with `200 {"ok":true,"metadata":{...}}` when that source is
active, or `503` when inactive. The metadata includes `source`, `generation`,
`trackId`, video geometry, capture settings, and `audio`. Camera audio reflects
the optional microphone state. Screen audio reflects whether device playback
capture started; it does not guarantee that the currently playing app allows
its audio to be captured.

A receiver creates a WebRTC offer with receive-only video and audio, waits for
ICE gathering, and posts `{"type":"offer","sdp":"...","viewerId":"UUID"}`.
The response is `{"ok":true,"answer":{"type":"answer","sdp":"..."}}`.
Apply that answer to the same peer connection. Send `{"viewerId":"UUID"}` to
`stop-viewer` when closing that receiver; this does not stop other viewers.

Camera answers from control-capable versions additionally include
`answer.cameraControls`: `version: 1`, a random `token`, `revision`, `busy`,
`microphoneEnabled`, `torchEnabled`, `torchAvailable`, and `canSwitchCamera`.
Camera metadata includes the same state without the token. Receivers disable
remote actions when the answer lacks this capability. Revisions are monotonic;
ignore older metadata arriving after a newer command response.

Send a JSON object of at most 4096 bytes to `/api/camera/control`:

```json
{
  "viewerId": "the-negotiated-viewer-UUID",
  "token": "the-capability-from-this-answer",
  "action": "microphone",
  "enabled": true
}
```

Actions are `microphone`, `torch`, `switch-camera`, and `stop`. The first two
require a boolean `enabled`. The capability belongs to the live viewer peer
and camera capture session; disconnecting or replacing the peer invalidates it.
In USB-only mode the endpoint applies the same loopback-only restriction as
camera negotiation.
It operates the broadcaster's capture, never the receiver's local microphone.
Remote microphone enablement requires an already granted OS permission; the
user must grant it on the phone first. Network requests do not open permission
dialogs. A successful response is `{"ok":true,"controls":{...}}` containing
confirmed state. Failures include `403 camera-control-forbidden`,
`409 camera-control-busy` / `camera-microphone-permission-denied` /
`camera-control-failed`, `400 invalid-camera-control`, and
`503 camera-share-not-active`.

Unlike `stop-viewer`, `stop` ends the phone's camera broadcast for all viewers.
Its response includes `controls.stopping: true`; capture cleanup starts after
that reply is delivered so a video-only listener can close without draining its
own pending request. This acknowledged stop remains bound to that capture
session even if the requesting viewer disconnects immediately afterward.

Updated senders additionally expose `cameraControls.capture`, without changing
the original version-1 microphone/flash capability. `capture.available: false`
means native camera initialization has not finished or capture capabilities are
unknown; a known unsupported backend sets `available: true` and each property's
`supported: false`. A receiver must not invent fallback ranges or implement
unsupported controls by filtering its video.

The capture object includes the current public `cameraId`, a `cameras` list of
public camera IDs exposed by the device (including lenses when available), and:

- `zoom`, `exposure`, `brightness`: `supported`, and when supported, numeric
  `min`, `max`, `step`, `value`, and `native: true`. Zero `step` means continuous
  device control. Zoom is a capture-device ratio; its supported range and
  optical lens behavior depend on the driver, not the PC renderer.
- `whiteBalance`: `supported`, `modes`, and the confirmed `value`. Only
  advertised modes may be selected, such as `auto`, `daylight`, or `incandescent`.
- `manualExposure`: `supported`, `mode` (`auto`/`manual`), `timeMinMs`,
  `timeMaxMs`, `timeMs`, `isoMin`, `isoMax`, and `iso`. Time is in milliseconds.
- Optional `observed`: whitelisted native capture-result metadata, such as
  sensor frame number, zoom ratio, shutter time, ISO and active physical camera.
  These observations are not decoded images or an arbitrary vendor metadata dump.

`whiteBalanceWarmth` advertises continuous hardware ISP white balance when manual
color correction is supported: `supported`, `min`, `max`, `step`, `value`,
`mode` (`auto`/`manual`), and `unit: "relative"`. The current implementation uses
the range `[-1, 1]`, from cool to warm. It is not a calibrated Kelvin value.
Send `settings: {"whiteBalanceWarmth": 0.4}` to disable AWB and apply sensor gain
and transform controls. Restore automatic balance with
`settings: {"whiteBalance": "auto"}`. The two setting keys cannot appear in the
same command. When manual correction disables AWB, `whiteBalance.value` is
`"off"`; its selectable `modes` still advertise which automatic/preset modes
can be restored. Optional observed `whiteBalanceGains` (four RGGB values),
`colorCorrectionTransform` (nine values), and `whiteBalanceWarmth` come from the
native capture result. Unsupported hardware retains its advertised presets
without presenting a software temperature slider.

`exposure` is actual device auto-exposure compensation in EV. The desktop labels
it as brightness compensation, and disables it in manual exposure mode.
`brightness` denotes an independent camera property and remains unsupported
unless the capture backend exposes that property; it is not an alias for EV.

Send `action: "capture-settings"`, the capture's `cameraId`, and a `settings`
object with one or more of `zoom`, `whiteBalance`, `exposure` (EV), `brightness`,
`exposureMode`, `exposureTimeMs`, and `iso`. Manual shutter/ISO require manual
mode. For example:

```json
{
  "viewerId": "the-negotiated-viewer-UUID",
  "token": "the-capability-from-this-answer",
  "action": "capture-settings",
  "cameraId": "0",
  "settings": {"zoom": 2.0}
}
```

`action: "select-camera"` takes `cameraId` identifying an entry in `capture.cameras`.
It replaces the real capture track and reloads that camera's capabilities.
`switch-camera` preferentially changes between front and rear cameras.

Unknown settings, wrong types and values outside advertised limits return
`400 invalid-camera-control`. Unsupported controls return
`409 camera-control-unsupported`; mode conflicts return
`camera-exposure-manual-required` or `camera-exposure-auto-required`. A capture
settings command bound to another current camera returns
`camera-control-session-ended`. Hardware changes share the existing camera
operation lock with microphone, flash and lens switching. A reply after capture
stop cannot update a later session. Successful replies and metadata publish the
state confirmed by native capture, rather than echoing requested settings.

Capture snapshots also contain `trackId` identifying the current native capture.
Updated receivers include this as `captureTrackId` on capture-setting commands.
The sender rejects an outdated track, even if the user switched away from and
back to the same camera ID. Gesture coalescing must be scoped to the current
viewer/session and capture, so pending slider values cannot cross a connection
restart or a lens change.

Only one source, screen or camera, broadcasts from an app instance at a time.
See the [OBS guide](docs/OBS.md) for forwarding the desktop receiver's video
through the system virtual camera.

### Android USB camera and screen sessions

The desktop selects a physical, authorized USB device through ADB, retaining its
serial and transport ID. Wireless ADB transports and emulators are excluded.
An owned ADB forward carries HTTP signaling to the phone; an owned reverse
exposes the PC's private TURN backend on Android loopback. USB tethering and a
manually entered phone IP are not part of this transport.

The camera or screen offer adds `usbRelay`, containing the Android peer's
session-generated relay configuration:

```json
{
  "type": "offer",
  "viewerId": "<viewer UUID>",
  "sdp": "<complete SDP containing loopback relay candidates>",
  "usbRelay": {
    "iceTransportPolicy": "relay",
    "iceServers": [
      {
        "urls": ["turn:127.0.0.1:55000?transport=tcp"],
        "username": "SESSION_GENERATED_ANDROID_USERNAME",
        "credential": "SESSION_GENERATED_ANDROID_PASSWORD"
      }
    ]
  }
}
```

Port `55000` and both credential strings above are placeholders. A real session
uses its allocated reverse port and independent random credentials for the
Android and desktop peers. Credentials are not discovery metadata or persistent
device settings.

An offer containing `usbRelay` is accepted only from loopback. The source
validates relay-only policy and exactly one authenticated TURN URI using
`127.0.0.1`, a valid port, and `transport=tcp`; external hosts, STUN, UDP and
malformed configurations are rejected. The configuration applies to that peer,
not other broadcasts. When USB-only capture is selected, all camera/screen HTTP
routes, including metadata, offers and controls, reject LAN callers, and offers
without `usbRelay` are rejected. File-transfer permissions remain independent.

The desktop's trusted configuration comes from its owned relay session. Native
SDK sockets may bind to a local interface, so that session additionally supplies
bounded self-address listeners on IPs owned by the same PC. Those listeners
accept only local-PC source addresses; they are not phone-facing LAN relays.
Android still connects through its loopback ADB reverse. Both peers publish and
accept only loopback relay candidates, with no host/LAN candidate fallback.

Metadata reconnects retain the same relay, credentials and viewer identity.
Stopping, disposing or canceling a pending connection releases the owned relay
and ADB mappings without restarting ADB or removing other devices' forwards.
See [USB transport details](docs/USB_TRANSPORT.md) and the
[physical Windows/Android report](docs/performance/windows-android-usb-review.json).

## Errors

Clients should surface no-network, blocked-port/firewall, disconnected-device, rejected-file, interrupted-transfer, and permission-denied errors. Completed and failed transfers are stored in local history.
