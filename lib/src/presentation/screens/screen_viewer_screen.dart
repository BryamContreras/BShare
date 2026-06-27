import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
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
  String _status = 'Opening viewer...';

  @override
  void initState() {
    super.initState();
    _enterFullscreen();
    Future.microtask(_connectIfNeeded);
  }

  @override
  void dispose() {
    _restoreSystemUi();
    super.dispose();
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
                      await _restoreSystemUi();
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
