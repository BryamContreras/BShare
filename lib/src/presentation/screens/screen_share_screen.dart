import 'dart:async';
import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/localization/video_connection_localizations.dart';
import 'package:bshare/src/presentation/localization/camera_localizations.dart';
import 'package:bshare/src/presentation/localization/camera_ui_localizations.dart';
import 'package:bshare/src/presentation/screens/screen_viewer_screen.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:bshare/src/presentation/widgets/discovery_status_card.dart';
import 'package:bshare/src/presentation/widgets/gradient_action_button.dart';
import 'package:bshare/src/presentation/widgets/orientation_aware_video_view.dart';
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
  String? _selectedDeviceId;
  DeviceInfo? _viewerDevice;
  bool _startingShare = false;
  late final ScreenShareService _service;

  @override
  void initState() {
    super.initState();
    _service = ref.read(screenShareServiceProvider);
    _service.state.addListener(_resumeDiscoveryWhenIdle);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(discoveryProvider.notifier).start());
    });
  }

  @override
  void dispose() {
    _service.state.removeListener(_resumeDiscoveryWhenIdle);
    _scrollController.dispose();
    super.dispose();
  }

  void _resumeDiscoveryWhenIdle() {
    if (!mounted ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.detached ||
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
                      else ...[
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
                              onTap: () =>
                                  setState(() => _selectedDeviceId = device.id),
                            ),
                          ),
                      ],
                      const SizedBox(height: 20),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final shareButton = FilledButton.icon(
                            onPressed:
                                !_startingShare &&
                                    state.mode == ScreenShareMode.idle
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
                                selected == null ||
                                    _startingShare ||
                                    state.mode != ScreenShareMode.idle
                                ? null
                                : () => _watch(service, selected),
                            icon: const Icon(Icons.visibility_rounded),
                            label: Text(l10n.t('watch')),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 52),
                              shape: const StadiumBorder(),
                            ),
                          );
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
    if (_startingShare) return;
    setState(() => _startingShare = true);
    final receiver = ref.read(receiveControllerProvider.notifier);
    try {
      final settings = await ref.read(settingsProvider.future);
      if (!mounted) return;
      await receiver.startForScreenShare();
      if (!mounted) {
        await receiver.stopIfScreenShareOnly();
        return;
      }
      final receive = ref.read(receiveControllerProvider).value;
      if (receive?.visible != true) {
        throw StateError(receive?.error ?? 'Receiver unavailable');
      }
      await service.startSharing(
        ref.read(fileServerProvider),
        settings: settings.screenCapture,
      );
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

  Future<void> _watch(ScreenShareService service, DeviceInfo device) async {
    setState(() => _viewerDevice = device);
    service.setFocusedViewerActive(true);
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
