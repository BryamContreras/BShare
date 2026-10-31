import 'dart:async';
import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/camera_connection_mode.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:bshare/src/infrastructure/services/usb_adb_transport_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/localization/video_connection_localizations.dart';
import 'package:bshare/src/presentation/localization/camera_localizations.dart';
import 'package:bshare/src/presentation/localization/camera_ui_localizations.dart';
import 'package:bshare/src/presentation/localization/screen_audio_localizations.dart';
import 'package:bshare/src/presentation/localization/usb_connection_localizations.dart';
import 'package:bshare/src/presentation/screens/screen_viewer_screen.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:bshare/src/presentation/widgets/broadcast_address_card.dart';
import 'package:bshare/src/presentation/widgets/discovery_status_card.dart';
import 'package:bshare/src/presentation/widgets/gradient_action_button.dart';
import 'package:bshare/src/presentation/widgets/orientation_aware_video_view.dart';
import 'package:bshare/src/presentation/widgets/usb_device_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:go_router/go_router.dart';

class ScreenShareScreen extends ConsumerStatefulWidget {
  const ScreenShareScreen({super.key});

  @override
  ConsumerState<ScreenShareScreen> createState() => _ScreenShareScreenState();
}

class _ScreenShareScreenState extends ConsumerState<ScreenShareScreen> {
  final _scrollController = ScrollController();
  final _usbPortController = TextEditingController(text: '53317');
  CameraConnectionMode _connection = CameraConnectionMode.wifi;
  String? _selectedDeviceId;
  String? _selectedUsbSerial;
  DeviceInfo? _viewerDevice;
  bool _startingShare = false;
  bool _watchBusy = false;
  bool _includeSystemAudio = true;
  late final ScreenShareService _service;

