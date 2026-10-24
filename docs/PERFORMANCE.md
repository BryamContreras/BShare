# Performance and lifecycle checks

## Streaming compatibility investigation (unreleased)

The final Dart revision passes 440 Flutter tests and static analysis. Regression
coverage includes discovery without a default route, session cancellation,
exclusive HTTP listeners, SDP negotiation and native encoder/capturer cleanup.
The local Linux production receiver passes H.264, VP8, one successful recovery
from missing frames and bounded failure after both attempts. A separate diagnostic
entrypoint also passes four receiver cases and three native capture/encoder cases
on an isolated Xvfb display. Diagnostic binaries are not installer payloads.

On a physical S22 Ultra running Android 14, the initial candidate receives both
codecs and sends rotated screen content, rear/front camera video and microphone
audio over Wi-Fi. Camera decoding measured about 29 FPS in these short sessions.
These results do not measure the reported low-resource Windows PC or Honor.

Physical tests exposed an additional idle-screen defect: a later viewer waited
25.654 seconds for its first frame; the native Linux viewer waited 40.91 seconds
and retried the codec. The updated Android capturer refreshes an unchanged valid
texture at most once per second, preserves monotonic timestamps, and cancels its
task on Stop, rotation/helper replacement and projection revocation. Its native
regressions pass. The corrected APK is built, but physical revalidation is pending
because the phone disconnected from ADB before installation. Windows verification
is running in Actions. These pending checks are not recorded as passes.

Binary hashes, measurements, cleanup and hardware limits are recorded in
[streaming-compatibility-review.json](performance/streaming-compatibility-review.json).
Connection diagnosis and reproduction guidance are in
[STREAMING_COMPATIBILITY.md](STREAMING_COMPATIBILITY.md).

## Linux window decorations (1.0.3)

The Linux runner no longer installs a custom GTK header bar or draws its own
minimize, maximize, restore and close buttons. It leaves `GtkWindow`'s title bar
unset and requests normal window decorations. GTK and the active compositor or
window manager now provide the title bar, controls, placement and theme, as they do
for other desktop applications. This avoids differences between manually drawn
controls and each desktop environment's style.

The automated Linux fixture checks that BShare requests standard decorations and
has no custom title-bar widget. GTK renders its standard themed titlebar or
negotiates decorations with the compositor, depending on the desktop. The
headless CI fixture does not render that title bar, so its exact appearance still
depends on the user's active desktop theme. Earlier Cairo-control checks and
screenshots below refer to 1.0.2. Linux window shutdown and Windows messenger
shutdown checks remain separate.

## Uniform settings and desktop branding (previous revision)

Settings now uses the same `SettingsSection` card, heading, spacing and outlined
field decoration throughout. The groups are Device, Transfers, Appearance and
Screen sharing, with Camera added only on Android/iOS. Port, automatic reception,
download folder and history cleanup belong to Transfers. Device name and port
drafts survive automatic saves of other preferences.

Linux, Windows and macOS do not display camera capture settings or enumerate
camera hardware from Settings. Saving other desktop preferences preserves the
stored rear/front/per-device camera profiles. Mobile camera resolution and frame
rate controls remain available, with the existing maximum of 60 FPS.

Desktop branding is in the left navigation header. Home uses its localized page
title in the toolbar; other page titles remain intact. The sidebar fills the
window height and scrolls in short windows. Below 900 dp it becomes an 80 dp rail
with the brand and all seven destinations, tooltips and accessible labels; larger
windows use the 280 dp sidebar. Mobile branding and bottom navigation are preserved.

The content wrapper keeps the same widget hierarchy across the 900 dp breakpoint.
This fixes the Settings scroll reset observed when narrowing the Linux window;
state and scroll-position tests cover both resize directions on all three desktop
platform themes.

The final Flutter suite passes **403 tests**, including 41 focused settings and
navigation checks, and `dart analyze --fatal-infos` reports no issues. The full
suite uses an isolated network namespace with loopback enabled: its exclusive UDP
cleanup assertion must not conflict with the user's running BShare instance. Test
assertions are unchanged and the user's application remains running.

Linux and universal Android release builds complete successfully. The current APK
is SHA-256 `d1b846184081e96a3e110556e9c45c776bcce1987dc890095bc1b18a602b76b3`.
Static inspection confirms three complete AOT architectures, 24 native libraries,
64-bit 16 KB ELF/ZIP alignment and the three ML Kit registrar constructors. The
S22 is unavailable over ADB, so this UI revision has not been installed or exercised
on the phone. Earlier physical media and permission results below apply to their
recorded APK hashes; these UI changes do not claim a new streaming benchmark or
physical Windows/macOS validation.

The final release window was exercised on KDE/Wayland at widths 1280 and 800,
including a return to 1280 while Settings stayed near its end. The compact Home
layout, four matching desktop settings groups and native window controls were
visually checked. Closing through the native button returned exit code 0. Owned
windows, processes, D-Bus helpers, KWin scripts and temporary XDG/build directories
were removed; the user's open BShare instance and preferences were preserved.

Validation and current artifacts are recorded in
[settings-sidebar-review.json](performance/settings-sidebar-review.json).

## Home, desktop navigation and transitions (previous revision)

Mobile Home cards use slightly smaller type: 20/15 dp titles and 13/12 dp
descriptions according to card width. Desktop type and the inherited text scaler
are preserved. The desktop menu fills the window height and begins at the top;
its existing scroll area keeps every destination reachable in short windows.
It now contains **Compartir pantalla** and **Cámara del dispositivo**, linked to
the existing sharing routes. Mobile destinations remain Home, Send, Receive and
Transfers.

Android and desktop route transitions use a stationary fade of 140 ms when
opening and 110 ms when closing. iOS retains its interactive native Back gesture.
The page builders, theme changes and scroll-to-top action respect the system's
disabled-animation setting. Clearing selected files is immediate, with no
per-row slide or delayed deletion; application enumeration no longer waits for
an artificial 120 ms delay. Video rotation stabilization remains independent of
navigation animation.

In the 1.0.2 implementation, Wayland used a compact custom GTK header bar while
some X11 window managers drew their own title bars. Version 1.0.3 removes that
split and uses the default GTK/window-manager decorations. The previous awaited
engine/window cleanup remains in place. Earlier observations are recorded in
[desktop-polish-review.json](performance/desktop-polish-review.json).

The archived Linux bundle from 1.0.2 was exercised on KDE/Wayland with the
Breeze GTK theme. The custom controls in that build were visible and worked under
the recorded test conditions. Version 1.0.3 delegates window controls to GTK and
the active desktop environment. The sidebar behavior is unchanged.

## Android compatibility and permission lifecycle (previous revision)

The Android build is configured for API 24 (Android 7) through target API 36
(Android 16). The universal release includes complete ARM32, ARM64 and x86-64
native library sets. This minimum configuration is separate from the OS versions
and hardware actually exercised below.

Shared file access uses the legacy storage permission through API 29 and all-files
access from API 30. App-private directories need neither grant. Permission state is
read again before browsing, accepting a file, changing the download destination or
writing a received file; grants are not cached. Denial preserves the selected
destination, ends pending file decisions and displays the appropriate error.
Older permission results cannot disable a newly selected valid destination.
Camera/screen signaling can run without granting access to shared files, and an
existing signaling listener can be promoted to file reception without a duplicate
server. Notifications, Wi-Fi connections and hotspot creation request only the
permissions required by that Android version and operation. Exact location remains
required for the scan-based connection path; Nearby Wi-Fi permission alone does
not substitute for it.

