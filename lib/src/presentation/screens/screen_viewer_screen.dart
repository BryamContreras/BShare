import 'dart:async';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/infrastructure/services/android_screen_awake_service.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/widgets/orientation_aware_video_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class ScreenViewerScreen extends ConsumerStatefulWidget {
  const ScreenViewerScreen({super.key, this.device});

  final DeviceInfo? device;

  @override
  ConsumerState<ScreenViewerScreen> createState() => _ScreenViewerScreenState();
}

class _ScreenViewerScreenState extends ConsumerState<ScreenViewerScreen> {
  final _screenAwake = AndroidScreenAwakeService();

  String _status = 'Opening viewer...';

  @override
  void initState() {
    super.initState();
    unawaited(_enterViewerMode());
    Future.microtask(_connectIfNeeded);
  }

  @override
  void dispose() {
    unawaited(_exitViewerMode());
    super.dispose();
  }

  Future<void> _enterViewerMode() async {
    await Future.wait<void>([
      _enterFullscreen(),
      _screenAwake.setViewerActive(true),
    ]);
  }

  Future<void> _exitViewerMode() async {
    await Future.wait<void>([
      _restoreSystemUi(),
      _screenAwake.setViewerActive(false),
    ]);
  }

  Future<void> _enterFullscreen() {
    return SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  Future<void> _restoreSystemUi() async {
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
  }

  Future<void> _connectIfNeeded() async {
    final device = widget.device;
    if (device == null) {
      setState(() => _status = 'Watching remote screen');
      return;
    }
    try {
      await ref.read(screenShareServiceProvider).watch(device);
      if (mounted) setState(() => _status = 'Watching ${device.name}');
    } catch (error) {
      if (mounted) setState(() => _status = 'Could not connect: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(screenShareServiceProvider);
    final renderer = service.remoteRenderer;
    final l10n = context.l10n;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: ValueListenableBuilder<double?>(
                valueListenable: service.remoteAspectRatio,
                builder: (context, aspectRatio, _) {
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: OrientationAwareVideoView(
                          renderer: renderer,
                          preferredAspectRatio: aspectRatio,
                          settleOnAspectChange: true,
                          settleDuration: const Duration(milliseconds: 1800),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            ValueListenableBuilder<ScreenShareState>(
              valueListenable: service.state,
              builder: (context, state, _) {
                final senderDisconnected =
                    state.mode == ScreenShareMode.idle &&
                    state.status == 'Screen share ended';
                if (!senderDisconnected) return const SizedBox.shrink();

                return Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 20,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.portable_wifi_off_rounded,
                            color: Colors.white,
                            size: 32,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            l10n.t('senderDisconnected'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            Positioned(
              left: 12,
              right: 12,
              top: MediaQuery.of(context).padding.top + 12,
              child: Row(
                children: [
                  Expanded(
                    child: ValueListenableBuilder(
                      valueListenable: service.state,
                      builder: (context, state, _) {
                        final status = state.mode == ScreenShareMode.idle
                            ? l10n.screenStatus(_status)
                            : l10n.screenStatus(state.status);
                        final error = state.error;
                        return Text(
                          error == null ? status : '$status: $error',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white),
                        );
                      },
                    ),
                  ),
                  IconButton.filledTonal(
                    tooltip: context.l10n.t('closeViewer'),
                    onPressed: () async {
                      await _exitViewerMode();
                      if (!context.mounted) return;
                      if (Navigator.of(context).canPop()) {
                        context.pop();
                      } else {
                        context.go('/screen');
                      }
                    },
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