  @override
  void initState() {
    super.initState();
    _service = ref.read(screenShareServiceProvider);
    if (_service.usbOnly) _connection = CameraConnectionMode.usb;
    _service.state.addListener(_resumeDiscoveryWhenIdle);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_connection == CameraConnectionMode.wifi) {
        unawaited(ref.read(discoveryProvider.notifier).start());
      }
    });
  }

  @override
  void dispose() {
    _service.state.removeListener(_resumeDiscoveryWhenIdle);
    _scrollController.dispose();
    _usbPortController.dispose();
    super.dispose();
  }

  void _resumeDiscoveryWhenIdle() {
    if (!mounted ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.detached ||
        _connection == CameraConnectionMode.usb ||
        _service.state.value.mode != ScreenShareMode.idle ||
        ref.read(discoveryStatusProvider).phase != DiscoveryPhase.idle) {
      return;
    }
    unawaited(ref.read(discoveryProvider.notifier).start());
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(screenShareServiceProvider);
    final devices = ref.watch(discoveryProvider);
    final discovery = ref.watch(discoveryStatusProvider);
    final selected = devices
        .where((device) => device.id == _selectedDeviceId)
        .firstOrNull;
    final l10n = context.l10n;
    final configuredCapture = ref.watch(settingsProvider).value?.screenCapture;
    final android = ref.watch(androidPlatformInfoProvider).isAndroid;
    final platform = Theme.of(context).platform;
    final mobile =
        platform == TargetPlatform.android || platform == TargetPlatform.iOS;
    final usb = _connection == CameraConnectionMode.usb;
    final usbDevices = !mobile && usb
        ? ref.watch(usbAdbDevicesProvider).asData?.value
        : null;
    final selectedUsb = usbDevices
        ?.where(
          (device) =>
              device.serial == _selectedUsbSerial &&
              device.state == UsbAdbDeviceState.authorized,
        )
        .firstOrNull;
    final busy = _startingShare || _watchBusy;

    return ValueListenableBuilder<bool>(
      valueListenable: service.focusedViewerActive,
      builder: (context, viewerActive, _) {
        if (viewerActive) {
          return FocusedScreenViewer(
            device: _viewerDevice,
            onClose: () => _closeFocusedViewer(service),
          );
        }
        return ValueListenableBuilder<ScreenShareState>(
          valueListenable: service.state,
          builder: (context, state, _) {
            final cameraActive =
                service.source == VideoShareSource.camera &&
                state.mode != ScreenShareMode.idle;
            return AppShell(
              title: l10n.t('screen'),
              scrollController: _scrollController,
              child: LayoutBuilder(
                builder: (context, outer) {
                  final compact = outer.maxWidth < 560;
                  return ListView(
                    controller: _scrollController,
                    padding: EdgeInsets.all(
                      Platform.isAndroid
                          ? 8
                          : compact
                          ? 12
                          : 16,
                    ),
                    children: [
                      SegmentedButton<CameraConnectionMode>(
                        key: const ValueKey('screen-connection'),
                        segments: [
                          ButtonSegment(
                            value: CameraConnectionMode.wifi,
                            icon: const Icon(Icons.wifi_rounded),
                            label: Text(l10n.cameraUiText('wifi')),
                          ),
                          ButtonSegment(
                            value: CameraConnectionMode.usb,
                            enabled: platform != TargetPlatform.iOS,
                            icon: const Icon(Icons.usb_rounded),
                            label: Text(l10n.cameraUiText('usb')),
                          ),
                        ],
                        selected: {_connection},
                        onSelectionChanged:
                            state.mode != ScreenShareMode.idle || busy
                            ? null
                            : (selection) {
                                setState(() => _connection = selection.single);
                                if (_connection == CameraConnectionMode.usb) {
                                  if (!mobile) {
                                    ref.invalidate(usbAdbDevicesProvider);
                                  }
                                } else {
                                  unawaited(
                                    ref
                                        .read(discoveryProvider.notifier)
                                        .start(),
                                  );
                                }
                              },
                      ),
                      if (platform == TargetPlatform.iOS)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(l10n.usbConnectionText('androidOnly')),
                        ),
                      if (usb) ...[
                        const SizedBox(height: 12),
                        Text(
                          l10n.usbConnectionText(
                            mobile ? 'phoneHelp' : 'computerHelp',
                          ),
                        ),
                        if (mobile)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              '${l10n.cameraUiText('port')}: ${ref.watch(receiveControllerProvider).value?.port ?? ref.watch(settingsProvider).value?.preferredPort ?? 53317}',
                              key: const ValueKey('screen-usb-listening-port'),
                            ),
                          ),
                        const SizedBox(height: 14),
                      ],
                      if (configuredCapture != null && !cameraActive)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () => context.go('/settings'),
                            icon: const Icon(Icons.tune_rounded, size: 18),
                            label: Text(() {
                              final options =
                                  state.mode == ScreenShareMode.sharing
                                  ? service.captureSettings
                                  : configuredCapture;
                              final resolution = options.resolution == 0
                                  ? l10n.t('screenNativeResolution')
                                  : '${options.resolution}p';
                              return '$resolution · ${options.frameRate} FPS';
                            }()),
                          ),
                        ),
                      const SizedBox(height: 14),
                      if (!cameraActive &&
                          state.mode == ScreenShareMode.idle &&
                          android) ...[
                        Card(
                          child: SwitchListTile.adaptive(
                            key: const ValueKey('screen-system-audio-toggle'),
                            value: _includeSystemAudio,
                            onChanged: busy
                                ? null
                                : (value) => setState(
                                    () => _includeSystemAudio = value,
                                  ),
                            title: Text(l10n.screenAudioText('include')),
                            subtitle: Text(l10n.screenAudioText('help')),
                            secondary: const Icon(Icons.volume_up_rounded),
                          ),
                        ),
                        const SizedBox(height: 14),
                      ],
                      Card(
                        child: ListTile(
                          leading: Icon(
                            state.mode == ScreenShareMode.idle
                                ? Icons.tv_off_rounded
                                : Icons.connected_tv_rounded,
                          ),
                          title: Text(
                            cameraActive
                                ? l10n.cameraUiText('cameraBusy')
                                : l10n.screenStatus(state.status),
                          ),
                          subtitle: state.error == null
                              ? null
                              : Text(l10n.videoConnectionError(state)),
                        ),
                      ),
                      const SizedBox(height: 14),
                      if (!cameraActive &&
                          state.mode == ScreenShareMode.sharing) ...[
                        if (!usb) const BroadcastAddressCard(),
                        const SizedBox(height: 14),
                        if (android) ...[
                          _ScreenAudioStatusCard(
                            status: service.screenSystemAudioStatus,
                          ),
                          const SizedBox(height: 14),
                        ],
                      ],
                      if (cameraActive)
                        Card(
                          child: ListTile(
                            leading: const Icon(Icons.videocam_rounded),
                            title: Text(l10n.cameraText('deviceCamera')),
                            trailing: IconButton(
                              onPressed: () => context.go('/camera'),
                              tooltip: l10n.cameraText('deviceCamera'),
                              icon: const Icon(Icons.arrow_forward_rounded),
                            ),
                          ),
                        )
                      else if (state.mode == ScreenShareMode.sharing &&
                          (Platform.isAndroid || Platform.isIOS))
                        _SharingMobileCard(onStop: () => _stop(service))
                      else if (state.mode == ScreenShareMode.sharing)
                        _VideoPanel(
                          title: l10n.t('yourScreen'),
                          renderer: service.localRenderer,
                          trailing: _StopButton(
                            onPressed: () => _stop(service),
                          ),
                        )
                      else if (state.mode == ScreenShareMode.watching)
                        ValueListenableBuilder<double?>(
                          valueListenable: service.remoteAspectRatio,
                          builder: (context, aspectRatio, _) {
                            return _VideoPanel(
                              title: l10n.t('remoteScreen'),
                              renderer: service.remoteRenderer,
                              preferredAspectRatio: aspectRatio,
                              trailing: Wrap(
                                spacing: 8,
                                children: [
                                  IconButton.filledTonal(
                                    tooltip:
                                        Platform.isWindows ||
                                            Platform.isLinux ||
                                            Platform.isMacOS
                                        ? l10n.t('openFocusedViewer')
                                        : l10n.t('openFullscreen'),
                                    onPressed: () => _openViewer(service),
                                    icon: Icon(
                                      Platform.isWindows ||
                                              Platform.isLinux ||
                                              Platform.isMacOS
                                          ? Icons.open_in_new_rounded
                                          : Icons.fullscreen_rounded,
                                    ),
                                  ),
                                  _StopButton(onPressed: () => _stop(service)),
                                ],
                              ),
                            );
                          },
                        )
                      else if (usb && !mobile) ...[
                        UsbDevicePicker(
                          selectedSerial: _selectedUsbSerial,
                          enabled: !busy,
                          onSelected: (device) => setState(
                            () => _selectedUsbSerial = device.serial,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const ValueKey('screen-usb-port'),
                          controller: _usbPortController,
                          enabled: !busy,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: l10n.usbConnectionText('port'),
                            helperText: l10n.usbConnectionText('portHelp'),
                          ),
                        ),
                      ] else if (!usb) ...[
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                l10n.t('availableDevices'),
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                            ),
                            GradientIconButton(
                              tooltip: l10n.t('refreshDevices'),
                              onPressed: discovery.isSearching
                                  ? null
                                  : () => ref
                                        .read(discoveryProvider.notifier)
                                        .refresh(),
                              icon: Icons.refresh_rounded,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        DiscoveryStatusCard(deviceCount: devices.length),
                        for (final device in devices)
                          Card(
                            child: ListTile(
                              leading: const CircleAvatar(
                                child: Icon(Icons.devices_rounded),
                              ),
                              title: Text(device.name),
                              subtitle: Text(
                                '${device.platform} - ${device.ip}:${device.port}',
                              ),
                              trailing: Icon(
                                _selectedDeviceId == device.id
                                    ? Icons.check_circle_rounded
                                    : Icons.circle_outlined,
                                color: _selectedDeviceId == device.id
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                              onTap: busy
                                  ? null
                                  : () => setState(
                                      () => _selectedDeviceId = device.id,
                                    ),
                            ),
                          ),
                      ],
                      const SizedBox(height: 20),
                      if (_watchBusy && usb) ...[
                        const LinearProgressIndicator(),
                        const SizedBox(height: 8),
                        Text(l10n.usbConnectionText('connecting')),
                        const SizedBox(height: 12),
                      ],
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final shareButton = FilledButton.icon(
                            onPressed:
                                !busy && state.mode == ScreenShareMode.idle
                                ? () => _startSharing(service)
                                : null,
                            icon: const Icon(Icons.screen_share_rounded),
                            label: Text(l10n.t('shareScreen')),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 52),
                              shape: const StadiumBorder(),
                            ),
                          );
                          final watchButton = OutlinedButton.icon(
                            onPressed:
                                (usb
                                        ? selectedUsb == null
                                        : selected == null) ||
                                    busy ||
                                    state.mode != ScreenShareMode.idle
                                ? null
                                : () => _watch(service, selected, selectedUsb),
                            icon: const Icon(Icons.visibility_rounded),
                            label: Text(l10n.t('watch')),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 52),
                              shape: const StadiumBorder(),
                            ),
                          );
                          if (usb) return mobile ? shareButton : watchButton;
                          if (constraints.maxWidth < 420) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                shareButton,
                                const SizedBox(height: 10),
                                watchButton,
                              ],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(child: shareButton),
                              const SizedBox(width: 12),
                              Expanded(child: watchButton),
                            ],
                          );
                        },
                      ),
                    ],
                  );
                },
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _startSharing(ScreenShareService service) async {
    if (_startingShare || _watchBusy) return;
    final usb = _connection == CameraConnectionMode.usb;
    setState(() => _startingShare = true);
    final receiver = ref.read(receiveControllerProvider.notifier);
    final server = ref.read(fileServerProvider);
    try {
      final settings = await ref.read(settingsProvider.future);
      if (!mounted) return;
      if (usb) {
        await receiver.startForVideoShare(
          ipOverride: '127.0.0.1',
          advertise: false,
        );
      } else {
        await receiver.startForScreenShare();
      }
      if (!mounted) {
        await receiver.stopIfScreenShareOnly();
        return;
      }
      final receive = ref.read(receiveControllerProvider).value;
      if (receive?.visible != true) {
        throw StateError(receive?.error ?? 'Receiver unavailable');
      }
      await service.startSharing(
        server,
        settings: settings.screenCapture,
        includeSystemAudio:
            _includeSystemAudio &&
            ref.read(androidPlatformInfoProvider).isAndroid,
        usbOnly: usb,
      );
      if (!mounted) {
        await service.stop(server);
        await receiver.stopIfScreenShareOnly();
      }
    } catch (error) {
      await receiver.stopIfScreenShareOnly();
      if (mounted) {
        ref.read(loggerProvider).warn('Screen capture could not start: $error');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.t('screenStartFailed'))),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _startingShare = false);
        _resumeDiscoveryWhenIdle();
      }
    }
  }

  Future<void> _watch(
    ScreenShareService service,
    DeviceInfo? device,
    UsbAdbDevice? usbDevice,
  ) async {
    if (_watchBusy || _startingShare) return;
    final usb = _connection == CameraConnectionMode.usb;
    final port = int.tryParse(_usbPortController.text.trim());
    if (usb &&
        (usbDevice == null || port == null || port < 1 || port > 65535)) {
      _showUsbMessage('invalidPort');
      return;
    }
    setState(() => _watchBusy = true);
    try {
      if (usb) {
        await service.watchUsb(
          usbDevice!,
          source: VideoShareSource.screen,
          remotePort: port!,
        );
        if (!mounted) {
          await service.stopWatching();
          return;
        }
      }
      if (!mounted) return;
      setState(() => _viewerDevice = usb ? null : device);
      service.setFocusedViewerActive(true);
    } catch (error) {
      if (mounted) {
        ref.read(loggerProvider).warn('USB screen connection failed: $error');
        _showUsbMessage('watchFailed');
      }
    } finally {
      if (mounted) setState(() => _watchBusy = false);
    }
  }

  void _showUsbMessage(String key) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(context.l10n.usbConnectionText(key))),
      );
  }

  Future<void> _closeFocusedViewer(ScreenShareService service) async {
    if (!mounted) return;
    setState(() => _viewerDevice = null);
    service.setFocusedViewerActive(false);
  }

  Future<void> _stop(ScreenShareService service) async {
    await service.stop(ref.read(fileServerProvider));
  }

  void _openViewer(ScreenShareService service) {
    service.setFocusedViewerActive(true);
  }
}

