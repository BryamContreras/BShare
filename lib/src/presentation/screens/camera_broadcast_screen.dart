import 'dart:async';
import 'dart:io';

import 'package:bshare/src/application/camera_session_controller.dart';
import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/camera_device.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/localization/camera_broadcast_localizations.dart';
import 'package:bshare/src/presentation/localization/camera_localizations.dart';
import 'package:bshare/src/presentation/localization/camera_ui_localizations.dart';
import 'package:bshare/src/presentation/navigation/app_navigation.dart';
import 'package:bshare/src/presentation/widgets/orientation_aware_video_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Owns the presentation of an already running camera session, never another
/// capturer or renderer. Hiding the preview only removes its local texture view.
class CameraBroadcastScreen extends ConsumerStatefulWidget {
  const CameraBroadcastScreen({super.key});

  @override
  ConsumerState<CameraBroadcastScreen> createState() =>
      _CameraBroadcastScreenState();
}

class _CameraBroadcastScreenState extends ConsumerState<CameraBroadcastScreen> {
  late final ScreenShareService _service;
  late final CameraSessionController _session;
  late final AppLogger _logger;
  late final Future<void> _enteringFullscreen;
  Future<void>? _restoringSystemUi;
  Future<void>? _closing;
  bool _previewVisible = true;
  String? _closeError;

  @override
  void initState() {
    super.initState();
    _service = ref.read(screenShareServiceProvider);
    _session = ref.read(cameraSessionProvider.notifier);
    _logger = ref.read(loggerProvider);
    _enteringFullscreen = _enterFullscreen().catchError((Object error) {
      _logger.warn('Could not enter camera fullscreen: $error');
    });
  }

  @override
  void dispose() {
    // Capture belongs to the shared session, so navigation to Settings or
    // Transfers must only release this view. Back/Stop explicitly ends capture.
    unawaited(_restoreSystemUi());
    super.dispose();
  }

  Future<void> _enterFullscreen() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  Future<void> _restoreSystemUi() =>
      _restoringSystemUi ??= _restoreSystemUiAfterEntry();