Emulator testing exposed an additional lifecycle defect in the first candidate:
Android killed the application UID after storage permission revocation, but the
upstream sticky native service restarted without its Dart receiver. The final
candidate uses a local MIT-licensed `flutter_background` fork with
`START_NOT_STICKY`, defensive shutdown for null/unknown intents, idempotent Start
and release of both CPU and Wi-Fi locks. File transfers declare the
`connectedDevice` foreground service type; camera/microphone and screen projection
keep their dedicated execution services.

The S22 additionally retained an OS service record with `app=null` and its old
notification after the UID was killed, without a process, locks or HTTP listener.
The fork reconciles that record when a new Flutter engine attaches: it stops the
old service only if this process has no live service instance. This avoids
interrupting an existing native service when another engine attaches. Code in a
terminated process cannot clean Samsung's retained notification before the app
is reopened.

The final release build and analyzer finish successfully, and the complete Flutter
suite passes **383 tests**. APK inspection confirms all three AOT architectures,
24 native libraries, the expected ELF machine types and 16 KB ELF/ZIP alignment
for the packaged 64-bit libraries. QR inspection confirms the three ML Kit
registrars retain their public no-argument constructors. These inspections do not
establish camera decoding or operation on a kernel with 16 KB memory pages.

The production HTTP transfer benchmark ran three rounds with 32 MiB files at
concurrency one and three, plus 20 start/stop cycles. All files were verified;
the four cancellation/cleanup checks pass, file descriptors remain at 10 across
the cycles and no sockets remain. These loopback observations are not phone Wi-Fi
throughput measurements or evidence of an FPS improvement.

Artifact hashes, permission rules, runtime results and cleanup scope are recorded in
[android-compatibility-review.json](performance/android-compatibility-review.json).

The final APK (`5ff3674cb5d76bd8b16f9fe47b1030956356d155244defbf778a6b9137260e7c`)
passed receiver/revocation/restart/Stop checks on Android 10, 12 and 16 x86-64
emulators. Each received two real files with matching SHA-256; revocation left no
process, service, notification, lock or listener at 2 and 15 seconds, before any
force-stop. Reopening Home without Start remained clean, and explicit Start/Stop
worked after permission restoration. All temporary AVDs, forwards and fixtures
were removed after testing. These HTTP checks used emulator ADB forwards.

The same APK was installed in place on the Android 14 S22 Ultra and its installed
hash matched. The final Home screenshot showed all four mobile cards without
overflow. With the receiver active, revoking shared-storage access caused Android
to kill the UID as expected. Samples starting at 2 and 15 seconds found no process,
service record, notification, CPU/Wi-Fi lock or HTTP listener. Reopening Home without
Start remained clean. This final attempt did not reproduce Samsung's retained
`app=null` record seen in the historical candidate, so it does not separately prove
removal of such a retained record by the engine-attachment hook.

After restoring the original all-files grant, an explicit Start received a real
262,199-byte file over the Wi-Fi LAN from the PC. The saved SHA-256 matched the sent
payload and the test file was removed. Tapping Stop closed the foreground service
and listener while retaining the same idle application process; no force-stop was
used. Final checks found no camera client, active recorder, projection, source HTTP
listener, foreground service or owned CPU/Wi-Fi lock, and display brightness had
returned to the system default. The app was left on Home with the original storage
grant restored. Device UI dumps were removed, owned helpers finished and the user's
ADB server was preserved. This final physical run did not retest camera/audio
transmission; the earlier media observations remain scoped to their retained APKs.

## Responsive camera display and controls (previous revision)

The inactivity overlay now uses the app's small text style with an explicit 12 dp
base font, regular weight, no decoration and subdued white on black. It previously
inherited a fallback text style outside the route Scaffold. Its content is centered,
bounded to 280 dp, respects safe areas and can scroll when the available height is
very small. Touching any part of the dim screen restores the display. The semantics
tree exposes only the wake action while dimmed, preventing activation of hidden
controls with a screen reader.

Live camera controls retain transparent backgrounds and minimum 48 dp touch targets.
On short displays, the optional controls scroll in a bounded area while Stop remains
visible. The header, error message and hidden-preview content accommodate smaller
heights. Settings selections use one-line ellipsis; their menus retain full wrapping
labels. The tablet/desktop sidebar scrolls and navigation rows grow with their text.
No Samsung-specific screen dimensions or device checks were added.

The complete Flutter suite passes **279 tests** and analysis reports no issues.
Component tests exercise portrait, landscape, split-screen-sized viewports, tablet
sizes, Spanish/English text, display densities from 1 to 3, safe-area insets and
injected text scales up to 3×. The dim overlay also passes an extreme 216×120 dp
viewport check. These component stress tests inject their own text scale; the
existing app-wide font-scale policy is unchanged. Home and camera setup already use
scrolling/adaptive layouts; their existing labels may abbreviate with ellipsis.

The optimized release was installed in place as **BShare Optimizada** on the S22
Ultra (Android 14). The pulled installed APK matches SHA-256
`28f5191c11ede930acc0aef76ce3f53460032556199ac7a32e346dc71fc11f43`.
A physical run confirmed the small hint after 60 seconds of inactivity, brightness
`0.01`, an awake/unlocked phone, active camera and inactive microphone. One tap
restored the controls while keeping the local preview hidden. Stop returned to
camera setup and app Back returned Home. Camera clients, recorder, foreground
services, camera wake lock, projection and source HTTP listener were released;
brightness returned to the system default. No Flutter/Android runtime errors were
found in the application log. Owned build/test helpers completed and the temporary
device UI dump was removed.

Evidence and the responsive matrix are recorded in
[s22-camera-responsive-review.json](performance/s22-camera-responsive-review.json).
This revision changes four presentation files; the Android DEX matches the previous
AV revision. The earlier PC audio/video observations apply to their retained APK.
This revision does not establish compatibility with every Android OS or device;
other hardware, USB and iOS were not physically tested.

## Camera controls, microphone and flash (previous revision)

Camera broadcast controls form a vertical column at the upper right. Icons have
transparent backgrounds and shadows for contrast. They switch camera, show/hide
the local preview, toggle flash, toggle microphone and stop sharing. Back stays
available at the upper left. The receiving camera viewer also uses a transparent
Stop icon, preserving inactivity hide/reveal and awaited shutdown.

Microphone capture starts off and requests recording permission only when enabled.
The camera connection reserves an audio sender while capture is off, so enabling
or disabling audio uses the same peer and video connection. Video and audio share
the negotiated stream identity for WebRTC synchronization. Audio capture has its
own stream; changing front/rear cameras retains that capture. Disabling microphone
removes sender tracks and releases recording hardware. Preview visibility does
not change audio or video transmission. Native desktop WebRTC handles playback.

Android explicitly disables WebRTC's recording device before camera signaling.
The native factory retains that setting for subsequently created peers. A reserved
audio channel can otherwise open `AudioRecord` even without a local audio track;
detaching that track alone can silence transmission while recording stays active.
The Android SDK also prepares a recording device for a disabled sender. Preparation
therefore uses its virtual reader; the reader's start callback enables hardware
only for an authorized microphone session, retaining the existing JNI buffer.
Microphone activation enables recording after permission/service readiness; Off,
Stop and disposal disable recording before releasing tracks or awaiting other work.
A recording-gate failure closes sending peers and still releases local audio.

Android uses one camera foreground service. Its microphone execution type is added
only after permission and a foreground lifecycle check, and removed after capture
is released. Starting capture waits for the foreground service to confirm readiness.
Cancelled or timed-out service starts cannot revive a stopped session. Microphone
permission requests and media acquisition are serialized; a late result after Stop
cannot reopen capture. The controls queue releases completed futures while idle.

