import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bshare/src/domain/entities/camera_device.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/domain/entities/screen_capture_settings.dart';
import 'package:bshare/src/infrastructure/services/android_camera_execution_service.dart';
import 'package:bshare/src/infrastructure/services/android_screen_share_execution_service.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/camera_capture_lifecycle_gate.dart';
import 'package:bshare/src/infrastructure/services/file_server.dart';
import 'package:bshare/src/infrastructure/services/permission_request_coordinator.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

enum ScreenShareMode { idle, sharing, watching }

enum VideoShareSource { screen, camera }

class ScreenShareState {
  const ScreenShareState({
    required this.mode,
    this.status = 'Idle',
    this.error,
  });

  final ScreenShareMode mode;
  final String status;
  final String? error;
}

class ScreenShareService with WidgetsBindingObserver {
  ScreenShareService(
    this._logger,
    this._screenShareExecution, {
    Dio? signalingClient,
    RTCVideoRenderer? localRenderer,
    RTCVideoRenderer? remoteRenderer,
    Future<RTCPeerConnection> Function()? peerConnectionFactory,
    AndroidCameraExecutionService? cameraExecution,
    PermissionRequestCoordinator? permissionCoordinator,
    Future<void> Function(bool enabled)? audioRecordingGate,
    this.onSharingStopped,
  }) : _dio =
           signalingClient ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 15),
               receiveTimeout: const Duration(seconds: 20),
             ),
           ),
       localRenderer = localRenderer ?? RTCVideoRenderer(),
       remoteRenderer = remoteRenderer ?? RTCVideoRenderer(),
       _cameraExecution = cameraExecution ?? AndroidCameraExecutionService(),
       _permissions =
           permissionCoordinator ?? PermissionRequestCoordinator.instance,
       _audioRecordingGate =
           audioRecordingGate ?? Helper.setAndroidAudioRecording,
       _peerConnectionFactory = peerConnectionFactory ?? _createLanPeer;

  static const String _screenCodec = 'H264';
  static const Duration _metadataPollInterval = Duration(milliseconds: 500);
  static const Duration _androidForegroundServiceSettleDelay = Duration(
    milliseconds: 650,
  );

  final AppLogger _logger;
  final AndroidScreenShareExecutionService _screenShareExecution;
  final AndroidCameraExecutionService _cameraExecution;
  final PermissionRequestCoordinator _permissions;
  final Future<void> Function(bool enabled) _audioRecordingGate;
  bool _audioRecordingConfigured = false;
  final _cameraLifecycle = CameraCaptureLifecycleGate();
  final Dio _dio;
  Dio? _boundSignalingClient;
  VideoShareSource _source = VideoShareSource.screen;
  VideoShareSource get source => _source;
  String get _endedStatus => _source == VideoShareSource.camera
      ? 'Camera share ended'
      : 'Screen share ended';
  CameraDevice? _currentCamera;
  CameraDevice? get currentCamera => _currentCamera;
  List<String>? _allowedLocalIps;
  Future<void>? _cameraOperations;
  Future<void>? _switchingCamera;
  String? _startingCameraId;
  bool get isSwitchingCamera => _switchingCamera != null;
  final Future<RTCPeerConnection> Function() _peerConnectionFactory;
  final Future<void> Function()? onSharingStopped;
  ScreenCaptureSettings _captureSettings = const ScreenCaptureSettings();
  ScreenCaptureSettings get captureSettings => _captureSettings;
  final Map<RTCPeerConnection, RTCRtpSender> _videoSenders = {};
  final Map<RTCPeerConnection, RTCRtpSender> _cameraAudioSenders = {};
  MediaStream? _cameraAudioStream;
  bool _cameraMicrophoneEnabled = false;
  bool get cameraMicrophoneEnabled => _cameraMicrophoneEnabled;
  bool _cameraTorchEnabled = false;
  bool get cameraTorchEnabled => _cameraTorchEnabled;
  bool _cameraTorchAvailable = false;
  bool get cameraTorchAvailable => _cameraTorchAvailable;
  Completer<void>? _microphoneRequestCancellation;
  Future<void>? _microphoneOperation;
  bool? _requestedMicrophoneEnabled;

  final Expando<Future<void>> _senderUpdates = Expando<Future<void>>();
  final RTCVideoRenderer localRenderer;
  final RTCVideoRenderer remoteRenderer;
  final ValueNotifier<ScreenShareState> state = ValueNotifier(
    const ScreenShareState(mode: ScreenShareMode.idle),
  );
  final ValueNotifier<double?> remoteAspectRatio = ValueNotifier(null);
  final ValueNotifier<bool> focusedViewerActive = ValueNotifier(false);
  final List<RTCPeerConnection> _peers = [];
  final Map<RTCPeerConnection, Timer> _sharingPeerDisconnectTimers = {};

  MediaStream? _localStream;
  RTCPeerConnection? _viewerPeer;
  Timer? _metadataPollTimer;
  Timer? _viewerStatsTimer;
  CancelToken? _viewerRequests;
  Future<void>? _initializing;
  Future<void>? _startingShare;
  Future<void>? _watching;
  DeviceInfo? _watchedDevice;
  Future<void>? _stoppingFuture;
  Future<void>? _disposing;
  final Expando<Future<void>> _closingPeers = Expando<Future<void>>();
  final Map<RTCPeerConnection, void Function()> _iceWaitCancellations = {};
  int _session = 0;
  bool _disposed = false;
  FileServer? _sharingServer;
  bool _observingAndroidMetrics = false;
  int? _lastRemoteGeneration;
  String? _localTrackId;
  double? _localAspectRatio;
  int? _localScreenWidth;
  int? _localScreenHeight;
  ui.Size? _lastAndroidViewSize;
  int _screenGeneration = 0;
  bool _initialized = false;
  bool _reconnectingViewer = false;
  bool _stopping = false;

  void _setState(ScreenShareMode mode, String status, [String? error]) {
    if (_disposed) return;
    state.value = ScreenShareState(mode: mode, status: status, error: error);
  }

  /// Indicates that the compact preview has been replaced by the focused view.
  /// Both views reuse [remoteRenderer], but only one of them is mounted.
  void setFocusedViewerActive(bool active) {
    if (_disposed || focusedViewerActive.value == active) return;
    focusedViewerActive.value = active;
  }

  Future<void> initialize() {
    if (_disposed) return Future.error(StateError('Screen share is disposed'));
    if (_initialized) return Future.value();
    return _initializing ??= _initializeRenderers().whenComplete(() {
      _initializing = null;
    });
  }

  Future<void> _initializeRenderers() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    localRenderer.onResize = () {
      if (_disposed || state.value.mode != ScreenShareMode.sharing) return;
      for (final sender in _videoSenders.values.toList()) {
        unawaited(_configureLowLatencyVideoSender(sender));
      }
    };
    remoteRenderer.onFirstFrameRendered = () {
      final value = remoteRenderer.value;
      _logger.info(
        'Remote screen renderer received its first frame '
        '(${value.width.toInt()}x${value.height.toInt()})',
      );
    };
    remoteRenderer.onResize = () {
      final value = remoteRenderer.value;
      _logger.info(
        'Remote screen renderer size: '
        '${value.width.toInt()}x${value.height.toInt()}',
      );
    };
    _initialized = true;
  }

  Future<List<CameraDevice>> enumerateCameras() async {
    if (_disposed) throw StateError('Video sharing is disposed');
    // The native source list retains facing metadata. enumerateDevices drops
    // that field, leaving only labels that can be localized by the OS.
    // ignore: deprecated_member_use
    final devices = await navigator.mediaDevices.getSources();
    if (_disposed) return [];
    final seen = <String>{};
    final primary = <bool, CameraDevice>{};
    CameraDevice? unspecified;
    for (final device in devices) {
      if (device is! Map || device['kind'] != 'videoinput') continue;
      final id = device['deviceId'];
      if (id is! String || id.isEmpty || !seen.add(id)) continue;
      final facing = (device['facing'] as String? ?? '').toLowerCase();
      final label = (device['label'] as String? ?? '').toLowerCase();
      final front = facing == 'front' || facing == 'user';
      final back = facing == 'back' || facing == 'environment';
      final bool? frontFacing = front
          ? true
          : back
          ? false
          : label.contains('front') || label.contains('user')
          ? true
          : label.contains('back') ||
                label.contains('rear') ||
                label.contains('trasera')
          ? false
          : null;
      final camera = CameraDevice(
        id: id,
        label: frontFacing == true ? 'Front camera' : 'Rear camera',
        frontFacing: frontFacing ?? false,
      );
      if (frontFacing == null) {
        unspecified ??= camera;
      } else {
        // Preserve the SDK's preferred logical camera for each side instead
        // of presenting every ultra-wide, telephoto or virtual sensor.
        primary.putIfAbsent(frontFacing, () => camera);
      }
    }
    // A camera without facing metadata remains usable on desktop/external
    // inputs, without inventing a second camera or replacing a known rear.
    if (unspecified != null) primary.putIfAbsent(false, () => unspecified!);
    return [?primary[false], ?primary[true]];
  }

  Future<void> startSharing(
    FileServer server, {
    ScreenCaptureSettings settings = const ScreenCaptureSettings(),
  }) => _startCapture(server, VideoShareSource.screen, settings);

  Future<void> startCameraSharing(
    FileServer server, {
    required CameraDevice camera,
    ScreenCaptureSettings settings = const ScreenCaptureSettings(),
    List<String>? allowedLocalIps,
    List<String>? allowedRemoteSubnets,
  }) => _startCapture(
    server,
    VideoShareSource.camera,
    settings,
    camera: camera,
    allowedLocalIps: allowedLocalIps,
    allowedRemoteSubnets: allowedRemoteSubnets,
  );

  Future<void> _startCapture(
    FileServer server,
    VideoShareSource source,
    ScreenCaptureSettings settings, {
    CameraDevice? camera,
    List<String>? allowedLocalIps,
    List<String>? allowedRemoteSubnets,
  }) {
    if (_disposed) return Future.error(StateError('Video sharing is disposed'));
    if (_switchingCamera != null) {
      return Future.error(
        StateError('Wait for the active camera switch first'),
      );
    }
    if (_startingShare != null || _localStream != null) {
      if (_source != source ||
          (source == VideoShareSource.camera &&
              (_startingShare != null
                      ? _startingCameraId
                      : _currentCamera?.id) !=
                  camera?.id)) {
        return Future.error(StateError('Stop the active video capture first'));
      }
      return _startingShare ?? Future<void>.value();
    }
    List<String>? allowed;
    try {
      allowed = _validatedLocalIps(allowedLocalIps);
      if (allowed != null &&
          (allowedRemoteSubnets == null || allowedRemoteSubnets.isEmpty)) {
        throw StateError('A USB remote subnet is required');
      }
      for (final subnet in allowedRemoteSubnets ?? const <String>[]) {
        final parts = subnet.split('/');
        final address = InternetAddress.tryParse(parts.first);
        final prefix = parts.length == 2 ? int.tryParse(parts[1]) : null;
        if (address == null ||
            prefix == null ||
            prefix < 0 ||
            prefix > address.rawAddress.length * 8) {
          throw StateError('A valid USB subnet prefix is required');
        }
      }
    } catch (error, stack) {
      return Future.error(error, stack);
    }
    _source = source;
    _currentCamera = camera;
    _startingCameraId = camera?.id;
    return _startingShare ??=
        _startSharing(
          server,
          settings.validated,
          source,
          camera,
          allowed,
          allowedRemoteSubnets == null
              ? null
              : List.unmodifiable(allowedRemoteSubnets),
        ).whenComplete(() {
          _startingShare = null;
          _startingCameraId = null;
        });
  }

  Future<void> _startSharing(
    FileServer server,
    ScreenCaptureSettings settings,
    VideoShareSource source,
    CameraDevice? camera,
    List<String>? allowedLocalIps,
    List<String>? allowedRemoteSubnets,
  ) async {
    final session = ++_session;
    _setState(ScreenShareMode.sharing, 'Starting ${source.name} capture...');
    try {
      await _stop(server, updateState: false, invalidateSession: false);
      _checkSession(session);
      _source = source;
      _currentCamera = camera;
      _allowedLocalIps = allowedLocalIps;
      _captureSettings = settings;
      await initialize();
      _checkSession(session);
      _setState(ScreenShareMode.sharing, 'Starting ${source.name} capture...');
      final MediaStream stream;
      if (source == VideoShareSource.camera) {
        await _prepareCameraCapture(session);
        _checkSession(session);
        stream = await _openCamera(camera!, settings);
      } else {
        await _prepareCapture(session);
        final constraints = await _videoConstraints();
        _checkSession(session);
        stream = await _getDisplayMediaWithForegroundRetry({
          'video': constraints,
          'audio': false,
        }, session);
      }
      if (!_isCurrentSession(session)) {
        await _disposeStream(stream);
        // stop() owns the current execution service; a stale acquisition must
        // only release its stream and must not stop a newer foreground session.
        return;
      }
      await _attachLocalStream(stream, server, session);
      _checkSession(session);
      _sharingServer = server;
      if (source == VideoShareSource.camera) {
        server.cameraOfferHandler = (offer) {
          final offerSession = _session;
          return _withCameraLock(() {
            _checkSession(offerSession);
            return _answerOffer(offer);
          });
        };
        server.cameraMetadataHandler = _screenMetadata;
        server.cameraAllowedRemoteSubnets = allowedRemoteSubnets == null
            ? null
            : List.unmodifiable(allowedRemoteSubnets);
      } else {
        server.screenOfferHandler = _answerOffer;
        server.screenMetadataHandler = _screenMetadata;
        _startAndroidMetricsObserver();
      }
      _screenGeneration++;
      _setState(ScreenShareMode.sharing, 'Sharing ${source.name} on LAN');
    } catch (error) {
      if (!_isCurrentSession(session)) return;
      await _stop(server, updateState: false);
      if (_isCurrentSession(session + 1)) {
        _setState(
          ScreenShareMode.idle,
          'Video share stopped',
          error.toString(),
        );
      }
      rethrow;
    }
  }

  Future<void> _attachLocalStream(
    MediaStream stream,
    FileServer server,
    int session,
  ) async {
    _localStream = stream;
    final videoTrack = stream.getVideoTracks().firstOrNull;
    if (videoTrack == null) {
      throw StateError('Video capture returned no video track');
    }
    _localTrackId = videoTrack.id;
    if (_source == VideoShareSource.camera) {
      final settings = videoTrack.getSettings();
      final width = settings['width'];
      final height = settings['height'];
      if (width is num && height is num) {
        updateLocalScreenMetrics(width.toDouble(), height.toDouble());
      }
    }
    videoTrack.onEnded = () {
      if (_isCurrentSession(session) && _localStream == stream) {
        unawaited(_handleLocalTrackEnded(server));
      }
    };
    await localRenderer.setSrcObject(stream: stream, trackId: videoTrack.id);
    if (_source == VideoShareSource.camera) {
      await _refreshCameraTorch(videoTrack, session);
    }
  }

  Future<void> _prepareCameraCapture(int session) async {
    if (WebRTC.platformIsAndroid) {
      await _cameraLifecycle.waitForForeground();
      _checkSession(session);
    }
    if (WebRTC.platformIsAndroid || WebRTC.platformIsIOS) {
      final status = await _permissions.request(Permission.camera);
      _checkSession(session);
      if (!status.isGranted) throw StateError('Camera permission was denied');
    }
    if (WebRTC.platformIsAndroid) {
      await _cameraLifecycle.waitForForeground();
      _checkSession(session);
      await _cameraExecution.start();
      if (!_isCurrentSession(session)) {
        await _cameraExecution.stop();
        _checkSession(session);
      }
    }
  }

  Future<MediaStream> _openCamera(
    CameraDevice camera,
    ScreenCaptureSettings settings,
  ) {
    final shortSide = settings.resolution;
    return navigator.mediaDevices.getUserMedia({
      'audio': false,
      'video': {
        'deviceId': camera.id,
        'facingMode': camera.frontFacing ? 'user' : 'environment',
        if (shortSide > 0) 'width': (shortSide * 16 / 9).round(),
        if (shortSide > 0) 'height': shortSide,
        'frameRate': settings.frameRate,
      },
    });
  }

  void _notifyCameraControls() {
    final current = state.value;
    _setState(current.mode, current.status, current.error);
  }

  void _requireCameraCapture(int session) {
    _checkSession(session);
    if (_source != VideoShareSource.camera ||
        _localStream == null ||
        _stopping) {
      throw StateError('Camera sharing is not active');
    }
  }

  /// Microphone capture stays separate from the video stream, so replacing a
  /// camera neither interrupts audio nor plays the microphone in the preview.
  /// An audio sender is reserved during signaling even when capture is off.
  Future<void> setCameraMicrophoneEnabled(bool enabled) {
    if (_disposed) return Future.error(StateError('Video sharing is disposed'));
    final session = _session;
    try {
      _requireCameraCapture(session);
    } catch (error, stack) {
      return Future.error(error, stack);
    }
    if (_microphoneOperation != null &&
        _requestedMicrophoneEnabled == enabled) {
      return _microphoneOperation!;
    }
    if (_microphoneOperation == null && _cameraMicrophoneEnabled == enabled) {
      return Future.value();
    }
    final previousRequest = _microphoneRequestCancellation;
    if (previousRequest != null && !previousRequest.isCompleted) {
      previousRequest.complete();
    }
    final cancellation = Completer<void>();
    _microphoneRequestCancellation = cancellation;
    _requestedMicrophoneEnabled = enabled;
    late final Future<void> result;
    result =
        _withCameraLock(() async {
          _requireCameraCapture(session);
          if (cancellation.isCompleted) return;
          if (!enabled) {
            try {
              await _stopCameraMicrophone(reportFailure: true);
            } finally {
              _notifyCameraControls();
            }
            return;
          }
          if (_cameraMicrophoneEnabled) return;
          MediaStream? acquired;
          try {
            if (WebRTC.platformIsAndroid) {
              await _cameraLifecycle.waitForForeground();
              _requireCameraCapture(session);
            }
            if (WebRTC.platformIsAndroid || WebRTC.platformIsIOS) {
              // A Stop or a newer toggle releases this queue immediately; the OS
              // permission result may arrive later but can no longer open capture.
              final permission = await Future.any<PermissionStatus?>([
                _permissions.request(Permission.microphone),
                cancellation.future.then((_) => null),
              ]);
              if (permission == null || cancellation.isCompleted) return;
              _requireCameraCapture(session);
              if (!permission.isGranted) {
                throw StateError('Microphone permission was denied');
              }
            }
            if (WebRTC.platformIsAndroid) {
              await _cameraLifecycle.waitForForeground();
              _requireCameraCapture(session);
              if (cancellation.isCompleted) return;
              await _cameraExecution.setMicrophoneActive(true);
              _requireCameraCapture(session);
            }
            if (cancellation.isCompleted) {
              await _disableMicrophoneExecution();
              return;
            }
            _requireCameraCapture(session);
            if (cancellation.isCompleted) return;
            await _setCameraAudioRecording(true);
            _requireCameraCapture(session);
            if (cancellation.isCompleted) {
              await _stopCameraMicrophone();
              return;
            }
            acquired = await navigator.mediaDevices.getUserMedia({
              'audio': true,
              'video': false,
            });
            if (!_isCurrentSession(session) ||
                _stopping ||
                cancellation.isCompleted) {
              await _disposeStream(acquired);
              acquired = null;
              await _stopCameraMicrophone();
              return;
            }
            final track = acquired.getAudioTracks().firstOrNull;
            if (track == null) {
              throw StateError('Microphone capture returned no audio track');
            }
            _cameraAudioStream = acquired;
            track.onEnded = () {
              if (_isCurrentSession(session) &&
                  _cameraAudioStream == acquired) {
                unawaited(
                  setCameraMicrophoneEnabled(false).catchError((Object e) {
                    _logger.warn('Could not release ended microphone: $e');
                  }),
                );
              }
            };
            for (final entry in _cameraAudioSenders.entries.toList()) {
              if (!_peers.contains(entry.key)) continue;
              await entry.value.replaceTrack(track);
              _requireCameraCapture(session);
              if (cancellation.isCompleted) {
                await _stopCameraMicrophone();
                _notifyCameraControls();
                return;
              }
            }
            _cameraMicrophoneEnabled = true;
            _notifyCameraControls();
          } catch (error, stack) {
            if (acquired != null && _cameraAudioStream != acquired) {
              await _disposeStream(acquired);
            }
            await _stopCameraMicrophone();
            if (_isCurrentSession(session)) _notifyCameraControls();
            Error.throwWithStackTrace(error, stack);
          }
        }).whenComplete(() {
          if (_microphoneOperation == result) {
            _microphoneOperation = null;
            _requestedMicrophoneEnabled = null;
            _microphoneRequestCancellation = null;
          }
        });
    _microphoneOperation = result;
    return result;
  }

  Future<void> _disableMicrophoneExecution() async {
    if (!WebRTC.platformIsAndroid) return;
    try {
      await _cameraExecution.setMicrophoneActive(false);
    } catch (error) {
      _logger.warn('Android microphone foreground stop failed: $error');
    }
  }

  Future<void> _setCameraAudioRecording(bool enabled) async {
    _audioRecordingConfigured = true;
    await _audioRecordingGate(enabled);
  }

  Future<void> _stopCameraAudioRecording() async {
    if (!_audioRecordingConfigured && _source != VideoShareSource.camera) {
      return;
    }
    try {
      await _setCameraAudioRecording(false);
    } catch (error) {
      _logger.warn('Could not disable camera audio recording: $error');
      // Disposing only a local audio track can leave libwebrtc's shared audio
      // device recording while a sendonly channel survives. Closing the peers
      // releases those channels if the native recording gate itself fails.
      await _stopSharingPeers();
      rethrow;
    }
  }

  Future<void> _stopCameraMicrophone({bool reportFailure = false}) async {
    Object? recordingFailure;
    StackTrace? recordingStack;
    try {
      // Stop the shared audio device before detaching senders or tracks. A null
      // sender track alone does not switch off Android's AudioRecord instance.
      await _stopCameraAudioRecording();
    } catch (error, stack) {
      recordingFailure = error;
      recordingStack = stack;
    }
    _cameraMicrophoneEnabled = false;
    final stream = _cameraAudioStream;
    _cameraAudioStream = null;
    for (final entry in _cameraAudioSenders.entries.toList()) {
      if (!_peers.contains(entry.key)) continue;
      try {
        await entry.value.replaceTrack(null);
      } catch (error) {
        _logger.warn('Could not detach camera microphone sender: $error');
      }
    }
    if (stream != null) await _disposeStream(stream);
    await _disableMicrophoneExecution();
    if (reportFailure && recordingFailure != null) {
      Error.throwWithStackTrace(recordingFailure, recordingStack!);
    }
  }

  Future<void> _refreshCameraTorch(MediaStreamTrack track, int session) async {
    var available = false;
    try {
      available = await track.hasTorch();
    } catch (error) {
      _logger.info('Camera torch is unavailable: $error');
    }
    _checkSession(session);
    _cameraTorchEnabled = false;
    _cameraTorchAvailable = available;
  }

  Future<void> setCameraTorchEnabled(bool enabled) {
    if (_disposed) return Future.error(StateError('Video sharing is disposed'));
    final session = _session;
    return _withCameraLock(() async {
      _requireCameraCapture(session);
      if (_cameraTorchEnabled == enabled) return;
      if (enabled && !_cameraTorchAvailable) {
        throw StateError('Flash is not available on this camera');
      }
      final track = _localStream!.getVideoTracks().first;
      await track.setTorch(enabled);
      _requireCameraCapture(session);
      _cameraTorchEnabled = enabled;
      _notifyCameraControls();
    });
  }

  Future<void> _resetCameraTorch(MediaStream? stream) async {
    final enabled = _cameraTorchEnabled;
    _cameraTorchEnabled = false;
    _cameraTorchAvailable = false;
    if (!enabled) return;
    final track = stream?.getVideoTracks().firstOrNull;
    if (track == null) return;
    try {
      await track.setTorch(false);
    } catch (error) {
      // Releasing the capturer immediately afterwards also releases its torch.
      _logger.warn('Could not reset camera flash before release: $error');
    }
  }

  void _cancelCameraControls() {
    final microphone = _microphoneRequestCancellation;
    if (microphone != null && !microphone.isCompleted) microphone.complete();
  }

  Future<T> _withCameraLock<T>(Future<T> Function() action) {
    final previous = _cameraOperations;
    final operation = previous == null
        ? Future<T>.sync(action)
        : previous.then((_) => action());
    late final Future<void> settled;
    void clear() {
      if (identical(_cameraOperations, settled)) _cameraOperations = null;
    }

    settled = operation.then<void>(
      (_) => clear(),
      onError: (Object error, StackTrace stack) => clear(),
    );
    _cameraOperations = settled;
    return operation;
  }

  Future<void> switchCamera(
    CameraDevice camera, {
    required ScreenCaptureSettings settings,
  }) {
    if (_disposed) return Future.error(StateError('Video sharing is disposed'));
    if (_source != VideoShareSource.camera) {
      return Future.error(StateError('Camera sharing is not active'));
    }
    if (_switchingCamera != null) return _switchingCamera!;
    if (_localStream == null || _stopping) {
      return Future.error(StateError('Camera sharing is not active'));
    }
    final options = settings.validated;
    if (_currentCamera?.id == camera.id &&
        _captureSettings.resolution == options.resolution &&
        _captureSettings.frameRate == options.frameRate) {
      return Future<void>.value();
    }
    final session = _session;
    // Never open two camera sessions at once: release the old capturer first,
    // then replace the sender track without renegotiating or recreating peers.
    final operation = _withCameraLock(() async {
      _checkSession(session);
      final previousCamera = _currentCamera!;
      final previousSettings = _captureSettings;
      try {
        await _replaceCamera(camera, options, session);
      } catch (error, stack) {
        if (!_isCurrentSession(session)) return;
        try {
          await _replaceCamera(previousCamera, previousSettings, session);
        } catch (rollbackError) {
          _logger.warn('Camera rollback failed: $rollbackError');
          rethrow;
        }
        Error.throwWithStackTrace(error, stack);
      }
    });
    final result = operation
        .whenComplete(() {
          _switchingCamera = null;
          if (_isCurrentSession(session) && _localStream != null) {
            _setState(ScreenShareMode.sharing, 'Sharing camera on LAN');
          }
        })
        .catchError((Object error, StackTrace stack) async {
          if (_isCurrentSession(session) && _localStream == null) {
            final server = _sharingServer;
            if (server != null) {
              await stop(server, status: 'Camera share stopped');
            }
          }
          Error.throwWithStackTrace(error, stack);
        });
    _switchingCamera = result;
    _setState(ScreenShareMode.sharing, 'Switching camera...');
    return result;
  }

  Future<void> _replaceCamera(
    CameraDevice camera,
    ScreenCaptureSettings settings,
    int session,
  ) async {
    _checkSession(session);
    await _stopLocalStream();
    _checkSession(session);
    final stream = await _openCamera(camera, settings);
    if (!_isCurrentSession(session)) {
      await _disposeStream(stream);
      return;
    }
    final track = stream.getVideoTracks().firstOrNull;
    if (track == null) {
      await _disposeStream(stream);
      throw StateError('The camera returned no video track');
    }
    _captureSettings = settings;
    _currentCamera = camera;
    try {
      for (final entry in _videoSenders.entries.toList()) {
        if (!_peers.contains(entry.key)) continue;
        await entry.value.replaceTrack(track);
        _checkSession(session);
      }
      await _attachLocalStream(stream, _sharingServer!, session);
      _checkSession(session);
      for (final sender in _videoSenders.values.toList()) {
        await _configureLowLatencyVideoSender(sender);
      }
    } catch (_) {
      if (_localStream == stream) _localStream = null;
      await _disposeStream(stream);
      rethrow;
    }
  }

  bool _isCurrentSession(int session) => !_disposed && _session == session;

  void _checkSession(int session) {
    if (!_isCurrentSession(session)) throw StateError('Screen session ended');
  }

  Future<void> _handleLocalTrackEnded(FileServer server) async {
    if (_localStream == null || _stopping) return;
    _logger.info('Local screen-share track ended');
    await stop(server, status: _endedStatus);
  }

  Future<MediaStream> _getDisplayMediaWithForegroundRetry(
    Map<String, dynamic> constraints,
    int session,
  ) async {
    try {
      return await navigator.mediaDevices.getDisplayMedia(constraints);
    } catch (error) {
      if (!WebRTC.platformIsAndroid ||
          !_isMediaProjectionForegroundError(error)) {
        rethrow;
      }
      _logger.warn(
        'Screen capture needs mediaProjection foreground service; retrying',
      );
      _checkSession(session);
      await _restartAndroidScreenShareExecution();
      _checkSession(session);
      return navigator.mediaDevices.getDisplayMedia(constraints);
    }
  }

  bool _isMediaProjectionForegroundError(Object error) {
    final message = error.toString();
    return message.contains('FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION') ||
        message.contains('mediaProjection');
  }

  Future<Map<String, dynamic>> _answerOffer(Map<String, dynamic> offer) async {
    final session = _session;
    final stream = _localStream;
    if (stream == null || _stopping || _sharingServer == null) {
      throw StateError('Screen sharing is not active');
    }

    final peer = await _createPeer();
    _peers.add(peer);
    peer.onIceConnectionState = (state) {
      _logger.info('Screen share sender ICE state: $state');
    };
    peer.onConnectionState = (connectionState) {
      _logger.info('Screen share sender peer state: $connectionState');
      _handleSharingPeerConnectionState(peer, connectionState);
    };
    try {
      _checkSession(session);
      for (final track in stream.getTracks()) {
        final sender = await peer.addTrack(track, stream);
        _checkSession(session);
        if (track.kind == 'video') {
          _videoSenders[peer] = sender;
          await _configureLowLatencyVideoSender(sender);
        }
      }

      await peer.setRemoteDescription(
        RTCSessionDescription(offer['sdp'] as String, offer['type'] as String),
      );
      _checkSession(session);
      if (_source == VideoShareSource.camera) {
        // An addTransceiver(audio) created before the remote offer remains
        // unassociated: libwebrtc creates a separate receiving transceiver for
        // the offered audio section, and otherwise answers it as inactive. Use
        // that associated transceiver to reserve sending without opening a mic.
        final transceivers = await peer.getTransceivers();
        _checkSession(session);
        final audio = transceivers
            .where(
              (transceiver) =>
                  transceiver.mid.isNotEmpty &&
                  transceiver.receiver.track?.kind == 'audio',
            )
            .firstOrNull;
        if (audio != null) {
          await audio.setDirection(TransceiverDirection.SendOnly);
          _checkSession(session);
          await audio.sender.setStreams([stream]);
          _checkSession(session);
          final audioTrack = _cameraAudioStream?.getAudioTracks().firstOrNull;
          if (audioTrack != null) {
            await audio.sender.replaceTrack(audioTrack);
            _checkSession(session);
          }
          _cameraAudioSenders[peer] = audio.sender;
        }
      }
      final answer = await peer.createAnswer();
      await peer.setLocalDescription(answer);
      await _waitForIceGatheringComplete(peer);
      final local = await peer.getLocalDescription();
      _checkSession(session);
      return {
        'type': local?.type ?? answer.type,
        'sdp': _restrictLocalCandidates(local?.sdp ?? answer.sdp ?? ''),
      };
    } catch (_) {
      await _releaseSharingPeer(peer);
      rethrow;
    }
  }

  void _handleSharingPeerConnectionState(
    RTCPeerConnection peer,
    RTCPeerConnectionState connectionState,
  ) {
    if (connectionState ==
        RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      _sharingPeerDisconnectTimers.remove(peer)?.cancel();
      return;
    }

    if (connectionState ==
            RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
        connectionState ==
            RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
      unawaited(_releaseSharingPeer(peer));
      return;
    }

    if (connectionState !=
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
      return;
    }

    _sharingPeerDisconnectTimers.remove(peer)?.cancel();
    _sharingPeerDisconnectTimers[peer] = Timer(
      const Duration(seconds: 4),
      () async {
        if (!_peers.contains(peer)) return;
        RTCPeerConnectionState? currentState;
        try {
          currentState = await peer.getConnectionState();
        } catch (error) {
          _logger.warn('Could not read disconnected screen peer: $error');
          await _releaseSharingPeer(peer);
          return;
        }
        if (!_peers.contains(peer)) return;
        if (currentState ==
                RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
            currentState ==
                RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            currentState ==
                RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          await _releaseSharingPeer(peer);
        }
      },
    );
  }

  Future<void> _releaseSharingPeer(RTCPeerConnection peer) async {
    _sharingPeerDisconnectTimers.remove(peer)?.cancel();
    if (!_peers.remove(peer)) return;
    await _closePeer(peer);
  }

  Future<void> watch(DeviceInfo device) =>
      _watchSource(device, VideoShareSource.screen);

  Future<void> watchCamera(
    DeviceInfo device, {
    List<String>? allowedLocalIps,
  }) => _watchSource(
    device,
    VideoShareSource.camera,
    allowedLocalIps: allowedLocalIps,
  );

  Future<void> _watchSource(
    DeviceInfo device,
    VideoShareSource source, {
    List<String>? allowedLocalIps,
  }) {
    if (_disposed) return Future.error(StateError('Screen share is disposed'));
    if (_localStream != null ||
        _startingShare != null ||
        _switchingCamera != null ||
        _sharingServer != null) {
      return Future.error(StateError('Stop screen capture before watching'));
    }
    final current = _watchedDevice;
    final sameDevice =
        _source == source &&
        current?.id == device.id &&
        current?.ip == device.ip &&
        current?.port == device.port &&
        _sameLocalIps(_allowedLocalIps, allowedLocalIps);
    if (sameDevice && _watching != null) return _watching!;
    if (sameDevice && _viewerPeer != null) return Future.value();
    List<String>? allowed;
    try {
      allowed = _validatedLocalIps(allowedLocalIps);
      if (allowed != null && InternetAddress.tryParse(device.ip) == null) {
        throw StateError('USB camera sharing requires a numeric device IP');
      }
    } catch (error, stack) {
      return Future.error(error, stack);
    }
    _watchedDevice = device;
    _source = source;
    _allowedLocalIps = allowed;
    late final Future<void> operation;
    operation = _watch(device, source, allowed).whenComplete(() {
      if (_watching == operation) _watching = null;
    });
    _watching = operation;
    return operation;
  }

  Future<void> _watch(
    DeviceInfo device,
    VideoShareSource source,
    List<String>? allowedLocalIps,
  ) async {
    final session = ++_session;
    _setState(
      ScreenShareMode.watching,
      'Connecting to ${source.name} share...',
    );
    await _stoppingFuture;
    if (!_isCurrentSession(session)) return;
    await _stopViewer();
    if (!_isCurrentSession(session)) return;
    _source = source;
    _allowedLocalIps = allowedLocalIps;
    _configureBoundSignaling(allowedLocalIps, device.ip);
    _viewerRequests = CancelToken();
    try {
      await initialize();
      _checkSession(session);
      _startMetadataPolling(device, session);
      final peer = await _connectViewerPeer(device, session);
      _checkSession(session);
      _monitorViewerDecode(peer, session);
      _setState(ScreenShareMode.watching, 'Watching remote ${source.name}');
    } catch (error) {
      if (!_isCurrentSession(session)) return;
      await _stopViewer();
      if (!_isCurrentSession(session)) return;
      _setState(ScreenShareMode.idle, 'Could not connect', error.toString());
      rethrow;
    }
  }

  /// Stops only the viewer. File transfers keep their own server and lifecycle.
  Future<void> stopWatching({String status = 'Idle'}) async {
    if (_disposed) return;
    if (_viewerPeer == null &&
        _watching == null &&
        state.value.mode != ScreenShareMode.watching) {
      return;
    }
    final session = ++_session;
    _watching = null;
    _watchedDevice = null;
    await _stopViewer();
    if (_isCurrentSession(session)) _setState(ScreenShareMode.idle, status);
  }

  Future<RTCPeerConnection> _connectViewerPeer(
    DeviceInfo device,
    int session,
  ) async {
    // Receiving camera audio requires playout, with no local microphone capture.
    await _setCameraAudioRecording(false);
    _checkSession(session);
    final peer = await _createPeer();
    try {
      _checkSession(session);
      _viewerPeer = peer;
      await peer.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      if (_source == VideoShareSource.camera) {
        await peer.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        );
      }
      peer.onIceConnectionState = (state) {
        _logger.info('Screen share viewer ICE state: $state');
        if (!_isCurrentSession(session) || _viewerPeer != peer) return;
        if (state == RTCIceConnectionState.RTCIceConnectionStateClosed ||
            state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          unawaited(_handleRemoteEnded(_endedStatus));
        }
      };
      peer.onTrack = (event) async {
        if (!_isCurrentSession(session) || _viewerPeer != peer) return;
        _logger.info(
          'Screen share viewer received track: ${event.track.kind} '
          '(streams: ${event.streams.length})',
        );
        try {
          event.track.enabled = true;
        } catch (_) {}
        // Native WebRTC plays remote audio through its audio device. A muted
        // microphone must neither replace the video texture nor end the video.
        if (event.track.kind == 'audio') return;
        event.track.onEnded = () {
          if (_isCurrentSession(session) && _viewerPeer == peer) {
            unawaited(_handleRemoteEnded(_endedStatus));
          }
        };
        if (event.streams.isNotEmpty) {
          final stream = event.streams.first;
          try {
            await remoteRenderer.setSrcObject(
              stream: stream,
              trackId: event.track.id,
            );
          } catch (error) {
            if (_isCurrentSession(session)) {
              _logger.warn('Could not attach remote screen renderer: $error');
            }
            return;
          }
          _logger.info(
            'Remote screen stream tracks: '
            '${stream.getVideoTracks().map((track) => track.id).join(', ')}',
          );
        }
      };

      final offer = await peer.createOffer({
        'offerToReceiveVideo': 1,
        'offerToReceiveAudio': _source == VideoShareSource.camera ? 1 : 0,
      });
      final preferredOffer = RTCSessionDescription(
        _preferVideoCodec(offer.sdp ?? '', _screenCodec),
        offer.type,
      );
      await peer.setLocalDescription(preferredOffer);
      await _waitForIceGatheringComplete(peer);
      final local = await peer.getLocalDescription();

      _checkSession(session);
      final response = await (_boundSignalingClient ?? _dio)
          .postUri<Map<String, dynamic>>(
            device.baseUri.replace(path: '/api/${_source.name}/offer'),
            cancelToken: _viewerRequests,
            data: {
              'type': local?.type ?? preferredOffer.type,
              'sdp': _restrictLocalCandidates(
                _preferVideoCodec(
                  local?.sdp ?? preferredOffer.sdp ?? '',
                  _screenCodec,
                ),
              ),
            },
          );
      _checkSession(session);
      final payload = response.data;
      final answer = payload?['answer'] as Map<String, dynamic>?;
      if (answer == null) {
        throw StateError(
          payload?['error']?.toString() ?? 'No screen-share answer',
        );
      }
      final answerSdp = answer['sdp'] as String;
      _logger.info(
        'Screen share negotiated codec: '
        '${_firstVideoCodec(answerSdp) ?? 'automatic'}',
      );
      await peer.setRemoteDescription(
        RTCSessionDescription(answerSdp, answer['type'] as String),
      );
      _checkSession(session);
      return peer;
    } catch (_) {
      if (_viewerPeer == peer) _viewerPeer = null;
      await _closePeer(peer);
      rethrow;
    }
  }

  void _monitorViewerDecode(RTCPeerConnection peer, int session) {
    _viewerStatsTimer?.cancel();
    var attempt = 0;
    Future<void> sample() async {
      if (!_isCurrentSession(session) || _viewerPeer != peer) return;
      attempt++;
      try {
        final reports = await peer.getStats();
        if (!_isCurrentSession(session) || _viewerPeer != peer) return;
        var foundInboundVideo = false;
        for (final report in reports) {
          if (report.type != 'inbound-rtp') continue;
          final values = report.values;
          final kind = values['kind'] ?? values['mediaType'];
          if (kind == 'audio') continue;
          foundInboundVideo = true;
          _logger.info(
            'Remote screen inbound video: '
            'bytes=${values['bytesReceived'] ?? '-'}, '
            'packets=${values['packetsReceived'] ?? '-'}, '
            'frames=${values['framesReceived'] ?? '-'}, '
            'decoded=${values['framesDecoded'] ?? '-'}, '
            'dropped=${values['framesDropped'] ?? '-'}, '
            'codec=${values['codecId'] ?? '-'}',
          );
        }
        if (foundInboundVideo) return;
      } catch (error) {
        _logger.warn('Could not read screen viewer stats: $error');
        return;
      }
      if (attempt < 5 && _isCurrentSession(session) && _viewerPeer == peer) {
        _viewerStatsTimer = Timer(const Duration(seconds: 2), sample);
      }
    }

    _viewerStatsTimer = Timer(const Duration(seconds: 4), sample);
  }

  void updateLocalScreenMetrics(double width, double height) {
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      return;
    }
    _localScreenWidth = width.round();
    _localScreenHeight = height.round();
    _localAspectRatio = width / height;
  }

  void _startAndroidMetricsObserver() {
    if (!WebRTC.platformIsAndroid) return;
    if (!_observingAndroidMetrics) {
      WidgetsBinding.instance.addObserver(this);
      _observingAndroidMetrics = true;
    }
    _pollAndroidScreenMetrics(force: true);
  }

  @override
  void didChangeMetrics() {
    if (_observingAndroidMetrics) _pollAndroidScreenMetrics();
  }

  void _pollAndroidScreenMetrics({bool force = false}) {
    if (!WebRTC.platformIsAndroid || _localStream == null) return;
    final views = ui.PlatformDispatcher.instance.views;
    if (views.isEmpty) return;
    final size = views.first.physicalSize;
    if (size == ui.Size.zero) return;

    final last = _lastAndroidViewSize;
    if (!force && last == size) return;
    _lastAndroidViewSize = size;
    updateLocalScreenMetrics(size.width, size.height);

    if (!force) {
      _logger.info(
        'Android screen metrics changed to '
        '${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)}',
      );
    }
  }

  void _stopAndroidMetricsObserver() {
    if (_observingAndroidMetrics) WidgetsBinding.instance.removeObserver(this);
    _observingAndroidMetrics = false;
    _lastAndroidViewSize = null;
  }

  Map<String, dynamic> _screenMetadata() {
    final frame = localRenderer.value;
    final rendererAspect = frame.aspectRatio;
    final hasFrame =
        frame.width.isFinite &&
        frame.height.isFinite &&
        frame.width > 0 &&
        frame.height > 0;
    final quarterTurn = frame.rotation == 90 || frame.rotation == 270;
    final aspectRatio = hasFrame && _isHealthyAspectRatio(rendererAspect)
        ? rendererAspect
        : _isHealthyAspectRatio(_localAspectRatio)
        ? _localAspectRatio!
        : 16 / 9;
    return {
      'source': _source.name,
      if (_source == VideoShareSource.camera) 'cameraId': _currentCamera?.id,
      'resolution': _captureSettings.resolution,
      'frameRate': _captureSettings.frameRate,
      'aspectRatio': aspectRatio,
      'width': hasFrame
          ? (quarterTurn ? frame.height : frame.width).round()
          : _localScreenWidth,
      'height': hasFrame
          ? (quarterTurn ? frame.width : frame.height).round()
          : _localScreenHeight,
      'generation': _screenGeneration,
      'trackId': _localTrackId,
      'updatedAt': DateTime.now().toIso8601String(),
    };
  }

  void _startMetadataPolling(DeviceInfo device, int session) {
    _metadataPollTimer?.cancel();
    // Schedule the next request only after this one finishes. Slow devices must
    // never accumulate metadata requests or apply responses out of order.
    Future<void> poll() async {
      if (!_isCurrentSession(session)) return;
      await _pollScreenMetadata(device, session);
      if (_isCurrentSession(session) && _viewerRequests?.isCancelled == false) {
        _metadataPollTimer = Timer(_metadataPollInterval, poll);
      }
    }

    unawaited(poll());
  }

  Future<void> _pollScreenMetadata(DeviceInfo device, int session) async {
    try {
      final response = await (_boundSignalingClient ?? _dio)
          .getUri<Map<String, dynamic>>(
            device.baseUri.replace(path: '/api/${_source.name}/metadata'),
            cancelToken: _viewerRequests,
            options: Options(
              connectTimeout: const Duration(seconds: 2),
              receiveTimeout: const Duration(seconds: 2),
            ),
          );
      if (!_isCurrentSession(session)) return;
      final metadata = response.data?['metadata'] as Map<String, dynamic>?;
      final aspectRatio = (metadata?['aspectRatio'] as num?)?.toDouble();
      if (_isHealthyAspectRatio(aspectRatio)) {
        remoteAspectRatio.value = aspectRatio;
      }
      final generation = (metadata?['generation'] as num?)?.toInt();
      if (generation != null) {
        final previous = _lastRemoteGeneration;
        _lastRemoteGeneration = generation;
        if (previous != null && generation != previous) {
          await _reconnectViewer(device, session);
        }
      }
    } catch (error) {
      if (_isCurrentSession(session) && _isScreenShareNotActiveError(error)) {
        await _handleRemoteEnded(_endedStatus);
      }
    }
  }

  bool _isScreenShareNotActiveError(Object error) {
    if (error is! DioException) return false;
    final response = error.response;
    if (response?.statusCode != HttpStatus.serviceUnavailable) return false;
    final data = response?.data;
    return data is Map && data['error'] == '${_source.name}-share-not-active';
  }

  Future<void> _handleRemoteEnded(String status) async {
    if (state.value.mode != ScreenShareMode.watching || _stopping) return;
    _logger.info('Remote screen share ended');
    final session = ++_session;
    _watching = null;
    _watchedDevice = null;
    await _stopViewer();
    if (_isCurrentSession(session)) _setState(ScreenShareMode.idle, status);
  }

  Future<void> _reconnectViewer(DeviceInfo device, int session) async {
    if (_reconnectingViewer || !_isCurrentSession(session)) return;
    _reconnectingViewer = true;
    try {
      _logger.info('Reconnecting screen viewer after stream restart');
      await _stopViewer(keepMetadataPolling: true);
      _checkSession(session);
      final peer = await _connectViewerPeer(device, session);
      _checkSession(session);
      _monitorViewerDecode(peer, session);
    } catch (error) {
      if (_isCurrentSession(session)) {
        _logger.warn('Screen viewer reconnect failed: $error');
        await _handleRemoteEnded(_endedStatus);
      }
    } finally {
      _reconnectingViewer = false;
    }
  }

  bool _isHealthyAspectRatio(double? aspectRatio) {
    return aspectRatio != null &&
        !aspectRatio.isNaN &&
        !aspectRatio.isInfinite &&
        aspectRatio > 0;
  }

  List<String>? _validatedLocalIps(List<String>? values) {
    if (values == null) return null;
    final addresses = <String>{};
    for (final value in values) {
      final address = InternetAddress.tryParse(value);
      if (address == null ||
          address.isMulticast ||
          address.address == '0.0.0.0' ||
          address.address == '::') {
        throw StateError('A valid USB interface address is required');
      }
      addresses.add(address.address);
    }
    if (addresses.isEmpty) throw StateError('No USB interface is available');
    return addresses.toList(growable: false);
  }

  bool _sameLocalIps(List<String>? first, List<String>? second) => first == null
      ? second == null
      : second != null &&
            first.length == second.length &&
            first.every(second.contains);

  String _restrictLocalCandidates(String sdp) {
    final allowed = _allowedLocalIps;
    if (allowed == null) return sdp;
    var candidates = 0;
    final lines = <String>[];
    for (final line in sdp.split(RegExp(r'\r?\n'))) {
      if (line.startsWith('a=candidate:')) {
        final fields = line.split(RegExp(r'\s+'));
        if (fields.length < 8 ||
            fields[6] != 'typ' ||
            fields[7] != 'host' ||
            !allowed.contains(InternetAddress.tryParse(fields[4])?.address)) {
          continue;
        }
        candidates++;
      } else if (line.startsWith('a=remote-candidates:')) {
        continue;
      } else if (line.startsWith('c=IN IP')) {
        // The effective media path is carried in ICE; keep even the fallback
        // connection address constrained to the selected USB interface.
        final address = InternetAddress(allowed.first);
        lines.add(
          'c=IN IP${address.type == InternetAddressType.IPv4 ? 4 : 6} ${address.address}',
        );
        continue;
      }
      lines.add(line);
    }
    if (candidates == 0) {
      throw StateError('WebRTC found no host candidate on the USB interface');
    }
    return lines.join('\r\n');
  }

  void _configureBoundSignaling(List<String>? allowed, String remoteIp) {
    _boundSignalingClient?.close(force: true);
    _boundSignalingClient = null;
    if (allowed == null) return;
    final remote = InternetAddress(remoteIp);
    final local = allowed
        .map(InternetAddress.new)
        .where((ip) => ip.type == remote.type)
        .firstOrNull;
    if (local == null) {
      throw StateError('The USB interface cannot reach this IP family');
    }
    final client = Dio(_dio.options.copyWith());
    client.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final http = HttpClient();
        http.findProxy = (_) => 'DIRECT';
        http.connectionFactory = (uri, proxyHost, proxyPort) {
          if (proxyHost != null) {
            throw StateError('USB camera signaling cannot use a proxy');
          }
          return Socket.startConnect(uri.host, uri.port, sourceAddress: local);
        };
        return http;
      },
    );
    _boundSignalingClient = client;
  }

  Future<RTCPeerConnection> _createPeer() {
    return _peerConnectionFactory();
  }

  static Future<RTCPeerConnection> _createLanPeer() {
    return createPeerConnection({
      'iceServers': [],
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
    });
  }

  Future<void> _configureLowLatencyVideoSender(RTCRtpSender sender) {
    final previous = _senderUpdates[sender] ?? Future<void>.value();
    final operation = previous.then((_) => _applyVideoSenderSettings(sender));
    _senderUpdates[sender] = operation;
    return operation;
  }

  Future<void> _applyVideoSenderSettings(RTCRtpSender sender) async {
    if (_disposed || !_videoSenders.containsValue(sender)) return;
    try {
      final options = _captureSettings;
      final size = localRenderer.value;
      final scale = options.scaleFor(size.width, size.height);
      final parameters = sender.parameters;
      parameters.degradationPreference = WebRTC.platformIsAndroid
          ? RTCDegradationPreference.MAINTAIN_FRAMERATE
          : RTCDegradationPreference.MAINTAIN_RESOLUTION;
      final encodings = parameters.encodings;
      if (encodings == null || encodings.isEmpty) {
        parameters.encodings = [
          RTCRtpEncoding(
            maxBitrate: options.maxBitrate,
            maxFramerate: options.frameRate,
            scaleResolutionDownBy: scale,
            priority: RTCPriorityType.high,
            networkPriority: RTCPriorityType.high,
          ),
        ];
      } else {
        for (final encoding in encodings) {
          encoding.maxBitrate = options.maxBitrate;
          encoding.minBitrate = null;
          encoding.maxFramerate = options.frameRate;
          encoding.scaleResolutionDownBy = scale;
          encoding.priority = RTCPriorityType.high;
          encoding.networkPriority = RTCPriorityType.high;
        }
      }
      final applied = await sender.setParameters(parameters);
      if (!applied) {
        _logger.warn('Screen share sender rejected the video limits');
      }
    } catch (error) {
      _logger.warn('Screen share sender tuning failed: $error');
    }
  }

  String _preferVideoCodec(String sdp, String codec) {
    if (sdp.isEmpty) return sdp;
    final lines = sdp.split(RegExp(r'\r?\n'));
    final videoIndex = lines.indexWhere((line) => line.startsWith('m=video '));
    if (videoIndex == -1) return sdp;

    final codecPattern = RegExp(
      '^a=rtpmap:(\\d+)\\s+$codec/',
      caseSensitive: false,
    );
    final preferredPayloads = <String>[];
    for (final line in lines) {
      final match = codecPattern.firstMatch(line);
      if (match != null) preferredPayloads.add(match.group(1)!);
    }
    if (preferredPayloads.isEmpty) return sdp;

    final videoParts = lines[videoIndex].split(' ');
    if (videoParts.length <= 3) return sdp;
    final header = videoParts.take(3);
    final payloads = videoParts.skip(3).toList();
    final orderedPayloads = [
      ...preferredPayloads.where(payloads.contains),
      ...payloads.where((payload) => !preferredPayloads.contains(payload)),
    ];
    lines[videoIndex] = [...header, ...orderedPayloads].join(' ');
    return lines.join('\r\n');
  }

  String? _firstVideoCodec(String sdp) {
    if (sdp.isEmpty) return null;
    final lines = sdp.split(RegExp(r'\r?\n'));
    final videoLine = lines
        .where((line) => line.startsWith('m=video '))
        .firstOrNull;
    if (videoLine == null) return null;
    final parts = videoLine.split(' ');
    if (parts.length <= 3) return null;
    final firstPayload = parts[3];
    final codecPattern = RegExp(
      '^a=rtpmap:${RegExp.escape(firstPayload)}\\s+([^/]+)/',
      caseSensitive: false,
    );
    for (final line in lines) {
      final match = codecPattern.firstMatch(line);
      if (match != null) return match.group(1)?.toUpperCase();
    }
    return null;
  }

  Future<void> _prepareCapture(int session) async {
    if (WebRTC.platformIsAndroid) {
      final granted = await Helper.requestCapturePermission();
      if (!granted) {
        throw StateError('Screen capture permission was denied');
      }
      _checkSession(session);
      await _enableAndroidScreenShareExecution();
      if (!_isCurrentSession(session)) {
        await _disableAndroidScreenShareExecution();
        _checkSession(session);
      }
    } else if (WebRTC.platformIsMacOS) {
      final granted = await Helper.requestCapturePermission();
      if (!granted) {
        throw StateError('Screen capture permission was denied');
      }
    }
    _checkSession(session);
  }

  Future<void> _enableAndroidScreenShareExecution() async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await _screenShareExecution.start();
        await Future<void>.delayed(_androidForegroundServiceSettleDelay);
        return;
      } catch (error) {
        lastError = error;
        _logger.warn('Android screen-share background start failed: $error');
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
    }

    throw StateError('Android background service could not start: $lastError');
  }

  Future<void> _restartAndroidScreenShareExecution() async {
    try {
      await _screenShareExecution.stop();
      await Future<void>.delayed(const Duration(milliseconds: 350));
    } catch (error) {
      _logger.warn('Android background service restart cleanup failed: $error');
    }
    await _enableAndroidScreenShareExecution();
  }

  Future<dynamic> _videoConstraints() async {
    if (WebRTC.platformIsDesktop) {
      final sources = await desktopCapturer.getSources(
        types: [SourceType.Screen],
      );
      if (sources.isEmpty) {
        throw StateError('No screen source found');
      }
      final source = sources.first;
      return {
        'deviceId': {'exact': source.id},
        'mandatory': {'frameRate': _captureSettings.frameRate.toDouble()},
      };
    }
    if (WebRTC.platformIsAndroid) {
      return {
        'mandatory': {
          'maxShortSide': _captureSettings.resolution,
          'frameRate': _captureSettings.frameRate,
        },
      };
    }
    return true;
  }

  Future<void> _waitForIceGatheringComplete(RTCPeerConnection peer) async {
    if (peer.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      return;
    }
    final completer = Completer<void>();
    Timer? timeout;
    void finish() {
      timeout?.cancel();
      if (!completer.isCompleted) completer.complete();
    }

    _iceWaitCancellations[peer] = finish;
    peer.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) finish();
    };
    timeout = Timer(const Duration(seconds: 4), finish);
    // Recheck after installing the callback in case gathering just completed.
    if (peer.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      finish();
    }
    try {
      await completer.future;
    } finally {
      timeout.cancel();
      _iceWaitCancellations.remove(peer);
      peer.onIceGatheringState = null;
    }
  }

  Future<void> stop(FileServer server, {String status = 'Idle'}) {
    if (_disposed) return _disposing ?? Future.value();
    return _stop(server, status: status);
  }

  Future<void> _stop(
    FileServer server, {
    bool updateState = true,
    String status = 'Idle',
    bool invalidateSession = true,
  }) {
    if (invalidateSession) {
      ++_session;
      _cameraLifecycle.cancel();
      _cancelCameraControls();
    }
    final session = _session;
    _cancelViewerRequests();
    final stopping = _stoppingFuture ??= _stopResources(
      server,
    ).whenComplete(() => _stoppingFuture = null);
    return stopping.then((_) {
      if (updateState && _isCurrentSession(session)) {
        _setState(ScreenShareMode.idle, status);
      }
    });
  }

  Future<void> _stopResources(FileServer server) async {
    _stopping = true;
    final wasSharing = _localStream != null || _sharingServer != null;
    try {
      // Invalidate capture immediately, even while a late media acquisition or
      // another camera operation is still finishing its own cleanup.
      try {
        await _stopCameraAudioRecording();
      } catch (_) {}
      _clearVideoHandlers(server);
      if (_sharingServer != null && _sharingServer != server) {
        _clearVideoHandlers(_sharingServer!);
      }
      _sharingServer = null;
      _stopAndroidMetricsObserver();
      await _stopSharingPeers();
      // Finish controls and any late media acquisition before native services
      // are stopped; a permission dialog is canceled without opening capture.
      await _cameraOperations;
      await _stopViewer();
      await _stopCameraMicrophone();
      await _stopLocalStream();
      await _disableAndroidScreenShareExecution();
      await _disableAndroidCameraExecution();
      _currentCamera = null;
      _allowedLocalIps = null;
      if (wasSharing) await onSharingStopped?.call();
    } finally {
      _stopping = false;
    }
  }

  Future<void> dispose() {
    if (_disposing != null) return _disposing!;
    _disposed = true;
    ++_session;
    _cameraLifecycle.dispose();
    _cancelCameraControls();
    _cancelViewerRequests();
    return _disposing = _disposeResources();
  }

  Future<void> _disposeResources() async {
    _logger.info('Disposing screen share resources');
    try {
      await _stopCameraAudioRecording();
    } catch (_) {}
    // Renderer creation must finish before native textures can be released.
    try {
      await _initializing;
    } catch (_) {}
    await _stoppingFuture;
    if (_sharingServer != null) _clearVideoHandlers(_sharingServer!);
    _sharingServer = null;
    _stopAndroidMetricsObserver();
    await _stopSharingPeers();
    await _cameraOperations;
    await _stopViewer();
    await _stopCameraMicrophone();
    await _stopLocalStream();
    await _disableAndroidScreenShareExecution();
    await _disableAndroidCameraExecution();
    _currentCamera = null;
    try {
      await Future.wait([localRenderer.dispose(), remoteRenderer.dispose()]);
    } finally {
      remoteAspectRatio.dispose();
      focusedViewerActive.dispose();
      state.dispose();
      _dio.close(force: true);
    }
  }

  Future<void> _stopSharingPeers() async {
    for (final timer in _sharingPeerDisconnectTimers.values) {
      timer.cancel();
    }
    _sharingPeerDisconnectTimers.clear();
    final peers = List<RTCPeerConnection>.from(_peers);
    _peers.clear();
    await Future.wait(peers.map(_closePeer));
  }

  Future<void> _closePeer(RTCPeerConnection peer) {
    return _closingPeers[peer] ??= _disposePeer(peer);
  }

  Future<void> _disposePeer(RTCPeerConnection peer) async {
    _videoSenders.remove(peer);
    _cameraAudioSenders.remove(peer);
    peer.onConnectionState = null;
    peer.onIceConnectionState = null;
    peer.onTrack = null;
    _iceWaitCancellations.remove(peer)?.call();
    try {
      await peer.close();
    } catch (error) {
      _logger.warn('Screen peer close failed: $error');
    }
    // close() only closes ICE; dispose() releases the native peer and its
    // EventChannel subscription in flutter_webrtc.
    try {
      await peer.dispose();
    } catch (error) {
      _logger.warn('Screen peer dispose failed: $error');
    }
  }

  void _cancelViewerRequests() {
    _metadataPollTimer?.cancel();
    _metadataPollTimer = null;
    _viewerStatsTimer?.cancel();
    _viewerStatsTimer = null;
    _viewerRequests?.cancel('Screen viewer stopped');
    _viewerRequests = null;
  }

  Future<void> _detachRenderer(RTCVideoRenderer renderer) async {
    if (!_initialized) return;
    try {
      await renderer.setSrcObject(stream: null);
    } catch (error) {
      _logger.warn('Screen renderer detach failed: $error');
    }
  }

  Future<void> _stopViewer({bool keepMetadataPolling = false}) async {
    _viewerStatsTimer?.cancel();
    _viewerStatsTimer = null;
    if (!keepMetadataPolling) {
      _cancelViewerRequests();
      _lastRemoteGeneration = null;
      remoteAspectRatio.value = null;
      _boundSignalingClient?.close(force: true);
      _boundSignalingClient = null;
    }
    final peer = _viewerPeer;
    _viewerPeer = null;
    await _detachRenderer(remoteRenderer);
    if (peer != null) await _closePeer(peer);
  }

  Future<void> _stopLocalStream() async {
    final stream = _localStream;
    await _resetCameraTorch(stream);
    _localStream = null;
    _localTrackId = null;
    _localAspectRatio = null;
    _localScreenWidth = null;
    _localScreenHeight = null;
    await _detachRenderer(localRenderer);
    if (stream != null) await _disposeStream(stream);
  }

  Future<void> _disposeStream(MediaStream stream) async {
    for (final track in stream.getTracks()) {
      track.onEnded = null;
      try {
        await track.stop();
      } catch (error) {
        _logger.warn('Screen share track stop failed: $error');
      }
    }
    try {
      await stream.dispose();
    } catch (error) {
      _logger.warn('Screen share stream dispose failed: $error');
    }
  }

  Future<void> _disableAndroidScreenShareExecution() async {
    if (!WebRTC.platformIsAndroid) return;
    try {
      await _screenShareExecution.stop();
    } catch (error) {
      _logger.warn('Android screen-share background stop failed: $error');
    }
  }

  Future<void> _disableAndroidCameraExecution() async {
    if (!WebRTC.platformIsAndroid) return;
    try {
      await _cameraExecution.stop();
    } catch (error) {
      _logger.warn('Android camera background stop failed: $error');
    }
  }

  void _clearVideoHandlers(FileServer server) {
    server.screenOfferHandler = null;
    server.screenMetadataHandler = null;
    server.cameraOfferHandler = null;
    server.cameraMetadataHandler = null;
    server.cameraAllowedRemoteSubnets = null;
  }
}
