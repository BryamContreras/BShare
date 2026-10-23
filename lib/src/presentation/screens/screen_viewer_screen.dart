import 'dart:async';
import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/infrastructure/services/android_screen_awake_service.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/navigation/app_navigation.dart';
import 'package:bshare/src/presentation/widgets/orientation_aware_video_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ScreenViewerScreen extends ConsumerWidget {
  const ScreenViewerScreen({super.key, this.device});

  final DeviceInfo? device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FocusedScreenViewer(
      device: device,
      onClose: () async {
        AppNavigationScope.back(context, fallback: '/screen');
      },
    );
  }
}

/// A focused view of the active remote screen stream.
///
/// The compact preview is unmounted before this widget is shown, so both views
/// can safely reuse the service's single native renderer and peer connection.
class FocusedScreenViewer extends ConsumerStatefulWidget {
  const FocusedScreenViewer({super.key, this.device, required this.onClose});

  final DeviceInfo? device;
  final Future<void> Function() onClose;

  @override
  ConsumerState<FocusedScreenViewer> createState() =>
      _FocusedScreenViewerState();
}

class _FocusedScreenViewerState extends ConsumerState<FocusedScreenViewer> {
  final _screenAwake = AndroidScreenAwakeService();

  String _status = 'Opening viewer...';
  ScreenShareService? _service;
  late final Future<void> _enteringViewer;
  Future<void>? _exitingViewer;
  Future<void>? _closing;

  @override
  void initState() {
    super.initState();
    final service = ref.read(screenShareServiceProvider);
    _service = service;
    service.setFocusedViewerActive(true);
    _enteringViewer = _enterViewerMode().catchError((Object error) {
      if (mounted) ref.read(loggerProvider).warn('Viewer setup failed: $error');
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_connectIfNeeded());
    });
  }

  @override
  void dispose() {
    final service = _service;
    service?.setFocusedViewerActive(false);
    if (service != null && _closing == null) unawaited(service.stopWatching());
    unawaited(_exitViewerMode());
    super.dispose();
  }

  Future<void> _enterViewerMode() async {
    await Future.wait<void>([
      _enterFullscreen(),
      _screenAwake.setViewerActive(true),
    ]);
  }

  Future<void> _exitViewerMode() => _exitingViewer ??= _restoreViewerMode();

  Future<void> _restoreViewerMode() async {
    await _enteringViewer;
    await Future.wait<void>([
      _restoreSystemUi(),
      _screenAwake.setViewerActive(false),
    ]);
  }

  Future<void> _enterFullscreen() {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return Future.value();
    }
    return SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  Future<void> _restoreSystemUi() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
  }

  Future<void> _connectIfNeeded() async {
    final service = _service!;
    if (service.state.value.mode == ScreenShareMode.watching &&
        service.remoteRenderer.srcObject != null) {
      if (mounted) setState(() => _status = 'Watching remote screen');
      return;
    }
    final device = widget.device;
    if (device == null) {
      setState(() => _status = 'Watching remote screen');
      return;
    }
    try {
      await service.watch(device);
      if (mounted) setState(() => _status = 'Watching ${device.name}');
    } catch (error) {
      if (mounted) setState(() => _status = 'Could not connect: $error');
    }
  }

  Future<void> _close() => _closing ??= _closeViewer();

  Future<void> _closeViewer() async {
    await _service!.stopWatching();
    await _exitViewerMode();
    if (mounted) await widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(screenShareServiceProvider);
    final l10n = context.l10n;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_close());
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              Positioned.fill(
                child: OrientationAwareVideoView(
                  renderer: service.remoteRenderer,
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                top: MediaQuery.paddingOf(context).top + 12,
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
                      onPressed: _close,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Positioned.fill(
                child: ValueListenableBuilder<ScreenShareState>(
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
              ),
            ],
          ),
        ),
      ),
    );
  }
}