Flash availability comes from the active camera's hardware. Switching cameras or
stopping releases an enabled torch. Android capability checks do not dereference
a capture session that may still be opening; torch updates run on the camera
thread and return one result even after closure or timeout. Twelve native scenarios
cover these cases, and nineteen focused native scenarios cover recording-gate
ordering, virtual initialization, new peers and failure cleanup. The Flutter suite
passes **248 tests**, and analysis is clean.

Android local media disposal now releases temporary audio-source wrappers, local
track wrappers and native stream references. Ownership follows wrapper identity:
shared local tracks survive until their final stream releases them, while borrowed
remote tracks keep their peer owner. Stopping a track before disposing its stream
does not release the same wrapper twice. Renderer detachment precedes track release;
capture cleanup runs outside the ownership lock. Fifteen native ownership scenarios
include 1,000 modeled microphone cycles with balanced reference counts. These are
SDK ownership-model checks, not measurements of the phone's heap usage.

The final Android release was installed as **BShare Optimizada** on the S22 Ultra
(Android 14); the pulled installed APK matches SHA-256
`6ec9ce105c7ac021bb202a6a0fa7fb3d29aa6ad069cc0dfe7029de5a1480277f`.
Wi-Fi checks with the native Linux viewer confirmed audio after the first permission
grant, microphone Off/On on an existing connection, camera switching with preview
hidden, torch activation/reset and a new viewer joining with microphone already
enabled. Android recording was inactive and PC output silent with microphone Off,
including after another viewer joined. A brief controlled speaker signal verified
the front-camera audio path during an otherwise quiet interval; only aggregate PCM
measurements were retained.

The independent receiver decoded **4,735 additional video frames** across 34 sampled
observations, receiving H.264 video and Opus audio. Capture settings remain ceilings:
WebRTC adapted resolution during reconnection and later returned to full resolution.
Stable intervals measured about 30 decoded FPS at the configured 30 FPS ceiling;
the frontal-camera interval measured 29.98 FPS across 75.68 seconds. These rates
exclude changes of RTP identity, source track, dimensions and capture configuration.
At inactivity dim, brightness was `0.01`, the phone remained awake/unlocked and media
continued. Both native PC windows exited with status zero. System Back stopped the
phone stream and returned to camera setup; app Back then returned Home. Final checks
found no camera client, active recorder, transmission service, camera wake lock,
projection or source HTTP listener. Owned browser/probe/build helpers were closed
and the temporary audio sink was unloaded without changing the default audio sink.

Final artifact/source hashes, scoped native checks, sampled media metrics, physical
observations and cleanup evidence are recorded in
[s22-camera-av-review.json](performance/s22-camera-av-review.json). These checks cover
one S22 and a Linux PC over Wi-Fi; USB hardware and iOS execution remain unvalidated.

## Camera viewing and capture interface (previous revision)

Opening a remote camera stream now uses the dedicated viewer surface, following
screen viewing. The Stop control appears above the video and hides after three
seconds without interaction; touching or moving over the viewer reveals it again.
Closing the viewer or using Back awaits the existing shared video teardown.

Starting camera transmission on a mobile device opens a dedicated full-screen
camera view. Overlay controls switch between rear/front cameras, toggle local
preview visibility and stop sharing. The eye control changes only the local
preview: capture, remote video and the configured resolution/FPS remain active.
The existing session-owned keep-awake and 60-second dim/wake behavior also applies
to this view; changing routes does not create another capture or display timer.

Camera selection and Settings now expose only **Rear camera** and **Front camera**.
Enumeration reads native facing metadata and retains the SDK's preferred logical
camera for each side, with the real device ID used internally for capture. Extra
ultra-wide, telephoto and virtual sensors do not become separate choices. A device
with only one camera side exposes only that available side. Inputs without facing
metadata can supply a single rear/default choice when no known rear exists.

Settings use independent rear/front resolution and FPS profiles, capped at 60 FPS.
The individual-camera detection and override interface has been removed. Existing
per-device overrides remain stored for safe settings round trips, but capture,
switching and the displayed profile use the rear/front settings instead. Resolution
and cadence remain device-dependent ceilings, with proportions preserved.

The final revision passes **228 Flutter tests** and analysis reports no issues.
Release builds completed for Android and Linux. The APK was installed in place as
**BShare Optimizada** on the S22 Ultra; its pulled hash matches the delivered APK.
A final Wi-Fi run verified dedicated viewing, Stop auto-hide/reveal, Stop followed
by reconnection, front/rear switching with the local preview hidden and closing the
Linux window with live video (exit status zero). Android Stop returned to camera
setup, then Back returned Home; camera clients, transmission services, projection,
HTTP listener and display overrides were cleared.

The initial interface build also retained the browser connection and advanced
**2,676 decoded frames** while the local preview was hidden, including a front/rear
switch with the same session generation. After the 60-second dim was confirmed,
**403 further frames** were decoded before waking the display; the phone remained
awake and unlocked. These sampled checks establish continued video at the observed
points, not absence of shorter pauses or a latency/performance improvement.

Physical testing found an expired temporary Android camera permission could be
classified as permanently denied by the permission plugin, preventing a new native
request. Explicit actions now make one serialized native request even for that
status; Android still decides whether to show a dialog. The final APK displayed
the permission dialog and started capture on the first attempt after selecting
**Solo esta vez**, without an ADB permission grant or automatic retry loop.

Build/source hashes, test results, separate initial/final device evidence and
cleanup checks are recorded in
[s22-camera-ui-review.json](performance/s22-camera-ui-review.json). Camera imagery
remains in ignored local evidence. The **205-test** suite and S22 measurements in
the next revision section are historical evidence for the earlier build. Physical
USB validation remains pending; these device checks used one Android phone and a
Linux PC over Wi-Fi.

## Repeatable transfer benchmark

The repository includes a repeatable benchmark using the production
`FileTransferClient`, `FileServer`, and `TransferControl`, without a Flutter engine.
It runs sender and receiver in one Dart process over IPv4 loopback. It exercises
HTTP streaming, local file I/O, three concurrent uploads, cancellation, and teardown.

```bash
flutter pub get
dart run tool/transfer_benchmark.dart --file-mib=32 --rounds=3 --cycles=20 --json=/tmp/bshare-performance.json
```

For an already resolved checkout, execute Dart directly to avoid dependency
resolution:

```bash
dart --packages=.dart_tool/package_config.json tool/transfer_benchmark.dart --json=/tmp/bshare-performance.json
```

The command exits with status 1 if a lifecycle check fails, a transfer fails,
content differs, or cleanup fails. Review `checks` and `errors` in the JSON report.
Temporary source files, received files, servers, timers, and clients are closed
and removed in `finally` blocks. Nothing is installed or left listening.

## Device camera, mobile navigation and display lifecycle (previous revision)

The mobile menu now contains Home, Send, Receive and Transfers, retaining the full
Spanish label **Transferencias**. Screen remains in the desktop menu. Home offers
**Compartir pantalla** and **Cámara del dispositivo**; screen-sharing actions appear
after the status/device list. The camera page has Wi-Fi/USB selection, video-only
capture on mobile and a camera viewer on desktop.

