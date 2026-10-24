# Changelog

## Unreleased

- Fix LAN discovery across Wi-Fi/Ethernet adapters and Android multicast filtering; refresh now queries peers directly and stopped receivers withdraw their announcements.
- Use exclusive HTTP listeners and show the actual destination and actionable connection errors instead of raw socket messages.
- Add an optional Windows installer task for private LAN firewall access, scoped to BShare and the local subnet, with cleanup on uninstall.
- Preserve real Android H.264 capabilities, prefer constrained baseline and recover once with bounded VP8 video when no frames arrive.
- Apply encoder limits after negotiation, close replaced/abandoned peers, and stop the remote sender explicitly when closing a viewer.
- Fix Android encoder worker/buffer cleanup and desktop capture startup failure reporting.
- Add native H.264/VP8 streaming, failed-startup recovery, Android codec lifecycle and Windows firewall regression checks. Hardware coverage is recorded separately in `docs/STREAMING_COMPATIBILITY.md`.

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
