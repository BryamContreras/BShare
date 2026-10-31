import 'dart:async';
import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/infrastructure/services/android_screen_awake_service.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/localization/screen_viewer_localizations.dart';
import 'package:bshare/src/presentation/localization/video_connection_localizations.dart';
import 'package:bshare/src/presentation/navigation/app_navigation.dart';
import 'package:bshare/src/presentation/widgets/orientation_aware_video_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

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

class _FocusedScreenViewerState extends ConsumerState<FocusedScreenViewer>
    with WindowListener {
  static const _controlsDelay = Duration(seconds: 3);
  final _screenAwake = AndroidScreenAwakeService();
  final _viewerFocus = FocusNode(debugLabel: 'Screen viewer');
  late final AppLogger _logger;

  String _status = 'Opening viewer...';
  ScreenShareService? _service;
  late final Future<void> _enteringViewer;
  Future<void>? _exitingViewer;
  Future<void>? _closing;
  Timer? _controlsTimer;
  Future<void>? _initializingWindow;
  Future<void>? _changingFullscreen;
  bool? _initialWindowFullscreen;
  bool _windowFullscreenTouched = false;
  bool _ownsWindowsTitleBar = false;
  bool _windowListenerAttached = false;
  bool _fullscreen = false;
  bool _requestedFullscreen = false;
  bool _controlsVisible = true;
  bool _disposed = false;

  bool get _desktop => switch (Theme.of(context).platform) {
    TargetPlatform.windows ||
    TargetPlatform.linux ||
    TargetPlatform.macOS => true,
    _ => false,
  };

  bool get _canHideControls {
    final state = _service!.state.value;
    return _desktop &&
        _fullscreen &&
        _changingFullscreen == null &&
        _closing == null &&
        state.mode == ScreenShareMode.watching &&
        state.error == null &&
        !state.awaitingVideo;
  }

  @override
  void initState() {
    super.initState();
    final service = ref.read(screenShareServiceProvider);
    _logger = ref.read(loggerProvider);
    _service = service;
    service.state.addListener(_onServiceChanged);
    service.setFocusedViewerActive(true);
    _enteringViewer = _enterViewerMode().catchError((Object error) {
      _logger.warn('Viewer setup failed: $error');
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_connectIfNeeded());
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _controlsTimer?.cancel();
    _viewerFocus.dispose();
    if (_windowListenerAttached) windowManager.removeListener(this);
    final service = _service;
    service?.state.removeListener(_onServiceChanged);
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
      _restoreDesktopWindow(),
    ]);
  }

  Future<void> _initializeDesktopWindow() => _initializingWindow ??= () async {
    await windowManager.ensureInitialized();
    final current = await windowManager.isFullScreen();
    _initialWindowFullscreen ??= current;
    _fullscreen = current;
    if (!_disposed && !_windowListenerAttached) {
      windowManager.addListener(this);
      _windowListenerAttached = true;
    }
  }();

  Future<void> _requestDesktopFullscreen(bool enabled) {
    if (!_desktop || _closing != null || _disposed) return Future.value();
    _requestedFullscreen = enabled;
    _controlsTimer?.cancel();
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    return _changingFullscreen ??= _changeDesktopFullscreen();
  }

  Future<void> _changeDesktopFullscreen() async {
    // One native transition at a time; Escape during entry retains only the
    // latest desired state instead of closing the live receiver.
    try {
      await _initializeDesktopWindow();
      while (!_disposed &&
          _closing == null &&
          _fullscreen != _requestedFullscreen) {
        final target = _requestedFullscreen;
        _windowFullscreenTouched = true;
        await _setWindowFullscreen(target);
        if (mounted && !_disposed) setState(() {});
      }
    } catch (error) {
      _logger.warn('Could not change screen viewer fullscreen: $error');
      _requestedFullscreen = _fullscreen;
      _initializingWindow = null;
      if (mounted && !_disposed && _closing == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.screenViewerText('failed'))),
        );
      }
    } finally {
      _changingFullscreen = null;
      if (mounted && !_disposed) {
        setState(() {});
        _armControlsTimer();
      }
    }
  }

  Future<void> _setWindowFullscreen(bool enabled) async {
    await windowManager.setFullScreen(enabled);
    _fullscreen = enabled;
    if (!Platform.isWindows) return;
    if (enabled) {
      // window_manager 0.5.2 retains the native caption when entry starts from
      // a maximized window. Hide it after the plugin saves the original normal
      // title bar and maximized placement; restore only our own change on exit.
      _ownsWindowsTitleBar = true;
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    } else {
      await _restoreWindowsTitleBar();
    }
  }

  Future<void> _restoreWindowsTitleBar() async {
    if (!_ownsWindowsTitleBar) return;
    await windowManager.setTitleBarStyle(TitleBarStyle.normal);
    _ownsWindowsTitleBar = false;
  }

  Future<void> _restoreDesktopWindow() async {
    await _changingFullscreen;
    final initial = _initialWindowFullscreen;
    if (_windowFullscreenTouched && initial != null && _fullscreen != initial) {
      try {
        await _setWindowFullscreen(initial);
        _windowFullscreenTouched = false;
      } catch (error) {
        _logger.warn('Could not restore screen viewer window: $error');
      }
    }
    // A native fullscreen exit may have succeeded while restoring its caption
    // failed. Retry that owned change even when fullscreen already matches.
    if (!_fullscreen) {
      try {
        await _restoreWindowsTitleBar();
      } catch (error) {
        _logger.warn('Could not restore screen viewer title bar: $error');
      }
    }
  }

  @override
  void onWindowEnterFullScreen() {
    if (!mounted || _disposed) return;
    setState(() => _fullscreen = true);
    if (_changingFullscreen == null) _requestedFullscreen = true;
    _armControlsTimer();
  }

  @override
  void onWindowLeaveFullScreen() {
    if (!mounted || _disposed) return;
    _controlsTimer?.cancel();
    setState(() {
      _fullscreen = false;
      _controlsVisible = true;
    });
    if (_changingFullscreen == null) _requestedFullscreen = false;
  }

  void _onServiceChanged() {
    if (!mounted || _disposed) return;
    if (!_canHideControls) {
      _controlsTimer?.cancel();
      if (!_controlsVisible) setState(() => _controlsVisible = true);
    } else if (_controlsVisible && _controlsTimer?.isActive != true) {
      _armControlsTimer();
    }
  }

  void _armControlsTimer() {
    _controlsTimer?.cancel();
    if (!_canHideControls) return;
    _controlsTimer = Timer(_controlsDelay, () {
      if (mounted && !_disposed && _canHideControls) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _showControls() {
    if (!mounted || _disposed || _closing != null) return;
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _armControlsTimer();
  }

  KeyEventResult _onViewerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_desktop && event.logicalKey == LogicalKeyboardKey.escape) {
      if (_fullscreen || _requestedFullscreen || _changingFullscreen != null) {
        unawaited(_requestDesktopFullscreen(false));
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    _showControls();
    return KeyEventResult.ignored;
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

  Future<void> _close() {
    _controlsTimer?.cancel();
    return _closing ??= _closeViewer();
  }

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
          if (didPop) return;
          if (_desktop && _fullscreen) {
            unawaited(_requestDesktopFullscreen(false));
          } else {
            unawaited(_close());
          }
        },
        child: Focus(
          focusNode: _viewerFocus,
          autofocus: true,
          onKeyEvent: _onViewerKey,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: MouseRegion(
              key: const ValueKey('screen-viewer-surface'),
              cursor: _fullscreen && !_controlsVisible
                  ? SystemMouseCursors.none
                  : SystemMouseCursors.basic,
              onEnter: (_) => _showControls(),
              onHover: (_) => _showControls(),
              child: Listener(
                onPointerDown: (_) {
                  _viewerFocus.requestFocus();
                  _showControls();
                },
                onPointerMove: (_) => _showControls(),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: OrientationAwareVideoView(
                        renderer: service.remoteRenderer,
                      ),
                    ),
                    if (_controlsVisible)
                      Positioned(
                        left: 12,
                        right: 12,
                        top: MediaQuery.paddingOf(context).top + 12,
                        child: Row(
                          key: const ValueKey('screen-viewer-controls'),
                          children: [
                            Expanded(
                              child: ValueListenableBuilder(
                                valueListenable: service.state,
                                builder: (context, state, _) {
                                  final status =
                                      state.mode == ScreenShareMode.idle
                                      ? l10n.screenStatus(_status)
                                      : l10n.screenStatus(state.status);
                                  final error = state.error == null
                                      ? null
                                      : l10n.videoConnectionError(state);
                                  return Text(
                                    error == null ? status : '$status: $error',
                                    maxLines: error == null ? 1 : 5,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white),
                                  );
                                },
                              ),
                            ),
                            if (_desktop) ...[
                              IconButton.filledTonal(
                                key: const ValueKey('screen-viewer-fullscreen'),
                                tooltip: l10n.screenViewerText(
                                  _fullscreen ? 'exitFullscreen' : 'fullscreen',
                                ),
                                onPressed: () => unawaited(
                                  _requestDesktopFullscreen(
                                    !_requestedFullscreen,
                                  ),
                                ),
                                icon: Icon(
                                  _fullscreen
                                      ? Icons.fullscreen_exit_rounded
                                      : Icons.fullscreen_rounded,
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            IconButton.filledTonal(
                              key: const ValueKey('screen-viewer-stop'),
                              tooltip: context.l10n.t('closeViewer'),
                              onPressed: _close,
                              icon: Icon(
                                _desktop
                                    ? Icons.stop_rounded
                                    : Icons.close_rounded,
                              ),
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
                          if (!senderDisconnected) {
                            return const SizedBox.shrink();
                          }

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
          ),
        ),
      ),
    );
  }
}