Camera capture uses the existing `ScreenShareService`, renderers and peer cleanup,
with separate `/api/camera/offer` and `/api/camera/metadata` endpoints. Only one local
video source is active. Changing camera releases the previous capturer before
opening another, replaces sender tracks on existing peers and retains the session
generation; failure restores the previous camera or closes the session. Camera
metadata uses camera frames, never screen/display dimensions. That previous
revision exposed front/rear profiles and individual-camera overrides, persisted
separately from screen sharing. The latest interface above replaces that override
workflow with only the two facing profiles. Validated FPS choices are 15/24/30/60;
supported cameras, formats and actual cadence depend on the device and connection.

Camera display state is session-owned, including across Settings/navigation.
An inactivity timer dims the window and displays a black overlay at 60 seconds;
touch restores the display without activating the underlying control. It keeps
the device awake and restores its original display state after normal stop,
controller disposal or failed platform updates. Android has a dedicated camera
foreground service and permission/type, plus native Activity-destruction cleanup
for camera/screen services when Dart's asynchronous cleanup cannot finish. iOS
has idle-timer/brightness restoration, including a background brightness reset;
iOS compilation and device behavior have not been validated on this Linux host.

The QR scanner does not allocate a controller, request permission or start another
camera while a camera stream is active/starting. It displays a localized Camera in
use view, with an action returning to the stream, and becomes available after
sharing ends. Late permission results cannot reopen the scanner after that guard.

USB video uses the network created by Android USB tethering. Sources require a
real USB interface; desktop clients require a target in that interface's exact
subnet. Signaling binds to the USB IP, ICE host candidates are restricted to that
interface and the camera HTTP endpoints restrict remote subnets. Missing wired
interfaces/candidates fail explicitly, without a Wi-Fi fallback. Android sources
and Linux/Windows/macOS interface detection are implemented. iOS sources currently
use Wi-Fi. Loopback/CIDR transport tests are controlled network checks, not evidence
of a physical USB cable test.

That revision passed **205 Flutter tests**; its analysis reported no issues.
Coverage includes camera capture/switch/rollback, duplicate starts, cancellation,
per-camera settings, receiver/display cleanup, 60-second dim/wake timing and
QR/camera exclusion. Physical permission testing found Android can return CAMERA
permission before Flutter receives `resumed`; capture now waits for that event,
with a three-second bound and cancellation, while rejecting background starts.
The updated release started on the first attempt after granting CAMERA again.

Physical Wi-Fi tests used an S22 Ultra on Android 14, the native Linux viewer and
an independent browser receiver. The updated APK delivered H.264 video at about
**29.34 decoded FPS** for the rear camera configured at 1080p/30, and **15.01 FPS**
for the front camera at 720p/15. Switching retained the session generation and
connection. Portrait/landscape dimensions followed rotation. At 60 seconds without
touch, the black overlay and brightness `0.01` were observed while the phone stayed
awake/unlocked and decoded frames continued on the PC; touch restored controls.
These are measurements on one device/network, not guaranteed rates on every phone.

Desktop lifecycle testing also found an EventChannel callback outliving its native
owner. Peer close now preserves the channel until Dart cancels it during disposal;
native disposal unregisters the callback and releases the peer. A subsequent real
Stop test exposed an invalid state query after native Close, so disposal uses the
library's idempotent Close directly. Regression checks include 200 cycles with the
real libwebrtc library and 200 with ASan/UBSan. A separate Linux messenger fix uses
shared RAII ownership to release response handles exactly once, including copied,
concurrent, failed and omitted replies; 1,400 cases pass sanitizer checks. Baseline
checks reproduce the original use-after-free and retained response-handle reference.

Closing the entire Linux window with live video exposed a separate Mesa-exit
crash: Flutter could quit while its raster thread was still drawing. The app now
awaits networking/capture cleanup through `didRequestAppExit`, coalescing repeated
close/detached notifications. The Linux runner retains its own windows, destroys
their FlViews and dispatches pending tasks until engine finalization. This also
waits for asynchronous `RemoveView` work. A 500-window GLib fixture covers delayed
and cross-thread releases; actual window-close checks are recorded separately in
the device report. The fixture models window ownership and does not replace the
real Flutter/Mesa test. The final native release completed **three real viewer
Stop/reconnect cycles** and **two window closes with active video**, with both
application exits returning status zero. Final Android Stop left no camera
clients, foreground transmission services, projection, owned HTTP listener,
camera wake lock, or keep-screen-on/brightness override.

The final APK was installed and its pulled hash matched the delivered file.
An additional 36-sample Wi-Fi run measured about 29.02 decoded FPS for the rear
camera and 23.91 FPS for the front camera, both configured with a 30-FPS ceiling
at 1080p. The connection/session survived switching and frames continued through
a second dim/awake check. These final measurements illustrate that a selected
FPS ceiling is not a guaranteed camera cadence; no cause for the lower front
camera cadence is inferred from this test.

The production-service loopback benchmark was repeated for that revision in
[camera-review-transfer.json](performance/camera-review-transfer.json): 20 sessions
retain **10 → 10 descriptors** and **0 → 0 sockets**, with all content,
cancellation and cleanup checks passing. Median aggregate rates are 59.11 MiB/s
for one upload and 135.83 MiB/s for three concurrent uploads. These local HTTP/I/O
results do not measure phone-to-PC Wi-Fi throughput or end-to-end video latency.

Home, camera navigation and USB rejection without a cable were checked in the
native Linux UI using an isolated profile. The user can currently test Wi-Fi only,
so physical USB validation is pending. Device/build and final lifecycle evidence
for that previous revision is recorded in
[s22-camera-review.json](performance/s22-camera-review.json).

## Settings, navigation and resource review (previous revision)

This revision adds a 12-second discovery feedback window, removes the three-second
announcement interval from the interface, and keeps listening after that window.
Screen actions are rounded horizontal buttons, stacked on narrow displays.
Android navigation includes Screen; both Back controls use a bounded route history
without retaining previous screens, cameras or renderers. Completing a file picker
or QR connection removes that completed screen from the return path.

Settings now persist a shorter-edge resolution limit (480/720/1080/1440/original)
and a frame-rate limit (15/24/30/60 FPS), applied to the next transmission.
Android limits the capture buffer before encoding and caps source cadence without
cropping. Desktop constraints and per-sender limits use the same session settings;
sender updates are serialized and reapplied when frame dimensions change. These
are ceilings: WebRTC can adapt below the selected resolution/FPS, and a static
source need not generate frames at the selected rate. Original size never upscales.

Additional audit corrections:

- Settings changes serialize against the latest saved values, write only changed
  preferences and preserve unfinished text edits. Explicitly disabled auto-accept
  survives migration. Folder/auto-accept updates apply to new requests while each
  active request retains its original destination and decision policy.
- A receiver started for screen sharing is stopped after capture cleanup. A receiver
  explicitly started for files stays available. If files are pending, cleanup waits
  until the last HTTP response finishes. Capture completion restarts discovery on
  the open Screen page; detached/disposed screens do not restart it.
- Android metrics polling is replaced with a capture-scoped metrics observer.
  Opening Screen no longer eagerly allocates two native video renderers.
- File, album and app selectors reject late results after disposal or selection
  changes; media confirmation failures release the busy state. Shared-file startup
  registers a single mounted listener. Viewer Close and system Back share one
  awaited stop/restore operation.

The current suite passes **133 Flutter tests**. Native Java harnesses cover capture
caps and rotation on controlled API 24/31/34/36 variants, plus the existing
API 24/29/30/31/34/36 startup, resize, rollback, revocation and disposal cases.
Eight DEX-verifier tests pass. Java harnesses are controlled doubles, not a fleet
of physical Android devices.