class _ScreenAudioStatusCard extends StatelessWidget {
  const _ScreenAudioStatusCard({required this.status});

  final ScreenSystemAudioStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final active = status == ScreenSystemAudioStatus.active;
    final failed = status != ScreenSystemAudioStatus.off && !active;
    return Card(
      child: ListTile(
        leading: Icon(
          active ? Icons.volume_up_rounded : Icons.volume_off_rounded,
        ),
        title: Text(l10n.screenAudioText(status.name)),
        subtitle: active
            ? Text(l10n.screenAudioText('restricted'))
            : failed
            ? Text(l10n.screenAudioText('videoOnly'))
            : null,
      ),
    );
  }
}

class _VideoPanel extends StatelessWidget {
  const _VideoPanel({
    required this.title,
    required this.renderer,
    this.trailing,
    this.preferredAspectRatio,
  });

  final String title;
  final RTCVideoRenderer renderer;
  final Widget? trailing;
  final double? preferredAspectRatio;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                trailing ?? const SizedBox(),
              ],
            ),
            const SizedBox(height: 10),
            OrientationAwareVideoView(
              renderer: renderer,
              borderRadius: BorderRadius.circular(8),
              constrainToVideoAspect: true,
              preferredAspectRatio: preferredAspectRatio,
            ),
          ],
        ),
      ),
    );
  }
}

class _StopButton extends StatelessWidget {
  const _StopButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      tooltip: context.l10n.t('stop'),
      onPressed: onPressed,
      icon: const Icon(Icons.stop_rounded),
    );
  }
}

class _SharingMobileCard extends StatelessWidget {
  const _SharingMobileCard({required this.onStop});

  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            const Icon(Icons.screen_share_rounded),
            const SizedBox(width: 12),
            Expanded(child: Text(context.l10n.t('screenSharingMobile'))),
            IconButton.filledTonal(
              tooltip: context.l10n.t('stop'),
              onPressed: onStop,
              icon: const Icon(Icons.stop_rounded),
            ),
          ],
        ),
      ),
    );
  }
}
