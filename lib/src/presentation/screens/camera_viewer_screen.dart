import 'dart:async';
import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/infrastructure/services/android_screen_awake_service.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/localization/camera_viewer_localizations.dart';
import 'package:bshare/src/presentation/navigation/app_navigation.dart';
import 'package:bshare/src/presentation/widgets/orientation_aware_video_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class CameraViewerScreen extends ConsumerWidget {
  const CameraViewerScreen({super.key, this.device, this.allowedLocalIps});

  final DeviceInfo? device;
  final List<String>? allowedLocalIps;

  @override
  Widget build(BuildContext context, WidgetRef ref) => FocusedCameraViewer(
    device: device,
    allowedLocalIps: allowedLocalIps,
    onClose: () async {
      AppNavigationScope.back(context, fallback: '/camera');
    },
  );
}

/// Uses the existing remote renderer and peer. The setup page must unmount its
/// compact preview before mounting this focused view.
class FocusedCameraViewer extends ConsumerStatefulWidget {
  const FocusedCameraViewer({
    super.key,
    this.device,
    this.allowedLocalIps,
    required this.onClose,
  });

  final DeviceInfo? device;
  final List<String>? allowedLocalIps;
  final Future<void> Function() onClose;

  @override
  ConsumerState<FocusedCameraViewer> createState() =>
      _FocusedCameraViewerState();
}

class _FocusedCameraViewerState extends ConsumerState<FocusedCameraViewer> {
  static const _controlsDelay = Duration(seconds: 3);
  final _screenAwake = AndroidScreenAwakeService();
  late final ScreenShareService _service;
  late final AppLogger _logger;
  late final Future<void> _enteringViewer;
  Timer? _controlsTimer;
  Future<void>? _exitingViewer;
  Future<void>? _stoppingViewer;
  Future<void>? _closing;
  bool _opening = true;
  bool _failed = false;
  bool _controlsVisible = true;
  bool _wasHealthy = false;
  bool _ownsViewer = false;

  bool get _healthy =>
      !_opening &&
      !_failed &&
      _closing == null &&
      _service.source == VideoShareSource.camera &&
      _service.state.value.mode == ScreenShareMode.watching &&
      _service.state.value.error == null;