The repeated production-service benchmark is recorded in
[app-review-transfer.json](performance/app-review-transfer.json). Across 20 fresh
sessions, descriptors remain **10 → 10**, sockets **0 → 0**, and RSS changes by
about 0.45 MiB. All content and cancellation/cleanup checks pass. Median aggregate
throughput is 118.2 MiB/s for one file and 163.3 MiB/s for three concurrent files.
These are Linux loopback measurements, not phone/Wi-Fi throughput or evidence of a
statistically significant speed improvement. Cancellation while awaiting a
response closes the stream in 14.6 ms; stopping an incomplete receive returns with
zero active requests or partial files (1.5 ms in this run).

### Final S22 installation and capture checks

The final release APK is `build/app/outputs/flutter-apk/bshare-optimized-release.apk`
(40,100,095 bytes, SHA256
`fc8db7527c3056b39844d48fe778dd32ea3c26a6c9ba55f22586abd3001b1113`).
It is installed as **BShare Optimizada**, package `com.bshare.bshare.audit`, using
an in-place update with the existing local signing key. Pulling the installed APK
back from Android reproduced the build hash. This is a release AOT/R8 build signed
with the existing local Android debug key; it is not a store-signed distribution.
The final DEX contains all three ML Kit public registrar constructors.

[s22-app-review.json](performance/s22-app-review.json) records the artifact/source
hashes, raw receiver statistics, geometry measurements, UI checks and cleanup
evidence. Physical checks use the S22 Ultra on Android 14 and a headless Chromium
receiver on Linux over the LAN. A foreground Android Chrome fixture animates with
`requestAnimationFrame`; a five-second inbound frame-count sample measured
**29.14 FPS** with a 1080p/30 cap and **14.76 FPS** with a 720p/15 cap. Each profile
passed four portrait/landscape samples with four reference circles and matching
X/Y layout, retaining one capture track/generation through the rotations.
WebRTC adapted below the selected resolution initially and later reached the cap;
neither profile exceeded its selected shorter-edge limit. These frame-count
samples do not measure end-to-end latency or establish sustained 60 FPS support.
Two earlier probes used a fixture updated at 10 Hz and therefore only establish
geometry and upper limits; their roughly 10 FPS results are not frame-rate tests.

Normal in-app stop left zero capture-helper threads, no active MediaProjection,
no app foreground service and a closed screen-only HTTP port. Discovery resumed
on Screen, remained visibly searching at the 5–7.7 second observation, and showed
its completed/listening state at the 13–15.4 second observation. Controlled tests
check the exact 12-second boundary. Toolbar and Android Back returned from Settings
to Screen and through Settings → Receive → Send → Screen in the recorded route
sequence. A fresh process retained 1080p/30 FPS and the existing language/name.
The app was left on Home. The fixture tabs, diagnostic browser/server/logcat,
ADB forwarding and reverse mappings were closed; device rotation settings were
restored to their original values. The final analyzer reported no issues.

## Initial debug build identification

| Artifact | Bytes | SHA256 |
| --- | ---: | --- |
| Normal debug APK: `build/app/outputs/flutter-apk/app-debug.apk` | 173,199,831 | `3798afbc6501106a3a82f222aea9cbe644b631262f1fa392cd6bc18c26149335` |
| Device-tested audit APK: `.dart_tool/bshare-audit-debug-final-v2.apk` | 112,168,867 | `bdd4c25d70c0dd86e6a1cdb8d477f2a139280519b93fdaa874e46da0accf2da8` |

The build and device operators independently verified both APK hashes. The phone
checks used a separate audit package, which was removed after testing; the
original installed app was retained. The JSON device report records APK and
source hashes along with the scope of the physical checks.

## Measurement method

- Generate three deterministic 32 MiB files and a 128 KiB session file. Warm up
  the production services with one complete small transfer.
- Measure three rounds with one file, then three rounds with three files. The
  stopwatch includes queue announcement, upload, file flush/close, receiver
  callback, HTTP response, and sender stream completion. Verify every received
  byte after stopping the stopwatch.
- Sample whole-process resident memory every 10 ms. Sender, receiver, benchmark,
  Dart JIT, and runtime share this RSS figure. A sampled peak can miss short
  spikes; it is not Flutter UI or Android memory usage.
- Create, transfer, and stop fresh service instances 20 times. On Linux, record
  `/proc/self/fd` and socket descriptors after each completed teardown.
- Cancel an upload after the receiver has consumed the entire body while it
  deliberately withholds the HTTP response. Require stream closure and a single
  `cancelled` terminal event within two seconds, before releasing that response.
- Pause an upload after its first data progress event, cancel it 50 ms later,
  and check that no partial destination file or receiver task remains.
- Stop the receiver while an incomplete HTTP body is still open. Check cleanup
  immediately when `await stop()` returns, then again 100 ms later.

These are local service measurements. Loopback and the OS filesystem cache can be
much faster than WiFi or a phone's storage. Files are flushed through Dart's
file APIs; this does not measure durable storage after a power loss. RSS can stay
allocated for Dart's heap and JIT after work finishes, so a positive RSS change
alone does not establish a leak. Stable descriptor counts provide separate
evidence for socket/file cleanup in the repeated-session workload.

## Initial baseline results from 2026-10-21

At the initial review stage the complete Flutter test suite passed 90 tests (34 seconds). The last
complete `flutter analyze --no-pub` reported no issues (4.2 seconds). A Linux
release build also completed successfully. The
tests include 21 screen-sharing service tests, seven native-renderer Dart
lifecycle tests, eight native-track lifecycle tests, and eight orientation-widget
tests. The checks below provide measurements outside the widget-test
environment.

Measured on Linux x64, Intel Core i3-1215U, six available CPUs, approximately
23.1 GiB RAM, Dart 3.12.2. Source and destination were temporary directories on
the same machine. During these HTTP measurements, `adb devices -l` reported no
Android devices. Later ADB pairing connected an S22 Ultra (SM-S908U), Android 14
/ API 34, with a 1080×2316 display override and 1440×3088 physical display.
Device capture validation is tracked separately from the HTTP measurements.

The baseline uses repository commit `b223666`, extracted into an isolated
temporary directory with its own package mapping. The corrected run imports the
working tree's production services. Raw reports are stored beside this document
in `performance/`. The final baseline and corrected measurements ran sequentially
after project builds and tests finished, with no project compilation competing
for CPU. Other desktop applications remained open. Three samples per case are
too few to establish a statistically significant throughput difference.

| Workload / check | Baseline | Corrected |
| --- | ---: | ---: |
| One 32 MiB file, median of 3, MiB/s | 132.7 | 122.5 |
| Three 32 MiB files, aggregate median of 3, MiB/s | 145.9 | 154.2 |
| Peak sampled RSS during one-file rounds, MiB | 268.2 | 276.8 |
| Peak sampled RSS during three-file rounds, MiB | 284.5 | 293.8 |
| Sender stream events, one-file median | 131 | 5 |
| Sender stream events, three-file median | 393 | 24 |
| Receiver progress callbacks, one-file median | 128 | 4 |
| Receiver progress callbacks, three-file median | 365 | 21 |
| Cancel while waiting for response | Still open after 2,003 ms | Closed, cancelled in 7.0 ms |
| Pause then cancel, stream closure | 11.3 ms | 1.1 ms |
| Active receive handlers when `stop()` returns | 1 | 0 |
| Partial files inspected immediately after `stop()` | 0 | 0 |
| File descriptors before / after 20 sessions | 10 / 10 | 10 / 10 |
| Socket descriptors before / after 20 sessions | 0 / 0 | 0 / 0 |

