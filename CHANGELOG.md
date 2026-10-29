# Changelog

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
