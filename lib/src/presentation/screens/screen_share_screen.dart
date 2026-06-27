import 'dart:async';
import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
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

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(discoveryProvider.notifier).start();
      ref.read(screenShareServiceProvider).initialize();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(screenShareServiceProvider);
    final devices = ref.watch(discoveryProvider);
    final selected = devices
        .where((device) => device.id == _selectedDeviceId)
        .firstOrNull;
    final l10n = context.l10n;

    return ValueListenableBuilder<ScreenShareState>(
      valueListenable: service.state,
      builder: (context, state, _) {
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
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      GradientActionButton(
                        onPressed: state.mode == ScreenShareMode.idle
                            ? () => _startSharing(service)
                            : null,
                        icon: Icons.screen_share_rounded,
                        label: l10n.t('shareScreen'),
                        vertical: true,
                        width: compact ? 108 : 118,
                        height: 64,
                      ),
                      GradientActionButton(
                        onPressed:
                            selected == null ||
                                state.mode != ScreenShareMode.idle
                            ? null
                            : () => _watch(service, selected),
                        icon: Icons.visibility_rounded,
                        label: l10n.t('watch'),
                        vertical: true,
                        width: compact ? 92 : 104,
                        height: 64,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Card(
                    child: ListTile(
                      leading: Icon(
                        state.mode == ScreenShareMode.idle
                            ? Icons.tv_off_rounded
                            : Icons.connected_tv_rounded,
                      ),
                      title: Text(l10n.screenStatus(state.status)),
                      subtitle: state.error == null ? null : Text(state.error!),
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (state.mode == ScreenShareMode.sharing &&
                      (Platform.isAndroid || Platform.isIOS))
                    _SharingMobileCard(onStop: () => _stop(service))
                  else if (state.mode == ScreenShareMode.sharing)
                    _VideoPanel(
                      title: l10n.t('yourScreen'),
                      renderer: service.localRenderer,
                      trailing: _StopButton(onPressed: () => _stop(service)),
                    )
                  else if (state.mode == ScreenShareMode.watching)
                    ValueListenableBuilder<double?>(
                      valueListenable: service.remoteAspectRatio,
                      builder: (context, aspectRatio, _) {
                        return _VideoPanel(
                          title: l10n.t('remoteScreen'),
                          renderer: service.remoteRenderer,
                          preferredAspectRatio: aspectRatio,
                          settleOnAspectChange: true,
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
                                onPressed: _openViewer,
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
                          onPressed: () =>
                              ref.read(discoveryProvider.notifier).refresh(),
                          icon: Icons.refresh_rounded,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (devices.isEmpty)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.radar_rounded),
                          title: Text(l10n.t('searchingLan')),
                        ),
                      )
                    else
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
                ],
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _startSharing(ScreenShareService service) async {
    try {
      await ref.read(receiveControllerProvider.notifier).start();
      await service.startSharing(ref.read(fileServerProvider));
    } catch (_) {
      await ref.read(receiveControllerProvider.notifier).stop();
    }
  }

  Future<void> _watch(ScreenShareService service, device) async {
    try {
      await service.watch(device);
    } catch (_) {}
  }

  Future<void> _stop(ScreenShareService service) async {
    await service.stop(ref.read(fileServerProvider));
    await ref.read(receiveControllerProvider.notifier).stop();
  }

  void _openViewer() {
    context.push('/screen/viewer');
  }
}

class _VideoPanel extends StatelessWidget {
  const _VideoPanel({
    required this.title,
    required this.renderer,
    this.trailing,
    this.preferredAspectRatio,
    this.settleOnAspectChange = false,
  });

  final String title;
  final RTCVideoRenderer renderer;
  final Widget? trailing;
  final double? preferredAspectRatio;
  final bool settleOnAspectChange;

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
              settleOnAspectChange: settleOnAspectChange,
              settleDuration: const Duration(milliseconds: 1800),
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
