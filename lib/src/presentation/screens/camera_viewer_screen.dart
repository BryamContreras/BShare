import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/application/camera_media_provider.dart';
import 'package:bshare/src/domain/entities/camera_capture_controls.dart';
import 'package:bshare/src/domain/entities/camera_media_state.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/infrastructure/services/android_screen_awake_service.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/file_server.dart';
import 'package:bshare/src/infrastructure/services/camera_media_service.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/localization/video_connection_localizations.dart';
import 'package:bshare/src/presentation/localization/camera_viewer_localizations.dart';
import 'package:bshare/src/presentation/localization/camera_ui_localizations.dart';
import 'package:bshare/src/presentation/navigation/app_navigation.dart';
import 'package:bshare/src/presentation/widgets/orientation_aware_video_view.dart';
import 'package:bshare/src/presentation/widgets/camera_media_actions_panel.dart';
import 'package:file_picker/file_picker.dart';
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

class _FocusedCameraViewerState extends ConsumerState<FocusedCameraViewer>
    with SingleTickerProviderStateMixin {
  static const _controlsDelay = Duration(seconds: 3);
  final _screenAwake = AndroidScreenAwakeService();
  late final ScreenShareService _service;
  late final AppLogger _logger;
  late final Future<void> _enteringViewer;
  late final AnimationController _photoFlash;
  late final Animation<double> _photoFlashOpacity;
  Timer? _controlsTimer;
  Future<void>? _exitingViewer;
  Future<void>? _stoppingViewer;
  Future<void>? _closing;
  bool _opening = true;
  bool _failed = false;
  bool _controlsVisible = true;
  bool _wasHealthy = false;
  bool _ownsViewer = false;
  bool _remoteControlBusy = false;
  bool _mirrorView = false;
  bool _previewBusy = false;
  String? _mediaAction;
  String? _mediaError;
  final _desktopHorizontalScroll = ScrollController();
  String? _remoteControlError;
  static const _liveControlInterval = Duration(milliseconds: 120);
  Timer? _liveControlThrottle;
  (String?, String?)? _liveControlScope;
  String? _liveControlProperty;
  double? _liveControlPending;
  bool _liveControlDragging = false;
  bool _liveControlSending = false;
  (String?, String?)? _liveRequestScope;
  String? _liveRequestProperty;
  double? _liveRequestValue;
  int _liveControlEpoch = 0;
  final _liveControlCompletions = <Completer<void>>[];

  bool get _liveControlActive =>
      _liveControlDragging ||
      _liveControlPending != null ||
      _liveControlSending;

  bool get _desktop {
    final platform = Theme.of(context).platform;
    return platform == TargetPlatform.windows ||
        platform == TargetPlatform.linux ||
        platform == TargetPlatform.macOS;
  }

  bool get _healthy =>
      !_opening &&
      !_failed &&
      _closing == null &&
      _service.source == VideoShareSource.camera &&
      _service.state.value.mode == ScreenShareMode.watching &&
      _service.state.value.error == null &&
      !_service.state.value.awaitingVideo;

  @override
  void initState() {
    super.initState();
    _photoFlash = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _photoFlashOpacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween<double>(begin: 0, end: .16), weight: 1),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: .16,
          end: 0,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 3,
      ),
    ]).animate(_photoFlash);
    _service = ref.read(screenShareServiceProvider);
    _logger = ref.read(loggerProvider);
    _service.setFocusedViewerActive(true);
    _service.state.addListener(_onServiceChanged);
    _service.remoteCameraControls.addListener(_onRemoteControlsChanged);
    _service.remotePreviewEnabled.addListener(_onPreviewChanged);
    _enteringViewer = _enterViewerMode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _closing == null) unawaited(_connectIfNeeded());
    });
  }

  @override
  void dispose() {
    _cancelLiveControl(notify: false);
    _photoFlash.dispose();
    _controlsTimer?.cancel();
    _desktopHorizontalScroll.dispose();
    _service.state.removeListener(_onServiceChanged);
    _service.remoteCameraControls.removeListener(_onRemoteControlsChanged);
    _service.remotePreviewEnabled.removeListener(_onPreviewChanged);
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
    _onRemoteControlsChanged();
    if (_desktop) return;
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
    if (_desktop || !_healthy) return;
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
    _cancelLiveControl(notify: false);
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

  Future<void> _runRemoteControl(
    Future<void> Function() operation,
    String errorKey,
  ) async {
    if (_remoteControlBusy || _liveControlSending || _closing != null) return;
    _cancelLiveControl(notify: false);
    setState(() {
      _remoteControlBusy = true;
      _remoteControlError = null;
    });
    try {
      await operation();
    } catch (error) {
      _logger.warn('Could not change remote camera: $error');
      if (mounted) {
        setState(() {
          _remoteControlError =
              error is CameraControlException &&
                  error.code == 'camera-microphone-permission-denied'
              ? 'microphonePermission'
              : errorKey;
        });
      }
    } finally {
      if (mounted) setState(() => _remoteControlBusy = false);
    }
  }

  Future<void> _stopRemoteSharing() => _runRemoteControl(() async {
    await _service.stopRemoteCameraSharing();
    // The remote stop already releases this peer; Back only owns local cleanup.
    _ownsViewer = false;
    await _close();
  }, 'stopFailed');

  (String?, String?) _captureScope(CameraCaptureControls capture) =>
      (_service.remoteCameraControlSessionId, capture.cameraId);

  bool _liveScopeAvailable((String?, String?) scope, String property) {
    final controls = _service.remoteCameraControls.value;
    final capture = controls.capture;
    return mounted &&
        !_opening &&
        !_failed &&
        _closing == null &&
        !_remoteControlBusy &&
        controls.available &&
        capture.available &&
        _captureScope(capture) == scope &&
        _service.source == VideoShareSource.camera &&
        _service.state.value.mode == ScreenShareMode.watching &&
        _service.state.value.error == null &&
        (property == 'zoom'
            ? capture.zoom.supported
            : capture.whiteBalanceWarmth.supported);
  }

  CameraNumericControl _liveNumericControl(String property) {
    final capture = _service.remoteCameraControls.value.capture;
    return property == 'zoom' ? capture.zoom : capture.whiteBalanceWarmth;
  }

  void _onRemoteControlsChanged() {
    final scope = _liveControlScope;
    final property = _liveControlProperty;
    if (scope == null || property == null) return;
    if (!_liveScopeAvailable(scope, property) ||
        (_service.remoteCameraControls.value.busy && !_liveControlSending) ||
        (_liveControlPending != null &&
            !_liveNumericControl(property).accepts(_liveControlPending!))) {
      _cancelLiveControl();
    }
  }

  void _completeLiveControl() {
    _liveControlThrottle?.cancel();
    _liveControlThrottle = null;
    for (final completion in _liveControlCompletions) {
      if (!completion.isCompleted) completion.complete();
    }
    _liveControlCompletions.clear();
    _liveControlProperty = null;
    _liveControlScope = null;
  }

  void _cancelLiveControl({bool notify = true}) {
    _liveControlEpoch++;
    _liveControlPending = null;
    _liveControlDragging = false;
    _completeLiveControl();
    // An existing HTTP operation drains normally; it cannot send a queued value
    // to a different camera or viewer after this epoch has been invalidated.
    if (notify && mounted) setState(() {});
  }

  void _beginLiveControl((String?, String?) scope, String property) {
    if (!_liveScopeAvailable(scope, property)) return;
    if (_liveControlSending &&
        (_liveRequestScope != scope || _liveRequestProperty != property)) {
      return;
    }
    if (_liveControlScope != scope || _liveControlProperty != property) {
      _cancelLiveControl(notify: false);
    }
    setState(() {
      _liveControlScope = scope;
      _liveControlProperty = property;
      _liveControlDragging = true;
      _remoteControlError = null;
    });
  }

  void _queueLiveControl(
    (String?, String?) scope,
    String property,
    double value,
  ) {
    if (!_liveScopeAvailable(scope, property) ||
        !_liveNumericControl(property).accepts(value)) {
      return;
    }
    if (_liveControlScope != scope || _liveControlProperty != property) {
      _beginLiveControl(scope, property);
    }
    if (_liveControlScope != scope || _liveControlProperty != property) return;
    final alreadySending =
        _liveControlSending &&
        _liveRequestScope == scope &&
        _liveRequestProperty == property &&
        _liveRequestValue == value;
    final alreadyConfirmed =
        !_liveControlSending &&
        (_liveNumericControl(property).value - value).abs() < .000001;
    _liveControlPending = alreadySending || alreadyConfirmed ? null : value;
    _pumpLiveControl();
  }

  Future<void> _finishLiveControl(
    (String?, String?) scope,
    String property,
    double value,
  ) {
    if (!_liveScopeAvailable(scope, property)) return Future.value();
    _queueLiveControl(scope, property, value);
    if (_liveControlScope != scope || _liveControlProperty != property) {
      return Future.value();
    }
    _liveControlDragging = false;
    final completion = Completer<void>();
    _liveControlCompletions.add(completion);
    // Release flushes the newest value as soon as the single active request
    // finishes, without waiting for the drag throttle.
    _liveControlThrottle?.cancel();
    _liveControlThrottle = null;
    _pumpLiveControl();
    if (mounted) setState(() {});
    return completion.future;
  }

  void _pumpLiveControl() {
    if (_liveControlSending) return;
    final scope = _liveControlScope;
    final property = _liveControlProperty;
    if (scope == null || property == null) return;
    if (!_liveScopeAvailable(scope, property)) {
      _cancelLiveControl();
      return;
    }
    if (_service.remoteCameraControls.value.busy) {
      _cancelLiveControl();
      return;
    }
    final value = _liveControlPending;
    if (value == null) {
      if (!_liveControlDragging) _completeLiveControl();
      return;
    }
    if (_liveControlDragging && _liveControlThrottle != null) return;
    _liveControlPending = null;
    _liveControlSending = true;
    _liveRequestScope = scope;
    _liveRequestProperty = property;
    _liveRequestValue = value;
    final epoch = _liveControlEpoch;
    _liveControlThrottle?.cancel();
    _liveControlThrottle = Timer(_liveControlInterval, () {
      _liveControlThrottle = null;
      if (mounted) _pumpLiveControl();
    });
    if (mounted) setState(() {});
    unawaited(_sendLiveControl(scope, property, value, epoch));
  }

  Future<void> _sendLiveControl(
    (String?, String?) scope,
    String property,
    double value,
    int epoch,
  ) async {
    try {
      if (!_liveScopeAvailable(scope, property)) return;
      if (property == 'zoom') {
        await _service.setRemoteCameraZoom(value);
      } else {
        await _service.setRemoteCameraWhiteBalanceWarmth(value);
      }
      if (mounted && epoch == _liveControlEpoch) {
        _remoteControlError = null;
      }
    } catch (error) {
      _logger.warn('Could not adjust live camera control: $error');
      if (mounted && epoch == _liveControlEpoch) {
        _remoteControlError = 'captureFailed';
      }
    } finally {
      _liveControlSending = false;
      _liveRequestScope = null;
      _liveRequestProperty = null;
      _liveRequestValue = null;
      if (mounted) {
        setState(() {});
        _pumpLiveControl();
      }
    }
  }

  Widget _videoSurface(BuildContext context) {
    final l10n = context.l10n;
    return Stack(
      key: const ValueKey('camera-viewer-video'),
      fit: StackFit.expand,
      children: [
        if (_desktop)
          ValueListenableBuilder<bool>(
            valueListenable: _service.remotePreviewEnabled,
            builder: (context, enabled, _) => enabled
                ? _cameraImage()
                : Center(
                    key: const ValueKey('camera-viewer-preview-hidden'),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.visibility_off_rounded,
                          color: Colors.white54,
                          size: 32,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          l10n.cameraViewerText('previewHidden'),
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
          )
        else
          _cameraImage(),
        if (_desktop)
          AnimatedBuilder(
            animation: _photoFlashOpacity,
            builder: (context, _) =>
                !_service.remotePreviewEnabled.value ||
                    _photoFlashOpacity.value <= 0
                ? const SizedBox.shrink()
                : IgnorePointer(
                    child: ExcludeSemantics(
                      child: ColoredBox(
                        key: const ValueKey('camera-photo-flash'),
                        color: Colors.white.withValues(
                          alpha: _photoFlashOpacity.value,
                        ),
                      ),
                    ),
                  ),
          ),
        ValueListenableBuilder<ScreenShareState>(
          valueListenable: _service.state,
          builder: (context, state, _) {
            final failed = _failed || state.error != null;
            final connecting = _opening || state.awaitingVideo;
            final ended = !_opening && state.mode != ScreenShareMode.watching;
            if (!failed && !ended && !connecting) {
              return const SizedBox.shrink();
            }
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (connecting && !failed)
                      const CircularProgressIndicator(color: Colors.white)
                    else
                      const Icon(
                        Icons.portable_wifi_off_rounded,
                        color: Colors.white,
                        size: 40,
                      ),
                    const SizedBox(height: 16),
                    Text(
                      state.failure != null
                          ? l10n.videoConnectionError(state)
                          : l10n.cameraViewerText(
                              failed
                                  ? 'failed'
                                  : connecting
                                  ? 'connecting'
                                  : 'ended',
                            ),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 18),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _cameraImage() => Transform.flip(
    key: const ValueKey('camera-viewer-video-mirror'),
    flipX: _desktop && _mirrorView,
    child: OrientationAwareVideoView(renderer: _service.remoteRenderer),
  );

  void _onPreviewChanged() {
    if (!_service.remotePreviewEnabled.value) _photoFlash.reset();
    if (mounted) setState(() {});
  }

  void _showPhotoFlash() {
    if (!mounted ||
        !_healthy ||
        !_service.remotePreviewEnabled.value ||
        MediaQuery.disableAnimationsOf(context)) {
      return;
    }
    _photoFlash.forward(from: 0);
  }

  Future<void> _changePreview(bool enabled) async {
    if (_previewBusy || _closing != null) return;
    setState(() {
      _previewBusy = true;
      _mediaError = null;
    });
    try {
      await _service.setRemotePreviewEnabled(enabled);
    } catch (error) {
      _logger.warn(
        'Could not change local camera preview: ${error.runtimeType}',
      );
      if (mounted) setState(() => _mediaError = 'previewFailed');
    } finally {
      if (mounted) setState(() => _previewBusy = false);
    }
  }

  Future<void> _runMediaAction(
    String action,
    Future<void> Function() operation,
  ) async {
    if (_mediaAction != null || _closing != null) return;
    setState(() {
      _mediaAction = action;
      _mediaError = null;
    });
    try {
      await operation();
    } catch (error) {
      _logger.warn(
        'Could not perform local camera media action: ${error.runtimeType}',
      );
      if (mounted) {
        setState(
          () =>
              _mediaError = action == 'folder' ? 'folderFailed' : 'mediaFailed',
        );
      }
    } finally {
      if (mounted) setState(() => _mediaAction = null);
    }
  }

  Future<void> _chooseMediaDirectory(
    CameraMediaService media, {
    required bool photo,
  }) async {
    final state = media.state.value;
    final initialDirectory = await cameraMediaPickerDirectory(
      photo ? state.photoDirectory : state.videoDirectory,
    );
    if (!mounted || _closing != null) return;
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: context.l10n.cameraViewerText(
        photo ? 'photosFolder' : 'videosFolder',
      ),
      initialDirectory: initialDirectory,
      lockParentWindow: true,
    );
    if (path == null || !mounted || _closing != null) return;
    if (photo) {
      await media.setPhotoDirectory(path);
    } else {
      await media.setVideoDirectory(path);
    }
  }

  Widget _desktopViewer(BuildContext context) {
    final media = ref.watch(cameraMediaServiceProvider);
    return ValueListenableBuilder<CameraMediaState>(
      valueListenable: media.state,
      builder: (context, capture, _) => LayoutBuilder(
        builder: (context, constraints) {
          final leftWidth = constraints.maxWidth >= 1100 ? 260.0 : 200.0;
          final rightWidth = constraints.maxWidth >= 720 ? 280.0 : 216.0;
          final minimumWidth = leftWidth + rightWidth + 240;
          final enabled =
              _closing == null && _mediaAction == null && !capture.busy;
          final error = _mediaError ?? capture.error;
          final content = SizedBox(
            width: math.max(constraints.maxWidth, minimumWidth),
            height: constraints.maxHeight,
            child: Row(
              children: [
                SizedBox(
                  width: leftWidth,
                  child: CameraMediaActionsPanel(
                    previewEnabled: _service.remotePreviewEnabled.value,
                    previewBusy: _previewBusy,
                    onPreviewChanged: _closing == null ? _changePreview : null,
                    initializing:
                        capture.busy &&
                        capture.photoDirectory == null &&
                        capture.videoDirectory == null,
                    supported: capture.supported,
                    streamReady: capture.ready,
                    takingPhoto: _mediaAction == 'photo' && capture.busy,
                    startingRecording: _mediaAction == 'record' && capture.busy,
                    recording: capture.recording,
                    savingVideo:
                        capture.busy &&
                        capture.recording &&
                        _mediaAction != 'photo',
                    elapsed: capture.elapsed,
                    photoDirectory: capture.photoDirectory,
                    videoDirectory: capture.videoDirectory,
                    lastSavedPath: capture.lastSavedPath,
                    errorMessage: error == null
                        ? null
                        : context.l10n.cameraViewerText(error),
                    onChoosePhotoFolder: enabled
                        ? () => _runMediaAction(
                            'folder',
                            () => _chooseMediaDirectory(media, photo: true),
                          )
                        : null,
                    onChooseVideoFolder: enabled && !capture.recording
                        ? () => _runMediaAction(
                            'folder',
                            () => _chooseMediaDirectory(media, photo: false),
                          )
                        : null,
                    onTakePhoto: enabled && capture.ready
                        ? () => _runMediaAction('photo', () async {
                            await media.takePhoto();
                            _showPhotoFlash();
                          })
                        : null,
                    onToggleRecording:
                        enabled && (capture.recording || capture.ready)
                        ? () => _runMediaAction(
                            capture.recording ? 'stop' : 'record',
                            () async {
                              if (capture.recording) {
                                await media.stopRecording();
                              } else {
                                await media.startRecording();
                              }
                            },
                          )
                        : null,
                  ),
                ),
                Expanded(child: _videoSurface(context)),
                SizedBox(width: rightWidth, child: _desktopPanel(context)),
              ],
            ),
          );
          if (constraints.maxWidth >= minimumWidth) return content;
          return Scrollbar(
            controller: _desktopHorizontalScroll,
            thumbVisibility: true,
            trackVisibility: true,
            scrollbarOrientation: ScrollbarOrientation.bottom,
            child: SingleChildScrollView(
              key: const ValueKey('camera-viewer-panels-scroll'),
              controller: _desktopHorizontalScroll,
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: content,
            ),
          );
        },
      ),
    );
  }

  List<Widget> _captureAdjustments(
    BuildContext context,
    CameraCaptureControls capture, {
    required bool enabled,
    required bool liveAvailable,
  }) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scope = _captureScope(capture);
    bool liveEnabled(String property) =>
        liveAvailable &&
        !_remoteControlBusy &&
        (!_liveControlActive || _liveControlProperty == property) &&
        (!_liveControlSending ||
            (_liveRequestProperty == property && _liveRequestScope == scope)) &&
        (!_service.remoteCameraControls.value.busy ||
            (_liveControlSending &&
                _liveRequestProperty == property &&
                _liveRequestScope == scope));
    if (!capture.available) {
      return [
        const SizedBox(height: 16),
        Text(
          l10n.cameraViewerText('captureUnavailable'),
          key: const ValueKey('camera-viewer-adjustments-unavailable'),
          style: theme.textTheme.bodySmall,
        ),
      ];
    }
    final currentCamera = capture.cameras
        .where((camera) => camera.id == capture.cameraId)
        .firstOrNull;
    final lenses = currentCamera == null
        ? const <CameraControlDevice>[]
        : capture.cameras
              .where(
                (camera) => camera.frontFacing == currentCamera.frontFacing,
              )
              .toList(growable: false);
    final brightness = capture.brightness.supported
        ? capture.brightness
        : capture.exposure;
    final manual = capture.manualExposure;
    final automaticExposure = manual.mode != 'manual';

    Widget unsupported(String label, String description, String key) => Padding(
      key: ValueKey(key),
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(description, style: theme.textTheme.bodySmall),
        ],
      ),
    );

    Widget numericControl({
      required String key,
      required String label,
      required CameraNumericControl control,
      required String unsupportedKey,
      required String Function(double) format,
      required Future<void> Function(double) change,
      bool active = true,
      String? help,
      String? liveProperty,
      String? minimumLabel,
      String? maximumLabel,
    }) => control.supported
        ? _RemoteCameraSlider(
            key: ValueKey('$key-${scope.$1}-${scope.$2}'),
            sliderKey: ValueKey(key),
            label: label,
            value: control.value,
            minimum: control.min,
            maximum: control.max,
            step: control.step,
            format: format,
            enabled:
                (liveProperty == null ? enabled : liveEnabled(liveProperty)) &&
                active,
            help: help,
            minimumLabel: minimumLabel,
            maximumLabel: maximumLabel,
            retainDraftUntilCommitted: liveProperty != null,
            onInteractionStart: liveProperty == null
                ? null
                : () => _beginLiveControl(scope, liveProperty),
            onPreview: liveProperty == null
                ? null
                : (value) => _queueLiveControl(scope, liveProperty, value),
            onCommit: (value) => liveProperty == null
                ? _runRemoteControl(() => change(value), 'captureFailed')
                : _finishLiveControl(scope, liveProperty, value),
          )
        : unsupported(
            label,
            l10n.cameraViewerText(unsupportedKey),
            '$key-unsupported',
          );

    return [
      if (lenses.length > 1) ...[
        const SizedBox(height: 16),
        _RemoteCameraChoice(
          key: ValueKey('camera-viewer-lens-${capture.cameraId}'),
          dropdownKey: const ValueKey('camera-viewer-lens'),
          value: capture.cameraId,
          decoration: InputDecoration(
            labelText: l10n.cameraViewerText('lens'),
            border: const OutlineInputBorder(),
          ),
          items: [
            for (final lens in lenses)
              DropdownMenuItem(
                value: lens.id,
                child: Tooltip(
                  message: lens.label,
                  child: Text(lens.label, overflow: TextOverflow.ellipsis),
                ),
              ),
          ],
          onChanged: enabled
              ? (value) {
                  if (value == null || value == capture.cameraId) return;
                  unawaited(
                    _runRemoteControl(
                      () => _service.selectRemoteCamera(value),
                      'captureFailed',
                    ),
                  );
                }
              : null,
        ),
      ],
      numericControl(
        key: 'camera-viewer-zoom',
        label: l10n.cameraViewerText('cameraZoom'),
        control: capture.zoom,
        unsupportedKey: 'zoomUnsupported',
        format: (value) => '${value.toStringAsFixed(2)}×',
        change: _service.setRemoteCameraZoom,
        liveProperty: 'zoom',
        help: l10n.cameraViewerText('cameraZoomHelp'),
      ),
      const SizedBox(height: 16),
      if (capture.whiteBalanceWarmth.supported) ...[
        SwitchListTile(
          key: const ValueKey('camera-viewer-white-balance-auto'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.cameraViewerText('whiteBalanceAuto')),
          value: capture.whiteBalanceWarmth.mode == 'auto',
          onChanged: enabled
              ? (automatic) => _runRemoteControl(
                  () => automatic
                      ? _service.setRemoteCameraWhiteBalance('auto')
                      : _service.setRemoteCameraWhiteBalanceWarmth(
                          capture.whiteBalanceWarmth.value,
                        ),
                  'captureFailed',
                )
              : null,
        ),
        numericControl(
          key: 'camera-viewer-white-balance-warmth',
          label: l10n.cameraViewerText('whiteBalance'),
          control: capture.whiteBalanceWarmth,
          unsupportedKey: 'whiteBalanceUnsupported',
          format: (value) => value.abs() < .005
              ? l10n.cameraViewerText('neutral')
              : '${(value * 100).round()}%',
          change: _service.setRemoteCameraWhiteBalanceWarmth,
          liveProperty: 'whiteBalanceWarmth',
          minimumLabel: l10n.cameraViewerText('cool'),
          maximumLabel: l10n.cameraViewerText('warm'),
          help: l10n.cameraViewerText('whiteBalanceWarmthHelp'),
        ),
      ] else if (capture.whiteBalance.supported)
        _RemoteCameraChoice(
          key: ValueKey(
            'camera-viewer-white-balance-${capture.cameraId}-${capture.whiteBalance.value}',
          ),
          dropdownKey: const ValueKey('camera-viewer-white-balance'),
          value: capture.whiteBalance.modes.contains(capture.whiteBalance.value)
              ? capture.whiteBalance.value
              : null,
          decoration: InputDecoration(
            labelText: l10n.cameraViewerText('whiteBalance'),
            border: const OutlineInputBorder(),
          ),
          items: [
            for (final mode in capture.whiteBalance.modes)
              DropdownMenuItem(
                value: mode,
                child: Text(
                  l10n.cameraWhiteBalanceName(mode),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: enabled && capture.whiteBalance.modes.length > 1
              ? (value) {
                  if (value == null || value == capture.whiteBalance.value) {
                    return;
                  }
                  unawaited(
                    _runRemoteControl(
                      () => _service.setRemoteCameraWhiteBalance(value),
                      'captureFailed',
                    ),
                  );
                }
              : null,
        )
      else
        unsupported(
          l10n.cameraViewerText('whiteBalance'),
          l10n.cameraViewerText('whiteBalanceUnsupported'),
          'camera-viewer-white-balance-unsupported',
        ),
      numericControl(
        key: 'camera-viewer-brightness',
        label: l10n.cameraViewerText(
          capture.brightness.supported ? 'brightness' : 'brightnessEv',
        ),
        control: brightness,
        unsupportedKey: 'brightnessUnsupported',
        format: (value) => capture.brightness.supported
            ? value.toStringAsFixed(2)
            : '${value > 0 ? '+' : ''}${value.toStringAsFixed(2)} EV',
        change: capture.brightness.supported
            ? _service.setRemoteCameraBrightness
            : _service.setRemoteCameraExposure,
        active: capture.brightness.supported || automaticExposure,
        help: capture.brightness.supported
            ? null
            : l10n.cameraViewerText(
                automaticExposure ? 'brightnessEvHelp' : 'brightnessManualHelp',
              ),
      ),
      const SizedBox(height: 16),
      if (manual.supported) ...[
        _RemoteCameraChoice(
          key: ValueKey(
            'camera-viewer-exposure-mode-${capture.cameraId}-${manual.mode}',
          ),
          dropdownKey: const ValueKey('camera-viewer-exposure-mode'),
          value: manual.mode,
          decoration: InputDecoration(
            labelText: l10n.cameraViewerText('exposure'),
            border: const OutlineInputBorder(),
          ),
          items: [
            for (final mode in const ['auto', 'manual'])
              DropdownMenuItem(
                value: mode,
                child: Text(l10n.cameraViewerText('exposure-$mode')),
              ),
          ],
          onChanged: enabled
              ? (value) {
                  if (value == null || value == manual.mode) return;
                  unawaited(
                    _runRemoteControl(
                      () => _service.setRemoteCameraExposureMode(value),
                      'captureFailed',
                    ),
                  );
                }
              : null,
        ),
        if (!automaticExposure) ...[
          _RemoteCameraSlider(
            key: ValueKey('camera-viewer-shutter-${capture.cameraId}'),
            sliderKey: const ValueKey('camera-viewer-shutter'),
            label: l10n.cameraViewerText('shutterTime'),
            value: manual.timeMs,
            minimum: manual.timeMinMs,
            maximum: manual.timeMaxMs,
            logarithmic: true,
            format: (value) => '${value.toStringAsFixed(value < 1 ? 3 : 1)} ms',
            enabled: enabled,
            onCommit: (value) => _runRemoteControl(
              () => _service.setRemoteCameraExposureTime(value),
              'captureFailed',
            ),
          ),
          _RemoteCameraSlider(
            key: ValueKey('camera-viewer-iso-${capture.cameraId}'),
            sliderKey: const ValueKey('camera-viewer-iso'),
            label: 'ISO',
            value: manual.iso.toDouble(),
            minimum: manual.isoMin.toDouble(),
            maximum: manual.isoMax.toDouble(),
            step: 1,
            format: (value) => value.round().toString(),
            enabled: enabled,
            onCommit: (value) => _runRemoteControl(
              () => _service.setRemoteCameraIso(value.round()),
              'captureFailed',
            ),
          ),
        ],
      ] else
        unsupported(
          l10n.cameraViewerText('exposure'),
          l10n.cameraViewerText('manualExposureUnsupported'),
          'camera-viewer-exposure-unsupported',
        ),
      const SizedBox(height: 20),
      const Divider(),
      const SizedBox(height: 8),
    ];
  }

  Widget _desktopPanel(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Material(
      key: const ValueKey('camera-viewer-menu'),
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: ValueListenableBuilder<ScreenShareState>(
          valueListenable: _service.state,
          builder: (context, state, _) =>
              ValueListenableBuilder<RemoteCameraControls>(
                valueListenable: _service.remoteCameraControls,
                builder: (context, controls, _) {
                  final available =
                      !_opening &&
                      !_failed &&
                      _closing == null &&
                      state.mode == ScreenShareMode.watching &&
                      state.error == null &&
                      controls.available;
                  final busy =
                      _remoteControlBusy || controls.busy || _liveControlActive;
                  final enabled = available && !busy;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
                        child: Row(
                          children: [
                            IconButton(
                              key: const ValueKey('camera-viewer-close'),
                              tooltip: l10n.cameraViewerText('closeViewer'),
                              onPressed: _closing == null ? _close : null,
                              icon: const Icon(Icons.arrow_back_rounded),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                l10n.cameraViewerText('controls'),
                                style: theme.textTheme.titleMedium,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: SingleChildScrollView(
                          key: const ValueKey('camera-viewer-menu-scroll'),
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              OutlinedButton.icon(
                                key: const ValueKey('camera-viewer-switch'),
                                onPressed: enabled && controls.canSwitchCamera
                                    ? () => _runRemoteControl(
                                        _service.switchRemoteCamera,
                                        'cameraSwitchFailed',
                                      )
                                    : null,
                                icon: const Icon(Icons.cameraswitch_rounded),
                                label: Text(l10n.cameraUiText('switchCamera')),
                              ),
                              const SizedBox(height: 8),
                              Tooltip(
                                message: l10n.cameraViewerText(
                                  'mirrorViewHelp',
                                ),
                                child: SwitchListTile(
                                  key: const ValueKey('camera-viewer-mirror'),
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(l10n.cameraViewerText('mirror')),
                                  secondary: const Icon(Icons.flip_rounded),
                                  value: _mirrorView,
                                  onChanged: _closing == null
                                      ? (mirror) =>
                                            setState(() => _mirrorView = mirror)
                                      : null,
                                ),
                              ),
                              if (controls.available)
                                ..._captureAdjustments(
                                  context,
                                  controls.capture,
                                  enabled: enabled,
                                  liveAvailable: available,
                                ),
                              const SizedBox(height: 12),
                              SwitchListTile(
                                key: const ValueKey('camera-viewer-microphone'),
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  l10n.cameraViewerText('microphone'),
                                ),
                                secondary: Icon(
                                  controls.microphoneEnabled
                                      ? Icons.mic_rounded
                                      : Icons.mic_off_rounded,
                                ),
                                value: controls.microphoneEnabled,
                                onChanged: enabled
                                    ? (value) => _runRemoteControl(
                                        () => _service
                                            .setRemoteCameraMicrophoneEnabled(
                                              value,
                                            ),
                                        'cameraMicrophoneFailed',
                                      )
                                    : null,
                              ),
                              if (controls.torchAvailable) ...[
                                const SizedBox(height: 12),
                                SwitchListTile(
                                  key: const ValueKey('camera-viewer-torch'),
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(l10n.cameraViewerText('flash')),
                                  secondary: Icon(
                                    controls.torchEnabled
                                        ? Icons.flash_on_rounded
                                        : Icons.flash_off_rounded,
                                  ),
                                  value: controls.torchEnabled,
                                  onChanged: enabled
                                      ? (value) => _runRemoteControl(
                                          () => _service
                                              .setRemoteCameraTorchEnabled(
                                                value,
                                              ),
                                          'cameraTorchFailed',
                                        )
                                      : null,
                                ),
                              ],
                              if (busy) ...[
                                const SizedBox(height: 16),
                                const LinearProgressIndicator(),
                              ],
                              if (!controls.available && !_opening) ...[
                                const SizedBox(height: 16),
                                Text(
                                  l10n.cameraViewerText(
                                    state.mode == ScreenShareMode.watching
                                        ? 'controlsUnavailable'
                                        : 'notConnected',
                                  ),
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                              if (_remoteControlError case final error?) ...[
                                const SizedBox(height: 16),
                                Semantics(
                                  liveRegion: true,
                                  child: Text(
                                    error == 'stopFailed' ||
                                            error == 'captureFailed' ||
                                            error == 'microphonePermission'
                                        ? l10n.cameraViewerText(error)
                                        : l10n.cameraUiText(error),
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.error,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: FilledButton.icon(
                          key: const ValueKey('camera-viewer-stop-sharing'),
                          onPressed: enabled ? _stopRemoteSharing : null,
                          style: FilledButton.styleFrom(
                            backgroundColor: theme.colorScheme.error,
                            foregroundColor: theme.colorScheme.onError,
                          ),
                          icon: const Icon(Icons.stop_rounded),
                          label: Text(l10n.cameraViewerText('stopSharing')),
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
          body: _desktop
              ? _desktopViewer(context)
              : Focus(
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
                          _videoSurface(context),
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

/// The selected item is controlled by the confirmed device state, including
/// while a command is pending or fails.
class _RemoteCameraChoice extends StatelessWidget {
  const _RemoteCameraChoice({
    super.key,
    required this.dropdownKey,
    required this.value,
    required this.decoration,
    required this.items,
    required this.onChanged,
  });

  final Key dropdownKey;
  final String? value;
  final InputDecoration decoration;
  final List<DropdownMenuItem<String>> items;
  final ValueChanged<String?>? onChanged;

  @override
  Widget build(BuildContext context) => InputDecorator(
    decoration: decoration.copyWith(enabled: onChanged != null),
    isEmpty: value == null,
    child: DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        key: dropdownKey,
        value: value,
        isExpanded: true,
        isDense: true,
        items: items,
        onChanged: onChanged,
      ),
    ),
  );
}

/// Controls can submit a coalesced live preview or commit only on release.
/// A gesture keeps its draft thumb stable while native acknowledgements arrive.
class _RemoteCameraSlider extends StatefulWidget {
  const _RemoteCameraSlider({
    super.key,
    required this.sliderKey,
    required this.label,
    required this.value,
    required this.minimum,
    required this.maximum,
    required this.format,
    required this.enabled,
    required this.onCommit,
    this.step = 0,
    this.logarithmic = false,
    this.help,
    this.minimumLabel,
    this.maximumLabel,
    this.onInteractionStart,
    this.onPreview,
    this.retainDraftUntilCommitted = false,
  });

  final Key sliderKey;
  final String label;
  final double value;
  final double minimum;
  final double maximum;
  final double step;
  final bool logarithmic;
  final bool enabled;
  final String? help;
  final String? minimumLabel;
  final String? maximumLabel;
  final VoidCallback? onInteractionStart;
  final ValueChanged<double>? onPreview;
  final bool retainDraftUntilCommitted;
  final String Function(double) format;
  final Future<void> Function(double) onCommit;

  @override
  State<_RemoteCameraSlider> createState() => _RemoteCameraSliderState();
}

class _RemoteCameraSliderState extends State<_RemoteCameraSlider> {
  double? _draft;
  bool _dragging = false;
  int _draftGeneration = 0;

  double _position(double value) =>
      widget.logarithmic ? math.log(value) : value;
  double _value(double position) {
    var value = widget.logarithmic ? math.exp(position) : position;
    if (widget.step > 0) {
      value =
          widget.minimum +
          ((value - widget.minimum) / widget.step).round() * widget.step;
    }
    return value.clamp(widget.minimum, widget.maximum);
  }

  @override
  void didUpdateWidget(covariant _RemoteCameraSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled ||
        oldWidget.minimum != widget.minimum ||
        oldWidget.maximum != widget.maximum) {
      _draft = null;
      _dragging = false;
      _draftGeneration++;
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = (_draft ?? widget.value).clamp(
      widget.minimum,
      widget.maximum,
    );
    final steps = widget.step > 0
        ? ((widget.maximum - widget.minimum) / widget.step).round()
        : 0;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Text(widget.label, style: Theme.of(context).textTheme.labelLarge),
              Text(widget.format(value)),
            ],
          ),
          Slider(
            key: widget.sliderKey,
            value: _position(value),
            min: _position(widget.minimum),
            max: _position(widget.maximum),
            divisions: !widget.logarithmic && steps > 0 && steps <= 100
                ? steps
                : null,
            label: widget.format(value),
            semanticFormatterCallback: (position) =>
                widget.format(_value(position)),
            onChangeStart: widget.enabled
                ? (_) {
                    if (!mounted || !widget.enabled) return;
                    _dragging = true;
                    _draftGeneration++;
                    widget.onInteractionStart?.call();
                  }
                : null,
            onChanged: widget.enabled
                ? (position) {
                    if (!mounted || !widget.enabled) return;
                    if (!_dragging) {
                      _dragging = true;
                      _draftGeneration++;
                      widget.onInteractionStart?.call();
                    }
                    final value = _value(position);
                    setState(() => _draft = value);
                    widget.onPreview?.call(value);
                  }
                : null,
            onChangeEnd: widget.enabled
                ? (position) {
                    if (!mounted || !widget.enabled) return;
                    final committed = _value(position);
                    _dragging = false;
                    if (!widget.retainDraftUntilCommitted) {
                      setState(() => _draft = null);
                      unawaited(widget.onCommit(committed));
                      return;
                    }
                    final generation = _draftGeneration;
                    setState(() => _draft = committed);
                    unawaited(() async {
                      try {
                        await widget.onCommit(committed);
                      } finally {
                        if (mounted &&
                            !_dragging &&
                            generation == _draftGeneration) {
                          setState(() => _draft = null);
                        }
                      }
                    }());
                  }
                : null,
          ),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 12,
            runSpacing: 4,
            children: [
              Text(
                widget.minimumLabel ?? widget.format(widget.minimum),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                widget.maximumLabel ?? widget.format(widget.maximum),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          if (widget.help case final help?) ...[
            const SizedBox(height: 4),
            Text(help, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}