The corrected run passed all four lifecycle checks and reported no errors.
Baseline cancellation and immediate stop cleanup failed their checks. Every
successful throughput transfer passed full content validation. Raw reports:
[baseline](performance/baseline-b223666.json),
[corrected](performance/corrected.json).

A separate corrected run increased each payload to 128 MiB, sending 384 MiB
across three simultaneous uploads. It measured 144.3 MiB/s for the single file
and 166.4 MiB/s aggregate for three files; peak sampled RSS was 274.7 and
301.3 MiB respectively. All bytes validated and lifecycle checks passed. This
single larger run shows memory remained similar when payload size quadrupled
in this environment; it does not establish a bound under a slow disk or on
Android. [Large-payload report](performance/corrected-large.json).

```bash
dart run tool/transfer_benchmark.dart --file-mib=128 --rounds=1 --cycles=1 --json=/tmp/bshare-performance-large.json
```

The measurements do not establish a network throughput improvement. They check
for a substantial local regression and demonstrate the observed lifecycle fixes.
Receiver progress callback counts also quantify event work; those counts depend
on scheduling and chunk sizes, and do not directly measure Flutter frame time.

## Screen rotation diagnosis

The review found concrete causes in app layout and WebRTC integration:

| Layer | Observed defect | Correction |
| --- | --- | --- |
| Viewer aspect ratio | Ratios below 0.42 or above 2.45 were discarded, including valid tall/narrow content. | Accept any finite positive video ratio. |
| Viewer signaling | Metadata could describe the next orientation while the displayed decoded frame still had the old orientation, stretching that frame. | Use the decoded frame's dimensions first and metadata while frame dimensions are unavailable. |
| Desktop pixel buffer | The conversion rotates pixels, but the buffer used the original width/height at 90/270 degrees. | Swap destination dimensions for quarter turns and cache conversion until a new frame arrives. |
| Android capture resize | A size change scheduled extra resizes at 350/900/1500 ms. | Coalesce pending changes and remove repeated delayed resizes. |
| Android capture output | On the S22 Ultra, landscape framebuffer bounds could retain portrait destination content after a resize. | Replace the SurfaceTexture/BufferQueue producer on API31+ while retaining the MediaProjection and VirtualDisplay; a same-producer detach was insufficient in the device probe. |
| Android before API 31 | The resize path did not preserve WebRTC's older-Android display recreation behavior. | Recreate the virtual display on API below 31; resize on newer versions. |

