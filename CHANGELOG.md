# Changelog

## 1.0.5

- Await application resource cleanup when closing a Linux window, including with the fullscreen/window-management plugin installed. Require native streaming verification as well as all installer checks before publishing a release.
- Add direct Android USB debugging transport for camera, screen, audio and camera controls, without USB tethering or manual IP entry. Select an authorized physical USB device on the computer; session-owned ADB mappings and authenticated relay connections carry signaling/media without a Wi-Fi/LAN fallback. Desktop installers include a pinned ADB client.
- Add a right-hand desktop camera menu with Switch camera first, public lens selection, native zoom, white balance, EV brightness compensation and supported manual shutter/ISO controls. Use the phone's ranges and confirmed settings, synchronize microphone/flash controls, and keep Close viewer separate from Stop sharing on the phone.
- Apply native zoom and supported relative cool/warm white balance while dragging, retaining only the latest pending value and rejecting drafts from an old camera/session. Auto restores automatic white balance; unsupported devices retain their advertised presets. No receiver-side image filter or zoom simulates these controls.
- Add a local Mirror switch and label the desktop Home camera action as viewing the device camera. Remove the virtual-camera status block from the control menu.
- Add a separate left camera actions panel: Preview first, Take photo above the photo destination, and Record/Stop video above the video destination. Save received frames as JPEG and H.264/AAC MP4 only on Windows/Linux computers, using separate persistent OS Pictures/Videos folders. Preview drawing can stop while recording and virtual camera output continue; disconnect/source changes finalize recordings.
- Show a compact Saved footer with a larger heading, animated appearance/disappearance and a ten-second lifetime per new file. Flash the enabled local preview briefly after a successful photo, without changing saved files or virtual camera output. Both effects respect reduced motion.
- Add the persistent Windows 11 x64 system virtual camera and a Linux v4l2loopback producer, each with clean received camera/screen video and a waiting image when disconnected. Install the supported Windows component automatically and add Linux driver/service setup. Linux still requires matching kernel headers and normal module-signing approval.
- Remove the separate OBS plugin; use the system video capture device in OBS. The virtual camera carries video only, with received phone audio available through the computer's playback output.
- Add native desktop screen fullscreen, including entry from maximized Windows, hide controls/cursor after three seconds of inactivity, restore controls on movement, and leave fullscreen with Esc while preserving the stream and original window state.
- Include Android device playback audio in screen sharing on Android 10+, with an opt-out and video-only fallback when permission/capture is unavailable. Keep the hardware microphone disabled in this mode and release audio capture with the screen session.
- Start phone camera broadcasts with their preview hidden and show plain LAN address/port text beneath the sharing message only in that state. Screen sharing retains its LAN address copy action; USB shows the phone's BShare port rather than a LAN address.
- Skip drawing hidden Android screen previews while retaining capture dimensions/rotation events. Route Windows WebRTC playback through the multimedia output, respecting device/output choices, and hide the firewall helper console while retaining normal UAC authorization.

## 1.0.4

- Select active LAN interfaces from OS hardware, bridge, prefix and route metadata; support Ethernet without Wi-Fi, including Windows external switches and Android Ethernet, while excluding internal virtual networks and VPNs.
- Bind transfer-control route checks to eligible source addresses for each receiver; discover peers over every eligible LAN and retain stable multi-interface destinations.
- Verify bidirectional 8 MiB transfers with matching SHA-256, screen sharing in both directions and front/rear phone camera reception between an Android 14 S22 Ultra over Wi-Fi and Windows over Ethernet.
- Publish native macOS ARM64/Intel PKG installers that install BShare.app into /Applications and validate the installed payload on native CI runners.
- Name releases after their version tags, rebuild existing versions through a separate staging draft, and add the Ko-fi sponsorship link to the repository.
- Fix LAN discovery across Wi-Fi/Ethernet adapters and Android multicast filtering; refresh now queries peers directly and stopped receivers withdraw their announcements.
- Refresh Home's network address after returning from the background, including DHCP changes, without duplicating refreshes for permission dialogs or app shutdown.
- Use exclusive HTTP listeners and show the actual destination and actionable connection errors instead of raw socket messages.
- Add an optional Windows installer task for private LAN firewall access, scoped to BShare and the local subnet, with cleanup on uninstall.
- Preserve real Android H.264 capabilities, prefer constrained baseline and recover once with bounded VP8 video when no frames arrive.
- Apply encoder limits after negotiation, close replaced/abandoned peers, and stop the remote sender explicitly when closing a viewer.
- Refresh an unchanged Android screen at most once per second so a later viewer can receive its first frame without touching the phone; cancel idle refreshes when capture stops or rotates.
- Fix Android encoder worker/buffer cleanup and desktop capture startup failure reporting.
- Add native H.264/VP8 streaming, failed-startup recovery, Android codec lifecycle and Windows firewall regression checks. Hardware coverage is recorded separately in `docs/STREAMING_COMPATIBILITY.md`.
- Record physical Android 14 tests for Honor/MagicOS 8 and S22 screen sharing in both directions, rotation, Linux camera discovery, VP8 reception, camera controls, audio transport and normal cleanup; keep the interrupted DHCP trial separate from completed results.

## 1.0.3

- Use GTK and the Linux desktop environment's standard window title bar and controls.
- Add GitHub Actions installers for Windows, Debian/Ubuntu, Fedora, Android and macOS.
- Publish separate ARM32/ARM64 APKs, Windows EXE, Linux DEB/RPM and macOS ARM64/x64 DMG release assets.
- Add a default Start Menu shortcut and an optional desktop shortcut to the Windows installer.
- Sign separate ARM32 and ARM64 Android APKs with the permanent BShare release key.
- Fix Windows WebRTC messenger and task runner cleanup during app shutdown.
- Improve camera and screen sharing, device discovery, QR scanning and responsive navigation.
- Publish BShare application code under the MIT License; preserve third-party notices.

## 1.0.2

- Separate Transfers from Receive and open Transfers for incoming files.
- Keep Android transfers running in the background.
- Save Android downloads in `Download` and order media chronologically.
- Improve screen sharing, full-screen viewing and desktop navigation.