  @override
  void initState() {
    super.initState();
    _service = ref.read(screenShareServiceProvider);
    _logger = ref.read(loggerProvider);
    _service.setFocusedViewerActive(true);
    _service.state.addListener(_onServiceChanged);
    _enteringViewer = _enterViewerMode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _closing == null) unawaited(_connectIfNeeded());
    });
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _service.state.removeListener(_onServiceChanged);
    _service.setFocusedViewerActive(false);
    if (_closing == null) unawaited(_stopOwnedViewer());
    unawaited(_exitViewerMode());
    super.dispose();
  }

  Future<void> _enterViewerMode() async {
    try {
      await Future.wait<void>([
        if (Platform.isAndroid || Platform.isIOS)
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
        _screenAwake.setViewerActive(true),
      ]);
    } catch (error) {
      _logger.warn('Camera viewer display setup failed: $error');
    }
  }

  Future<void> _exitViewerMode() => _exitingViewer ??= () async {
    await _enteringViewer;
    try {
      await Future.wait<void>([
        if (Platform.isAndroid || Platform.isIOS)
          SystemChrome.setEnabledSystemUIMode(
            SystemUiMode.manual,
            overlays: SystemUiOverlay.values,
          ),
        _screenAwake.setViewerActive(false),
      ]);
    } catch (error) {
      _logger.warn('Camera viewer display restore failed: $error');
    }
  }();

  Future<void> _connectIfNeeded() async {
    try {
      final state = _service.state.value;
      if (widget.device case final device?) {
        _ownsViewer = true;
        await _service.watchCamera(
          device,
          allowedLocalIps: widget.allowedLocalIps,
        );
      } else {
        _ownsViewer =
            _service.source == VideoShareSource.camera &&
            state.mode == ScreenShareMode.watching;
        _failed = !_ownsViewer;
      }
    } catch (error) {
      _logger.warn('Could not open camera viewer: $error');
      _failed = true;
    }
    if (!mounted || _closing != null) return;
    setState(() => _opening = false);
    _onServiceChanged();
  }

  void _onServiceChanged() {
    if (!mounted) return;
    final healthy = _healthy;
    if (!healthy) {
      _controlsTimer?.cancel();
      _controlsTimer = null;
      if (!_controlsVisible) setState(() => _controlsVisible = true);
    } else if (!_wasHealthy) {
      _armControlsTimer();
    }
    _wasHealthy = healthy;
  }

  void _armControlsTimer() {
    _controlsTimer?.cancel();
    _controlsTimer = null;
    if (!_healthy) return;
    _controlsTimer = Timer(_controlsDelay, () {
      _controlsTimer = null;
      if (mounted && _healthy) setState(() => _controlsVisible = false);
    });
  }

  void _showControls() {
    if (!mounted || _closing != null) return;
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _armControlsTimer();
  }

  Future<void> _stopOwnedViewer() => _stoppingViewer ??= () async {
    if (!_ownsViewer) return;
    try {
      await _service.stopWatching();
    } catch (error) {
      _logger.warn('Could not close camera viewer: $error');
    }
  }();

  Future<void> _close() {
    if (_closing case final closing?) return closing;
    _controlsTimer?.cancel();
    final closing = _closeViewer();
    _closing = closing;
    if (mounted) setState(() => _controlsVisible = true);
    return closing;
  }

  Future<void> _closeViewer() async {
    await _stopOwnedViewer();
    await _exitViewerMode();
    if (mounted) await widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_close());
        },
        child: Scaffold(
          key: const ValueKey('focused-camera-viewer'),
          backgroundColor: Colors.black,
          body: Focus(
            autofocus: true,
            onKeyEvent: (_, event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              final wasHidden = !_controlsVisible;
              _showControls();
              return wasHidden
                  ? KeyEventResult.handled
                  : KeyEventResult.ignored;
            },
            child: MouseRegion(
              onHover: (_) => _showControls(),
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (_) => _showControls(),
                onPointerMove: (_) => _showControls(),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    OrientationAwareVideoView(
                      renderer: _service.remoteRenderer,
                    ),
                    ValueListenableBuilder<ScreenShareState>(
                      valueListenable: _service.state,
                      builder: (context, state, _) {
                        final failed = _failed || state.error != null;
                        final ended =
                            !_opening && state.mode != ScreenShareMode.watching;
                        if (!failed && !ended && !_opening) {
                          return const SizedBox.shrink();
                        }
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_opening && !failed)
                                  const CircularProgressIndicator(
                                    color: Colors.white,
                                  )
                                else
                                  const Icon(
                                    Icons.portable_wifi_off_rounded,
                                    color: Colors.white,
                                    size: 40,
                                  ),
                                const SizedBox(height: 16),
                                Text(
                                  l10n.cameraViewerText(
                                    failed
                                        ? 'failed'
                                        : _opening
                                        ? 'connecting'
                                        : 'ended',
                                  ),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                    if (_controlsVisible)
                      SafeArea(
                        child: Align(
                          alignment: Alignment.topRight,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: IconButton(
                              key: const ValueKey('camera-viewer-stop'),
                              tooltip: l10n.cameraViewerText(
                                _closing == null ? 'stop' : 'stopping',
                              ),
                              onPressed: _closing == null ? _close : null,
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                foregroundColor: Colors.white,
                                disabledForegroundColor: Colors.white70,
                                minimumSize: const Size.square(48),
                              ),
                              icon: _closing != null
                                  ? const SizedBox.square(
                                      dimension: 22,
                                      child: CircularProgressIndicator(
                                        color: Colors.white,
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.stop_rounded,
                                      shadows: [
                                        Shadow(
                                          color: Colors.black87,
                                          blurRadius: 4,
                                        ),
                                      ],
                                    ),
                            ),
                          ),
                        ),
                      )
                    else
                      Semantics(
                        button: true,
                        label: l10n.cameraViewerText('showControls'),
                        onTap: _showControls,
                        child: GestureDetector(
                          key: const ValueKey('camera-viewer-reveal'),
                          behavior: HitTestBehavior.opaque,
                          onTap: _showControls,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