The versioned WebRTC source rotates the image before scaling it to the supplied
destination dimensions, supporting the desktop-buffer correction.
[WebRTC conversion implementation](https://raw.githubusercontent.com/webrtc-sdk/libwebrtc/libwebrtc.m144.7559.09/src/rtc_video_frame_impl.cc).
Its Android capturer documents display recreation before Android 12 to avoid
incorrect scaling when resizing.
[WebRTC Android capturer](https://raw.githubusercontent.com/webrtc-sdk/webrtc/m144_release/sdk/android/api/org/webrtc/ScreenCapturerAndroid.java).

These fixes do not establish a Dart, Flutter, or codec defect. H.264 remains the
preferred codec. A codec change would need evidence from negotiation, decoder
statistics, and the real phone/computer visual test.

## Screen-sharing lifecycle coverage

The screen-sharing service suite passes 21 tests using controlled platform and
peer implementations. It includes 25 consecutive watch/stop sessions and checks
that every peer is closed and disposed. Other cases stop during initialization,
peer creation, ICE gathering, signaling, native capture, and generation-based
reconnection. A native capture that finishes after stop is released before the
pending startup completes and cannot reactivate sharing. Stop can return while
the native capture request is still pending. The viewer also handles a remote
HTTP 503 during connection.

A delayed metadata response of 1.15 seconds produces at most one outstanding
metadata request. Polling schedules its next request after completion; the
original periodic timer could overlap requests when responses were slower than
its interval. These tests exercise service behavior and ownership, with mocked
WebRTC/native resources; real frame orientation and visual latency still need
device validation.

```bash
flutter test --no-pub test/services/screen_share_service_test.dart
```

Eight native-track Dart tests exercise the OS capture-ended event bridge over
the existing global platform event channel. They check track-ID filtering, a
single `onEnded` notification, listener cancellation after callback removal or
stop/dispose, concurrent native disposal, retry after disposal failure, and a
callback that stops its own track. These platform-channel tests do not certify
the Android system revocation flow on hardware.

```bash
flutter test --no-pub test/media_stream_track_lifecycle_test.dart
```

The native rendering harness compiles the production C++ renderer with vendored
WebRTC interfaces, controlled frames, and texture-registration doubles. It
passes 0/90/180/270-degree frames, track changes, detach/resume, and reuse of the
pixel buffer. For 120 synthetic 1080p frames with four raster reads per frame,
the corrected renderer performs 120 pixel conversions, compared with 480 when
converting on every raster read: 75% fewer repeated conversions in that workload.
The controlled frame substitutes its pixel conversion implementation; this does
not measure real YUV conversion cost. The operation count does not imply a 75%
reduction in real video latency or CPU.

The Java capturer harness runs the production capturer with simulated Android
and WebRTC APIs for SDK 24, 29, 30, 31, 34, and 36. It verifies resize coalescing, removal
of redundant delayed resizes, zero retained surfaces after cleanup, and stopping
or capture revocation without a deadlock. These native regression tests do not
exercise a real Android framework, GPU, encoder, or phone display. Additional
cases check that API31+ resize changes the producer, failed helper creation or
attachment rolls back to the old producer, and concurrent stop/dispose cannot
post to a retired helper. A separate host test compiles the production track
removal and startup-guard methods unchanged with ownership doubles and checks
final source/helper release, shared-track ownership promotion, interruption,
disposal failure, failed capture startup, and a video-track factory that throws
or returns null. OS revocation also disposes the capture helper before its
event is delivered to Dart in the controlled capturer test.

The production Java capturer also compiled with `javac` against the Android 36
SDK and WebRTC 144.7559.09 classes from the real AAR, checking API compatibility
in addition to the simulated behavior checks.

```bash
bash third_party/flutter_webrtc/test/native/run_video_renderer_test.sh
python3 third_party/flutter_webrtc/test/native/test_screen_capturer.py
python3 third_party/flutter_webrtc/test/native/test_video_capturer_disposal.py
```

## Child process cleanup

The direct-network service shares concurrent hotspot starts/stops and waits for
a pending start during disposal. Finite `nmcli` commands collect exit status and
both output streams; a timeout requests termination, escalates to a forced kill
if needed, and awaits exit and pipe completion before returning. Windows hotspot
cleanup also waits for PowerShell exit and output completion after a failed
start or a stop timeout.

Dart's documentation explains that process exit can precede completion of buffered
stdout/stderr output; both streams need their own completion checks.
[Process.exitCode documentation](https://api.dart.dev/dart-io/Process/exitCode.html).

Five process/service tests pass. Real Dart child processes verify complete
stdout/stderr capture, timeout cleanup, and escalation when SIGTERM is ignored.
The Linux tests check that the child no longer exists in `/proc` before the
operation completes. Controlled service tests cover idempotent disposal and
duplicate startup requests while disposal is pending. These tests create no
hotspot and do not change network settings. Windows WiFi Direct hardware behavior
has not been exercised by these Linux subprocess tests.

```bash
flutter test --no-pub test/services/process_runner_test.dart
```

## Device discovery feedback and scanner lifecycle

Validation after the discovery and QR changes: **117 Flutter tests passed**,
`flutter analyze --no-pub` reported no issues, and the eight DEX-verifier tests
passed. The Flutter analyzer was run with `FLUTTER_SUPPRESS_ANALYTICS=true` to
avoid a tooling telemetry connection failure; no global setting was changed.

Opening Send, Devices, or Screen starts discovery automatically. Receivers
announce immediately and every three seconds; the listener remains open between
announcements. The interface shows an animated initial/manual search window of
twelve seconds (extended from four in the settings/navigation revision), then reports the number of currently discovered devices without
an indefinite spinner. Reduced-motion settings use a static progress indicator.

Concurrent refresh requests share one operation and retain valid devices and
the existing socket. A one-second timer removes devices after twenty seconds
without announcements, including when no other packets arrive. A remembered
selected destination remains usable for direct QR connections but is labelled
as not currently detected and is excluded from the available count. An updated
announcement for the same device ID refreshes its selected IP/port before a new
transfer; an already running transfer retains its original immutable endpoint.

The listening socket is shared across screens. Home no longer starts a second
scan before navigation, and opening a sending screen preserves active receiver
advertisements. Refresh rechecks the network address; after changing Wi-Fi,
tap Refresh. Search/expiry timers and pending refresh completions are released
on stop/disposal. Bind/address failures show recovery guidance.

The scanner serializes camera operations and releases its controller on exit.
Failed startup is retried with a new controller, while duplicate detections
share the current connection attempt. Returning from camera permissions/settings
or app suspension restarts only the current camera session. Leaving a connection
attempt cancels its HTTP probe and retry timer. Invalid invitations keep the
camera running; a valid BShare code can be selected from a frame containing
several codes.

A regression test exposed retained native event listeners after failed startup
with `mobile_scanner` 7.2.0. The dependency is updated to 7.4.2, and that same
failure/retry/dispose test now passes. Invitation parsing and camera/network
lifecycle tests use controlled platform doubles; they do not establish real
hotspot connection compatibility on every Android device.

```bash
flutter test --no-pub test/discovery_controller_test.dart test/discovery_status_card_test.dart test/direct_qr_scanner_screen_test.dart test/direct_share_invite_test.dart
```

## Android QR scanner release diagnosis

The S22 Ultra's original installed release reproduces the reported scanner
startup error:

```text
Attempt to invoke virtual method 'c6.d c6.c.a(y5.b)' on a null object reference
```

Reading only that app process's logcat reveals an earlier initialization failure:
`Invalid component registrar`, followed by `NoSuchMethodException` for the
no-argument constructors of these classes:

- `com.google.mlkit.common.internal.CommonComponentRegistrar`
- `com.google.mlkit.vision.barcode.internal.BarcodeRegistrar`
- `com.google.mlkit.vision.common.internal.VisionCommonRegistrar`

A copy of the installed APK was inspected without replacing or stopping the
original app. All three classes remain in its DEX, but none declares the public
no-argument constructor required for reflective creation. An independent Android
SDK `apkanalyzer dex code` inspection also confirms the missing constructor on
`CommonComponentRegistrar`. The existing debug APK retains all three
constructors. A check for class-name strings alone would miss this defect.

This identifies release optimization removing reflectively used constructors.
The `mobile_scanner` 7.2.0 consumer rule only covered `com.google.mlkit.*`, which
excludes the nested packages containing the registrars. The plugin's upstream
R8 full-mode fix widens that rule to `com.google.mlkit.**`; a subsequent fix also
preserves the internal barcode classes. The app's release configuration now
includes those rules while retaining R8 optimization.
[Upstream R8 fix](https://github.com/juliansteenbakker/mobile_scanner/pull/1726),
[upstream barcode rule fix](https://github.com/juliansteenbakker/mobile_scanner/commit/5825d7a).

ML Kit was already integrated through `mobile_scanner`; installing another ML Kit
Flutter package is not required for this scanner. Android uses CameraX and ML
Kit, while the plugin uses Apple Vision on Apple platforms and ZXing on the web.
[Plugin documentation](https://pub.dev/packages/mobile_scanner).
The Android dependency uses ML Kit's bundled barcode model, available immediately
without waiting for a first-use model download.
[Google's bundled and unbundled model comparison](https://developers.google.com/ml-kit/vision/barcode-scanning/android).

After a normal minified release build, run:

```bash
python3 tool/verify_android_qr_release.py build/app/outputs/flutter-apk/app-release.apk
```

For split APK builds, pass the actual artifact path instead, for example
`build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`. The helper reads every
root `classes*.dex` file and verifies that each registrar declares a public
no-argument constructor with a code item. It exits 0 only if all three checks
pass, 1 if a class or constructor is missing, and 2 for an invalid or unreadable
APK. It requires Python 3 and its standard library, without Android SDK tools.

Eight synthetic DEX-reader regression tests pass. They cover retained
constructors across multiple DEX files, absent declarations despite retained
class/method-name strings, a missing class, private and argument-taking
constructors, malformed DEX, absent DEX, and duplicate definitions:

```bash
python3 tool/test_verify_android_qr_release.py
```

| Artifact inspected | Registrar classes present | Public no-argument constructors retained | Static check |
| --- | ---: | ---: | --- |
| Original installed S22 release | 3/3 | 0/3 | Failed, matching device startup logs |
| Existing debug APK | 3/3 | 3/3 | Passed |
| Final audit release, R8 enabled | 3/3 | 3/3 | Passed; camera initialized on S22 |
| Final normal release, R8 enabled | 3/3 | 3/3 | Passed; signature verified |

The final minified audit APK was installed separately as
`com.bshare.bshare.audit` on the S22 Ultra (Android 14). CameraX opened the rear
camera and ML Kit loaded `libbarhopper_v3.so` and initialized its decoder without
registrar or null-reference errors. Three background/recents/resume cycles and
three scanner dispose/recreate cycles all passed. Android's camera service showed
no active clients after exit and after cleanup. Polling observed camera release
within 2.6 seconds; these timings include Android transitions and adb/dumpsys
calls and are not scanner frame-processing benchmarks.

Real LAN multicast announcements from a temporary Linux receiver were detected
after the initial search window, and manual refresh retained the visible peer.
After announcements stopped, the peer disappeared from the available count while
the selected destination remained labelled as not currently detected.

The user could not aim the phone at the displayed QR fixture. Physical QR
recognition and real hotspot connection remain unverified; controlled-platform
tests cover invitation parsing, invalid/multiple/duplicate detections, connection
cancellation, permissions, and camera failure/retry. The static verifier always
reports `cameraRuntimeVerified: false` because it inspects DEX only; the separate
runtime evidence is recorded in
[s22-discovery-qr.json](performance/s22-discovery-qr.json).

The temporary audit package, multicast sender, logcat process, and phone-side
fixture file were removed/stopped. The original installed app remained running
with the same PID, and its package/data and rotation settings were preserved.

The normal release APK is
`build/app/outputs/flutter-apk/app-release.apk` (ARM64 and x86_64, Android API 24+),
SHA-256 `c8c5f7e37fe738d113ac38208f066b629da27a46f9d83c7c102eaaaf53158cfe`.
It passed the DEX constructor check and Android APK signature verification.
No release keystore is configured locally, so this artifact uses the project's
existing debug-signing fallback. Updating an installed app signed with another
key requires rebuilding with its original release key; the original phone app
was not replaced. The audit APK uses a separate application ID and a different
ABI set, so APK sizes are not a meaningful performance comparison.

## S22 Ultra and Linux device checks

Real-device evidence is recorded in
[s22-rotation.json](performance/s22-rotation.json), including source-image hashes.
The initial S22 Ultra portrait sample passes four circle shapes and reference layout
(maximum relative shape deviation 2.59%, X/Y scale mismatch 0.41%). The initial
landscape audit sample was visibly deformed and clipped and failed the
measurement; only two partial circles were detected. Diagnostic RGBA and safely
retained Y-plane dumps are already deformed before Flutter GL and pixel
conversion respectively.

The Android SurfaceFlinger dump locates the mismatch: the virtual display's
framebuffer **bounds** are 2316×1080, while its destination **content** remains
1080×2316, producing X/Y scales of 0.4663 and 2.1444. Restarting only the WebRTC
peer preserves the fault. Stopping capture and starting a new capture while the
phone is already landscape produces matching landscape bounds/content, an
identity transform, and a four-circle shape/layout pass. This identifies the
Android virtual-display output projection as the source of this persistent
deformation. It does not establish a general codec defect. Validation of the
new-producer resize fix is covered by the final APK probe and repeated capture
sessions below.

An experimental detach/resize/reattach using the same `SurfaceTexture` producer
was tested and rejected: all three recorded portrait samples passed, while
all three landscape samples failed with only two partial circles detected. The
12-sample run was stopped after these six samples demonstrated the repeated
failure; cleanup ran in `finally`. A later SurfaceFlinger dump represents the
restored portrait state and is not used as evidence of the failed landscape
projection. A separate later dump in landscape, with BShare foreground instead
of the Chrome fixture, has matching bounds/content and an identity transform;
it does not establish the display state during the earlier failed screenshots.
The probe waits two seconds after observing orientation metadata before taking
concurrent phone/viewer screenshots. Metadata polling timings are not video
latency.

The final Android V2 APK passes all 12 recorded samples: six portrait and three
landscape in each direction, spanning 11 orientation changes without restarting
capture (the same track and generation 21 throughout). Two earlier new-producer
probes also pass all 12 samples each.
Every sample contains four detected circles and passes shape/layout checks.
Maximum proportional shape deviation is 1.60%, and maximum X/Y center-spacing
scale mismatch is 0.36% (4% tolerance). A landscape SurfaceFlinger dump taken
with the Chrome fixture foreground has matching 2316×1080 bounds/content and
an identity transform. The operator also observed the displayed clock advance
between two recorded samples; this does not measure continuous frame rate or
end-to-end latency. The report identifies the tested APK by SHA256 and records
source hashes. The preceding final Linux probe also retains exactly identical
GTK header, Watching status, and close-button pixels in all 12 saved screenshots (36 region
comparisons, zero differing pixels). This does not attribute a rendering fix
to the texture filter setting.

A separate initial cleanup check found two surviving `main_texture_sc` threads
after two complete capture starts/stops, although Android reported no active
MediaProjection or capture service. After the correction, the phone has one
capture helper after the 11 orientation changes and zero after capture stops;
the before/after thread dumps and hashes are recorded. Android also reported
no active MediaProjection or capture service after this stop. General app,
WebRTC, and codec threads remain and are not counted as capture helpers. The
final Android V2 then passed 20 complete capture start/stop cycles in the same
phone process (PID25208), with one capture helper during every active session
and zero after every stop. All 20 raw post-stop dumps show MediaProjection
`null` and no foreground service; each session uses a different track ID and
generations advance from 1 to 20. These cycles exercise source-phone capture
teardown; controlled service tests separately cover viewer/peer teardown.
Harness cycle durations are not native stop latency. Actual OS revocation was
not tested: the shell command lacked permission, and stopping the app service
did not revoke MediaProjection. Normal in-app stop closed the session. OS revocation
therefore has controlled native/Dart test coverage only.

The final phone log contains two Flutter engine frame-time clamping messages
(16.692 ms and 8.333 ms). The recorded geometry and lifecycle checks pass, and
no unhandled Dart exception, permission message, or capture resize failure was
found by the recorded log searches. The effect of the timing messages on
continuous frame pacing was not measured.

After the checks, the temporary viewer, fixture server, logcat collections, and
owned build/harness processes were stopped. The audit package and ADB reverse
mappings were removed, the two fixture tabs were closed, and the original
rotation settings were restored. Final phone assertions confirm no active
MediaProjection and that the original app remains installed. Artifacts and logs
are retained under the ignored `.dart_tool/phone_rotation/` directory; the JSON
report preserves measurements and source hashes for review.

Screen capture, MediaProjection, hardware encoding, WebRTC decoding, and GPU
presentation require real devices. The local HTTP benchmark does not measure
screen sharing latency, dropped video frames, rotation correctness, battery
use, or codec compatibility.

`tool/screen_share_fixture.html` provides a standalone grid, four colored
circles, a moving marker, viewport dimensions, and a millisecond clock. Display
it on the phone and capture the computer viewer. The circles should remain round
through rotation. The fixture makes no external network requests.

The PNG helper requires Pillow and reports each detected circle's width, height,
and proportional stretch. It exits successfully when at least three circles
are found and all detected circles stay within 4% of the expected ratio. The
optional phone reference normalizes each color's measured ratio and compares
horizontal/vertical circle-center spacing. Uniform scaling should produce the
same X/Y scale; this comparison rejects an old portrait layout against a new
landscape reference even when all circles remain round. `referenceLayout`
reports that separate result. Matching layouts cannot prove temporal freshness
when content has not changed. Missing circles or a failed color segmentation
cannot establish that a frame is correct.

```bash
python3 tool/analyze_screen_geometry.py computer-viewer.png
python3 tool/analyze_screen_geometry.py computer-viewer.png --reference phone.png
```

Five synthetic regression tests pass, including rejection of an old portrait
frame with round circles against a new landscape reference. Other cases verify
uniform scaling, a current landscape layout, stretching, and a missing fixture.
This validates the measurement helper; only actual device screenshots can
establish a device result.

```bash
python3 tool/test_screen_geometry.py
```

Use the same build and LAN on both devices, record phone/OS and computer/OS/GPU,
and run the following sequence with a profile build. Keep a release build for
the final visual comparison; debug mode adds timing overhead.

1. Share a screen containing a clock or continuously moving content. Record the
   negotiated codec and video dimensions from WebRTC stats, rather than assuming
   that the preferred codec was selected. Observe 60 seconds without rotation.
2. Rotate portrait to landscape and back 50 times, including rapid rotations.
   Record time to the first correctly oriented frame, freezes, black frames,
   distortion, crop, and whether an old frame is stretched while dimensions
   change. Repeat with both landscape directions and a portrait-locked app.
3. Record inbound `framesReceived`, `framesDecoded`, `framesDropped`, decoded
   width/height, and packet loss; use deltas between stats samples for rates.
   Compare these with Flutter UI/raster frame times in DevTools. Codec/decoder
   stalls and Flutter layout stalls need separate evidence.
4. Start and stop viewing and sharing 20 times. Try cancelling while connecting,
   leaving the viewer during negotiation, and stopping while rotating. Check
   that camera/screen-capture indicators and the Android foreground notification
   stop, and that the next session connects exactly once.
5. With the app idle, record process memory and open sockets; compare after the
   repeated sessions and a short settling interval. Transfer three large files
   while viewing to expose network, CPU, and event contention. Repeat with
   WiFi interrupted, resumed, and background/foreground transitions.

Keep the two video recordings, profile traces, codec/stats samples, and device
details with the result. The current report covers the recorded S22 Ultra
samples; completion of this longer sequence is required before claiming its
full rotation, latency, and repeated-session coverage.