  Future<void> _restoreSystemUiAfterEntry() async {
    await _enteringFullscreen;
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
    } catch (error) {
      _logger.warn('Could not restore camera system UI: $error');
    }
  }

  Future<void> _close() {
    if (_closing != null) return _closing!;
    final closing = _closeBroadcast();
    _closing = closing;
    if (mounted) setState(() => _closeError = null);
    return closing;
  }

  Future<void> _closeBroadcast() async {
    try {
      // Do not cancel a different source when opening this route without an
      // active camera. Camera session cleanup owns its display and receiver.
      if (_service.source == VideoShareSource.camera) await _session.stop();
      await _restoreSystemUi();
      if (mounted) AppNavigationScope.back(context, fallback: '/camera');
    } catch (error) {
      _logger.warn('Could not close camera broadcast: $error');
      if (!mounted) return;
      setState(() {
        _closing = null;
        _closeError = 'stopFailed';
      });
    }
  }

  Future<void> _switchCamera(CameraDevice camera) async {
    try {
      await _session.switchCamera(camera);
    } catch (_) {
      // The controller logs native details and exposes a localized error key.
      // A failed switch can restore the previous camera without ending video.
    }
  }

  Future<void> _setTorchEnabled(bool enabled) async {
    try {
      await _session.setTorchEnabled(enabled);
    } catch (_) {
      // Failed native changes keep the previous state and expose a local error.
    }
  }

  Future<void> _setMicrophoneEnabled(bool enabled) async {
    try {
      await _session.setMicrophoneEnabled(enabled);
    } catch (_) {
      // Permission failures stay in the controller, without interrupting video.
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(cameraSessionProvider);
    final cameras = ref.watch(cameraDevicesProvider).value ?? const [];
    final l10n = context.l10n;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_close());
        },
        child: Scaffold(
          key: const ValueKey('camera-broadcast-screen'),
          backgroundColor: Colors.black,
          body: ValueListenableBuilder<ScreenShareState>(
            valueListenable: _service.state,
            builder: (context, state, _) {
              final sharing =
                  _service.source == VideoShareSource.camera &&
                  state.mode == ScreenShareMode.sharing;
              final currentCamera = _service.currentCamera;
              final otherCamera = cameras
                  .where(
                    (camera) =>
                        currentCamera != null &&
                        camera.frontFacing != currentCamera.frontFacing,
                  )
                  .firstOrNull;
              final busy = session.busy || _closing != null;
              final errorText = _closeError != null
                  ? l10n.cameraBroadcastText(_closeError!)
                  : session.error == null
                  ? null
                  : l10n.cameraUiText(session.error!);
              return Stack(
                fit: StackFit.expand,
                children: [
                  if (sharing && _previewVisible)
                    OrientationAwareVideoView(
                      key: const ValueKey('camera-live-preview'),
                      renderer: _service.localRenderer,
                    )
                  else
                    _PreviewPlaceholder(
                      sharing: sharing,
                      previewVisible: _previewVisible,
                    ),
                  SafeArea(
                    minimum: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: SingleChildScrollView(
                            key: const ValueKey('camera-live-header-scroll'),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    _CameraControl(
                                      buttonKey: const ValueKey(
                                        'camera-live-back',
                                      ),
                                      tooltip: l10n.t('back'),
                                      onPressed: _closing == null
                                          ? _close
                                          : null,
                                      icon: Icons.arrow_back_rounded,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Semantics(
                                        liveRegion: true,
                                        child: Text(
                                          sharing
                                              ? l10n.cameraText(
                                                  currentCamera?.frontFacing ==
                                                          true
                                                      ? 'frontCamera'
                                                      : 'backCamera',
                                                )
                                              : l10n.cameraBroadcastText(
                                                  'cameraStopped',
                                                ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyMedium
                                              ?.copyWith(
                                                color: Colors.white,
                                                shadows: const [
                                                  Shadow(
                                                    color: Colors.black87,
                                                    blurRadius: 4,
                                                  ),
                                                ],
                                              ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                if (errorText != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: Semantics(
                                      liveRegion: true,
                                      child: Text(
                                        errorText,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(
                                              color: Colors.white,
                                              shadows: const [
                                                Shadow(
                                                  color: Colors.black,
                                                  blurRadius: 6,
                                                ),
                                              ],
                                            ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        _CameraToolbar(
                          controls: [
                            if (sharing) ...[
                              _CameraControl(
                                buttonKey: const ValueKey('camera-live-switch'),
                                tooltip: l10n.cameraUiText('switchCamera'),
                                onPressed: busy || otherCamera == null
                                    ? null
                                    : () => _switchCamera(otherCamera),
                                icon: Icons.cameraswitch_rounded,
                              ),
                              const SizedBox(height: 4),
                              _CameraControl(
                                buttonKey: const ValueKey(
                                  'camera-live-preview-toggle',
                                ),
                                tooltip: l10n.cameraBroadcastText(
                                  _previewVisible
                                      ? 'hidePreview'
                                      : 'showPreview',
                                ),
                                onPressed: _closing == null
                                    ? () => setState(
                                        () =>
                                            _previewVisible = !_previewVisible,
                                      )
                                    : null,
                                icon: _previewVisible
                                    ? Icons.visibility_rounded
                                    : Icons.visibility_off_rounded,
                                selected: !_previewVisible,
                              ),
                              const SizedBox(height: 4),
                              _CameraControl(
                                buttonKey: const ValueKey('camera-live-torch'),
                                tooltip: l10n.cameraBroadcastText(
                                  !session.torchAvailable
                                      ? 'flashUnavailable'
                                      : session.torchEnabled
                                      ? 'disableFlash'
                                      : 'enableFlash',
                                ),
                                onPressed: busy || !session.torchAvailable
                                    ? null
                                    : () => _setTorchEnabled(
                                        !session.torchEnabled,
                                      ),
                                icon: session.torchEnabled
                                    ? Icons.flash_on_rounded
                                    : Icons.flash_off_rounded,
                                selected: session.torchEnabled,
                              ),
                              const SizedBox(height: 4),
                              _CameraControl(
                                buttonKey: const ValueKey(
                                  'camera-live-microphone',
                                ),
                                tooltip: l10n.cameraBroadcastText(
                                  session.microphoneEnabled
                                      ? 'disableMicrophone'
                                      : 'enableMicrophone',
                                ),
                                onPressed: busy
                                    ? null
                                    : () => _setMicrophoneEnabled(
                                        !session.microphoneEnabled,
                                      ),
                                icon: session.microphoneEnabled
                                    ? Icons.mic_rounded
                                    : Icons.mic_off_rounded,
                                selected: session.microphoneEnabled,
                              ),
                            ],
                          ],
                          stop: _CameraControl(
                            buttonKey: const ValueKey('camera-live-stop'),
                            tooltip: sharing
                                ? l10n.cameraUiText('stop')
                                : l10n.cameraBroadcastText('returnToCamera'),
                            onPressed: _closing == null ? _close : null,
                            icon: sharing
                                ? Icons.stop_rounded
                                : Icons.arrow_back_rounded,
                            busy: _closing != null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Keeps Stop reachable without reducing any action's 48 dp touch target.
/// On short viewports only the optional controls scroll; Stop stays below them.
class _CameraToolbar extends StatelessWidget {
  const _CameraToolbar({required this.controls, required this.stop});

  final List<Widget> controls;
  final Widget stop;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 48,
    child: LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 4.0;
        // Every control is 48 dp; the input list also contains its 4 dp gaps.
        final controlsHeight = controls.isEmpty
            ? 0.0
            : ((controls.length + 1) ~/ 2) * 48 +
                  ((controls.length - 1) ~/ 2) * spacing;
        final naturalHeight =
            controlsHeight + (controls.isEmpty ? 0 : spacing) + 48;
        if (constraints.maxHeight >= naturalHeight || controls.isEmpty) {
          return Column(
            key: const ValueKey('camera-live-controls'),
            mainAxisSize: MainAxisSize.min,
            children: [
              ...controls,
              if (controls.isNotEmpty) const SizedBox(height: spacing),
              stop,
            ],
          );
        }
        return SizedBox(
          height: constraints.maxHeight,
          child: Column(
            key: const ValueKey('camera-live-controls'),
            children: [
              Expanded(
                child: SingleChildScrollView(
                  key: const ValueKey('camera-live-controls-scroll'),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: controls,
                  ),
                ),
              ),
              const SizedBox(height: spacing),
              stop,
            ],
          ),
        );
      },
    ),
  );
}

class _CameraControl extends StatelessWidget {
  const _CameraControl({
    required this.buttonKey,
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    this.selected,
    this.busy = false,
  });

  final Key buttonKey;
  final String tooltip;
  final VoidCallback? onPressed;
  final IconData icon;
  final bool? selected;
  final bool busy;

  @override
  Widget build(BuildContext context) => IconButton(
    key: buttonKey,
    tooltip: tooltip,
    onPressed: onPressed,
    isSelected: selected,
    style: IconButton.styleFrom(
      backgroundColor: Colors.transparent,
      foregroundColor: selected == true ? Colors.amberAccent : Colors.white,
      disabledForegroundColor: Colors.white38,
      minimumSize: const Size.square(48),
    ),
    icon: busy
        ? const SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          )
        : Icon(
            icon,
            shadows: const [Shadow(color: Colors.black87, blurRadius: 4)],
          ),
  );
}

class _PreviewPlaceholder extends StatelessWidget {
  const _PreviewPlaceholder({
    required this.sharing,
    required this.previewVisible,
  });

  final bool sharing;
  final bool previewVisible;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final horizontalPadding = (constraints.maxWidth * .08).clamp(
            16.0,
            32.0,
          );
          final verticalPadding = (constraints.maxHeight * .1).clamp(
            12.0,
            48.0,
          );
          final contentHeight = (constraints.maxHeight - verticalPadding * 2)
              .clamp(0.0, double.infinity);
          return SingleChildScrollView(
            key: const ValueKey('camera-live-placeholder-scroll'),
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: verticalPadding,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: contentHeight),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      sharing
                          ? Icons.visibility_off_rounded
                          : Icons.videocam_off_rounded,
                      color: Colors.white54,
                      size: 42,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      l10n.cameraBroadcastText(
                        sharing && !previewVisible
                            ? 'previewHidden'
                            : 'cameraStopped',
                      ),
                      textAlign: TextAlign.center,
                      style: textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                    if (sharing) ...[
                      const SizedBox(height: 8),
                      Text(
                        l10n.cameraBroadcastText('sharingContinues'),
                        textAlign: TextAlign.center,
                        style: textTheme.bodyMedium?.copyWith(
                          color: Colors.white60,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
