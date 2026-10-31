import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bshare/src/domain/entities/camera_device.dart';
import 'package:bshare/src/domain/entities/camera_capture_controls.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/domain/entities/screen_capture_settings.dart';
import 'package:bshare/src/infrastructure/services/android_camera_execution_service.dart';
import 'package:bshare/src/infrastructure/services/android_screen_share_execution_service.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/camera_capture_lifecycle_gate.dart';
import 'package:bshare/src/infrastructure/services/file_server.dart';
import 'package:bshare/src/infrastructure/services/permission_request_coordinator.dart';
import 'package:bshare/src/infrastructure/services/video_sdp_policy.dart';
import 'package:bshare/src/infrastructure/services/usb_adb_transport_service.dart';
import 'package:bshare/src/infrastructure/services/usb_ice_configuration.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

enum ScreenShareMode { idle, sharing, watching }

enum VideoShareSource { screen, camera }

/// State reported by the broadcasting device, not the PC's microphone.
class RemoteCameraControls {
  const RemoteCameraControls({
    this.available = false,
    this.busy = false,
    this.microphoneEnabled = false,
    this.torchEnabled = false,
    this.torchAvailable = false,
    this.canSwitchCamera = false,
    this.capture = const CameraCaptureControls(),
  });

  final bool available;
  final bool busy;
  final bool microphoneEnabled;
  final bool torchEnabled;
  final bool torchAvailable;
  final bool canSwitchCamera;
  final CameraCaptureControls capture;
}

enum ScreenSystemAudioStatus {
  off,
  active,
  unsupported,
  permissionDenied,
  unavailable,
}

enum VideoConnectionFailure {
  connectionRefused,
  connectionTimeout,
  signaling,
  network,
  video,
}

class ScreenShareState {
  const ScreenShareState({
    required this.mode,
    this.status = 'Idle',
    this.error,
    this.awaitingVideo = false,
    this.failure,
    this.endpoint,
  });

  final ScreenShareMode mode;
  final String status;
  final String? error;
  final bool awaitingVideo;
  final VideoConnectionFailure? failure;
  final String? endpoint;
}

class ScreenShareService with WidgetsBindingObserver {
  ScreenShareService(
    this._logger,
    this._screenShareExecution, {
    Dio? signalingClient,
    RTCVideoRenderer? localRenderer,
    RTCVideoRenderer? remoteRenderer,
    Future<RTCPeerConnection> Function()? peerConnectionFactory,
    this.configuredPeerConnectionFactory,
    UsbAdbTransportService? usbTransport,
    AndroidCameraExecutionService? cameraExecution,
    PermissionRequestCoordinator? permissionCoordinator,
    Future<void> Function(bool enabled)? audioRecordingGate,
    Future<void> Function(bool enabled)? systemAudioRecordingGate,
    this.systemAudioSupport,
    this.remoteMicrophonePermissionGranted,
    Future<Map<String, dynamic>> Function(MediaStreamTrack track)?
    cameraControlsReader,
    Future<Map<String, dynamic>> Function(
      MediaStreamTrack track,
      Map<String, dynamic> settings,
    )?
    cameraControlsWriter,
    this.videoStartupTimeout = const Duration(seconds: 25),
    this.iceGatheringTimeout = const Duration(seconds: 10),
    this.onSharingStopped,
  }) : _dio =
           signalingClient ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 15),
               receiveTimeout: const Duration(seconds: 35),
             ),
           ),
       localRenderer = localRenderer ?? RTCVideoRenderer(),
       remoteRenderer =
           remoteRenderer ?? RTCVideoRenderer(virtualCameraOutput: true),
       _cameraExecution = cameraExecution ?? AndroidCameraExecutionService(),
       _permissions =
           permissionCoordinator ?? PermissionRequestCoordinator.instance,
       _audioRecordingGate =
           audioRecordingGate ?? Helper.setAndroidAudioRecording,
       _systemAudioRecordingGate =
           systemAudioRecordingGate ?? Helper.setAndroidScreenAudioRecording,
       _readCameraControls =
           cameraControlsReader ?? Helper.getCameraCaptureControls,
       _writeCameraControls =
           cameraControlsWriter ?? Helper.setCameraCaptureControls,
       _peerConnectionFactory = peerConnectionFactory ?? _createLanPeer,
       _usbTransport = usbTransport ?? UsbAdbTransportService();

  static const Duration _metadataPollInterval = Duration(milliseconds: 500);
  static const Duration _androidForegroundServiceSettleDelay = Duration(
    milliseconds: 650,
  );

  final AppLogger _logger;
  final Duration videoStartupTimeout;
  final Duration iceGatheringTimeout;
  final AndroidScreenShareExecutionService _screenShareExecution;
  final AndroidCameraExecutionService _cameraExecution;
  final PermissionRequestCoordinator _permissions;
  final Future<void> Function(bool enabled) _audioRecordingGate;
  bool _audioRecordingConfigured = false;
  final Future<void> Function(bool enabled) _systemAudioRecordingGate;
  final Future<bool> Function()? systemAudioSupport;
  final Future<bool> Function()? remoteMicrophonePermissionGranted;
  final Future<Map<String, dynamic>> Function(MediaStreamTrack track)
  _readCameraControls;
  final Future<Map<String, dynamic>> Function(
    MediaStreamTrack track,
    Map<String, dynamic> settings,
  )
  _writeCameraControls;
  CameraCaptureControls _cameraCaptureControls = const CameraCaptureControls();
  bool _systemAudioRecordingConfigured = false;
  ScreenSystemAudioStatus _screenSystemAudioStatus =
      ScreenSystemAudioStatus.off;
  ScreenSystemAudioStatus get screenSystemAudioStatus =>
      _screenSystemAudioStatus;

  Future<bool> supportsSystemAudio() async {
    final injected = systemAudioSupport;
    if (injected != null) return injected();
    if (!WebRTC.platformIsAndroid) return false;
    return await WebRTC.invokeMethod<bool, dynamic>(
          'isScreenAudioCaptureSupported',
        ) ??
        false;
  }

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
  final Future<RTCPeerConnection> Function(Map<String, dynamic>)?
  configuredPeerConnectionFactory;
  final UsbAdbTransportService _usbTransport;
  UsbRelaySession? _usbViewerSession;
  int _usbOpeningGeneration = 0;
  bool get watchingUsb => _usbViewerSession != null;
  bool _captureUsbOnly = false;
  bool get usbOnly => _captureUsbOnly || watchingUsb;
  final Future<void> Function()? onSharingStopped;
  ScreenCaptureSettings _captureSettings = const ScreenCaptureSettings();
  ScreenCaptureSettings get captureSettings => _captureSettings;
  final Map<RTCPeerConnection, RTCRtpSender> _videoSenders = {};
  final Set<RTCRtpSender> _compatibilitySenders = {};
  final Map<String, RTCPeerConnection> _remoteViewers = {};
  final Map<RTCPeerConnection, String> _remoteControlTokens = {};
  List<CameraDevice> _knownCameras = const [];
  final Map<String, Future<void>> _remoteViewerOperations = {};
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
  MediaStreamTrack? _remoteVideoTrack;
  MediaStreamTrack? _remoteAudioTrack;
  MediaStreamTrack? get remoteVideoTrack => _remoteVideoTrack;
  MediaStreamTrack? get remoteAudioTrack => _remoteAudioTrack;
  final ValueNotifier<bool> remotePreviewEnabled = ValueNotifier(true);
  Future<void> Function()? beforeRemoteMediaDetach;

  Future<void> setRemotePreviewEnabled(bool enabled) async {
    if (_disposed) return;
    final previous = remotePreviewEnabled.value;
    remotePreviewEnabled.value = enabled;
    if (!_initialized) return;
    try {
      await remoteRenderer.setFrameOutputEnabled(enabled);
    } catch (_) {
      if (!_disposed && remotePreviewEnabled.value == enabled) {
        remotePreviewEnabled.value = previous;
      }
      rethrow;
    }
  }

  final ValueNotifier<ScreenShareState> state = ValueNotifier(
    const ScreenShareState(mode: ScreenShareMode.idle),
  );
  final ValueNotifier<double?> remoteAspectRatio = ValueNotifier(null);
  final ValueNotifier<bool> focusedViewerActive = ValueNotifier(false);
  final ValueNotifier<RemoteCameraControls> remoteCameraControls =
      ValueNotifier(const RemoteCameraControls());

  /// Opaque receiver identity for gesture coalescing; never exposes its token.
  String? get remoteCameraControlSessionId => _viewerId == null
      ? null
      : '$_session:$_viewerId:${_remoteCameraSnapshot.capture.trackId ?? ''}';
  String? _viewerControlToken;
  int _remoteControlRevision = -1;
  int _cameraControlRevision = 0;
  Future<void>? _remoteControlOperation;
  bool _remoteCameraControlBusy = false;
  RemoteCameraControls _remoteCameraSnapshot = const RemoteCameraControls();
  final List<RTCPeerConnection> _peers = [];
  final Map<RTCPeerConnection, Timer> _sharingPeerDisconnectTimers = {};

  MediaStream? _localStream;
  RTCPeerConnection? _viewerPeer;
  Timer? _metadataPollTimer;
  Timer? _viewerStatsTimer;
  Timer? _viewerStartupTimer;
  bool _viewerHasVideo = false;
  bool _viewerCompatibility = false;
  RTCIceConnectionState? _viewerIceState;
  String? _viewerId;
  Uri? _viewerStopUri;
  CancelToken? _viewerRequests;
  Future<void>? _initializing;
  Future<void>? _startingShare;
  Future<void>? _watching;
  DeviceInfo? _watchedDevice;
  Future<void>? _stoppingFuture;
  Future<void>? _viewerStopping;
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
  int? _viewerReconnectSession;
  bool get _reconnectingViewer => _viewerReconnectSession == _session;
  bool _stopping = false;

  void _setState(ScreenShareMode mode, String status, [String? error]) {
    if (_disposed) return;
    state.value = ScreenShareState(mode: mode, status: status, error: error);
  }

  void _setViewerConnecting({bool compatibility = false}) {
    if (_disposed) return;
    state.value = ScreenShareState(
      mode: ScreenShareMode.watching,
      status: compatibility
          ? 'Retrying compatible video...'
          : 'Connecting to ${_source.name} share...',
      awaitingVideo: true,
    );
  }

  void _markViewerVideoReady() {
    if (_viewerPeer == null ||
        remoteRenderer.srcObject == null ||
        _viewerHasVideo ||
        _disposed ||
        _stopping) {
      return;
    }
    _viewerHasVideo = true;
    _viewerStartupTimer?.cancel();
    _viewerStartupTimer = null;
    _setState(ScreenShareMode.watching, 'Watching remote ${_source.name}');
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
      _markViewerVideoReady();
    };
    remoteRenderer.onResize = () {
      final value = remoteRenderer.value;
      _logger.info(
        'Remote screen renderer size: '
        '${value.width.toInt()}x${value.height.toInt()}',
      );
      // Some native renderers emit first-frame only once per texture lifetime.
      if (value.width > 0 &&
          value.height > 0 &&
          remoteRenderer.srcObject != null) {
        _markViewerVideoReady();
      }
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
    return _knownCameras = [?primary[false], ?primary[true]];
  }

  Future<void> startSharing(
    FileServer server, {
    ScreenCaptureSettings settings = const ScreenCaptureSettings(),
    bool includeSystemAudio = true,
    bool usbOnly = false,
  }) => _startCapture(
    server,
    VideoShareSource.screen,
    settings,
    includeSystemAudio: includeSystemAudio,
    usbOnly: usbOnly,
  );

  Future<void> startCameraSharing(
    FileServer server, {
    required CameraDevice camera,
    ScreenCaptureSettings settings = const ScreenCaptureSettings(),
    List<String>? allowedLocalIps,
    List<String>? allowedRemoteSubnets,
    bool usbOnly = false,
  }) => _startCapture(
    server,
    VideoShareSource.camera,
    settings,
    camera: camera,
    allowedLocalIps: allowedLocalIps,
    allowedRemoteSubnets: allowedRemoteSubnets,
    usbOnly: usbOnly,
  );

  Future<void> _startCapture(
    FileServer server,
    VideoShareSource source,
    ScreenCaptureSettings settings, {
    CameraDevice? camera,
    List<String>? allowedLocalIps,
    List<String>? allowedRemoteSubnets,
    bool includeSystemAudio = false,
    bool usbOnly = false,
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
    _captureUsbOnly = usbOnly;
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
          includeSystemAudio,
          usbOnly,
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
    bool includeSystemAudio,
    bool usbOnly,
  ) async {
    final session = ++_session;
    _setState(ScreenShareMode.sharing, 'Starting ${source.name} capture...');
    try {
      await _stop(server, updateState: false, invalidateSession: false);
      _checkSession(session);
      _source = source;
      _currentCamera = camera;
      _captureUsbOnly = usbOnly;
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
        await _setCameraAudioRecording(false);
        _checkSession(session);
        await _prepareCapture(session);
        final captureAudio = await _prepareSystemAudio(
          session,
          includeSystemAudio,
        );
        final constraints = await _videoConstraints();
        _checkSession(session);
        stream = await _getDisplayMediaWithForegroundRetry({
          'video': constraints,
          'audio': captureAudio,
        }, session);
        if (_isCurrentSession(session) && captureAudio) {
          await _attachSystemAudio(stream, session);
        }
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
      server.usbVideoOnly = usbOnly;
      if (source == VideoShareSource.camera) {
        server.cameraOfferHandler = (offer) {
          final offerSession = _session;
          return _withCameraLock(() {
            _checkSession(offerSession);
            return _answerOffer(offer);
          });
        };
        server.cameraMetadataHandler = _screenMetadata;
        server.cameraViewerStopHandler = _stopRemoteViewer;
        server.cameraControlHandler = _controlCamera;
        server.cameraAllowedRemoteSubnets = allowedRemoteSubnets == null
            ? null
            : List.unmodifiable(allowedRemoteSubnets);
      } else {
        server.screenOfferHandler = _answerOffer;
        server.screenMetadataHandler = _screenMetadata;
        server.screenViewerStopHandler = _stopRemoteViewer;
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

  Future<bool> _prepareSystemAudio(int session, bool requested) async {
    _screenSystemAudioStatus = ScreenSystemAudioStatus.off;
    if (!requested) return false;
    try {
      final supported = await supportsSystemAudio();
      _checkSession(session);
      if (!supported) {
        _screenSystemAudioStatus = ScreenSystemAudioStatus.unsupported;
        return false;
      }
      // Android requires RECORD_AUDIO for playback capture too. The native
      // playback route keeps the hardware microphone disabled throughout.
      final permission = await _permissions.request(Permission.microphone);
      _checkSession(session);
      if (!permission.isGranted) {
        _screenSystemAudioStatus = ScreenSystemAudioStatus.permissionDenied;
        return false;
      }
      return true;
    } catch (error) {
      _checkSession(session);
      _screenSystemAudioStatus = ScreenSystemAudioStatus.unavailable;
      _logger.warn('Device playback capture is unavailable: $error');
      return false;
    }
  }

  Future<void> _attachSystemAudio(MediaStream stream, int session) async {
    final track = stream.getAudioTracks().firstOrNull;
    if (track == null) {
      _screenSystemAudioStatus = ScreenSystemAudioStatus.unavailable;
      return;
    }
    try {
      _systemAudioRecordingConfigured = true;
      await _systemAudioRecordingGate(true);
      _checkSession(session);
      _screenSystemAudioStatus = ScreenSystemAudioStatus.active;
      track.onEnded = () {
        if (!_isCurrentSession(session) || _source != VideoShareSource.screen) {
          return;
        }
        _screenSystemAudioStatus = ScreenSystemAudioStatus.unavailable;
        unawaited(_stopSystemAudioRecording(preserveStatus: true));
        final current = state.value;
        _setState(current.mode, current.status, current.error);
      };
    } catch (error) {
      await _stopSystemAudioRecording(preserveStatus: true);
      track.onEnded = null;
      try {
        await stream.removeTrack(track);
        await track.stop();
      } catch (cleanupError) {
        _logger.warn(
          'Could not release unavailable playback track: $cleanupError',
        );
      }
      _checkSession(session);
      _screenSystemAudioStatus = ScreenSystemAudioStatus.unavailable;
      _logger.warn('Screen video continues without playback audio: $error');
    }
  }

  Future<void> _stopSystemAudioRecording({bool preserveStatus = false}) async {
    if (!preserveStatus) _screenSystemAudioStatus = ScreenSystemAudioStatus.off;
    if (!_systemAudioRecordingConfigured) return;
    _systemAudioRecordingConfigured = false;
    try {
      await _systemAudioRecordingGate(false);
    } catch (error) {
      _logger.warn('Could not stop device playback recording: $error');
      await _stopSharingPeers();
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
    // The Android screen-sharing card has no video preview. Keep its size and
    // rotation events without painting every captured frame into a hidden EGL
    // surface. Restore output when this renderer is reused for the camera.
    await localRenderer.setFrameOutputEnabled(
      !(WebRTC.platformIsAndroid && _source == VideoShareSource.screen),
    );
    _checkSession(session);
    await localRenderer.setSrcObject(stream: stream, trackId: videoTrack.id);
    if (_source == VideoShareSource.camera) {
      await _refreshCameraTorch(videoTrack, session);
      await _refreshCameraCaptureControls(videoTrack, session);
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
    ++_cameraControlRevision;
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

  Future<void> _refreshCameraCaptureControls(
    MediaStreamTrack track,
    int session,
  ) async {
    _cameraCaptureControls = const CameraCaptureControls();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (true) {
      _checkSession(session);
      if (_localStream?.getVideoTracks().firstOrNull?.id != track.id) return;
      try {
        final values = await _readCameraControls(
          track,
        ).timeout(const Duration(seconds: 5));
        _checkSession(session);
        if (_localStream?.getVideoTracks().firstOrNull?.id != track.id) return;
        if (values['ready'] != false) {
          final id = values['cameraId'] ?? _currentCamera?.id;
          if (id != _currentCamera?.id) {
            throw StateError('Capture controls returned another camera');
          }
          _cameraCaptureControls = CameraCaptureControls.fromMap({
            ...values,
            'cameraId': id,
            'trackId': track.id,
          });
          break;
        }
      } catch (error) {
        _checkSession(session);
        final retry =
            error is PlatformException &&
            (error.code == 'camera-not-ready' ||
                error.code == 'camera_not_ready');
        if (!retry || DateTime.now().isAfter(deadline)) {
          _logger.info(
            'Native camera capture controls are unavailable: $error',
          );
          break;
        }
      }
      if (DateTime.now().isAfter(deadline)) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    _notifyCameraControls();
  }

  /// Applies settings to the phone's live capture device and publishes only the
  /// state returned by that device. It never changes a received frame or widget.
  Future<void> setCameraCaptureSettings(Map<String, dynamic> settings) {
    if (_disposed) return Future.error(StateError('Video sharing is disposed'));
    final session = _session;
    final requested = Map<String, dynamic>.from(settings);
    final operation = _withCameraLock(() async {
      _requireCameraCapture(session);
      _validateCameraCaptureSettings(requested, _cameraCaptureControls);
      final track = _localStream!.getVideoTracks().first;
      final result = await _writeCameraControls(track, requested);
      _requireCameraCapture(session);
      if (_localStream?.getVideoTracks().firstOrNull?.id != track.id) {
        throw const CameraControlException('camera-control-session-ended');
      }
      final confirmed = CameraCaptureControls.fromMap({
        ...result,
        'cameraId': result['cameraId'] ?? _currentCamera?.id,
        'trackId': track.id,
      });
      if (!confirmed.available || confirmed.cameraId != _currentCamera?.id) {
        throw const CameraControlException('camera-control-failed');
      }
      _cameraCaptureControls = confirmed;
      _notifyCameraControls();
    });
    return operation.whenComplete(() {
      if (_isCurrentSession(session)) _notifyCameraControls();
    });
  }

  void _validateCameraCaptureSettings(
    Map<String, dynamic> settings,
    CameraCaptureControls controls,
  ) {
    const allowed = {
      'zoom',
      'whiteBalance',
      'whiteBalanceWarmth',
      'exposure',
      'brightness',
      'exposureMode',
      'exposureTimeMs',
      'iso',
    };
    if (settings.isEmpty ||
        settings.keys.any((key) => !allowed.contains(key))) {
      throw const CameraControlException(
        'invalid-camera-control',
        status: HttpStatus.badRequest,
      );
    }
    if (!controls.available) {
      throw const CameraControlException('camera-control-unsupported');
    }
    void numeric(String key, CameraNumericControl control) {
      if (!settings.containsKey(key)) return;
      if (!control.supported) {
        throw const CameraControlException('camera-control-unsupported');
      }
      final value = settings[key];
      if (value is! num || !control.accepts(value.toDouble())) {
        throw const CameraControlException(
          'invalid-camera-control',
          status: HttpStatus.badRequest,
        );
      }
    }

    numeric('zoom', controls.zoom);
    numeric('exposure', controls.exposure);
    numeric('brightness', controls.brightness);
    numeric('whiteBalanceWarmth', controls.whiteBalanceWarmth);
    if (settings.containsKey('whiteBalance') &&
        settings.containsKey('whiteBalanceWarmth')) {
      throw const CameraControlException(
        'invalid-camera-control',
        status: HttpStatus.badRequest,
      );
    }
    if (settings.containsKey('whiteBalance')) {
      if (!controls.whiteBalance.supported) {
        throw const CameraControlException('camera-control-unsupported');
      }
      if (!controls.whiteBalance.modes.contains(settings['whiteBalance'])) {
        throw const CameraControlException(
          'invalid-camera-control',
          status: HttpStatus.badRequest,
        );
      }
    }
    final manual = controls.manualExposure;
    if (settings.keys.any(
      (key) => key == 'exposureMode' || key == 'exposureTimeMs' || key == 'iso',
    )) {
      if (!manual.supported) {
        throw const CameraControlException('camera-control-unsupported');
      }
      if (settings.containsKey('exposureMode') &&
          settings['exposureMode'] != 'auto' &&
          settings['exposureMode'] != 'manual') {
        throw const CameraControlException(
          'invalid-camera-control',
          status: HttpStatus.badRequest,
        );
      }
      final mode = settings['exposureMode'] ?? manual.mode;
      if (mode != 'manual' &&
          (settings.containsKey('exposureTimeMs') ||
              settings.containsKey('iso'))) {
        throw const CameraControlException('camera-exposure-manual-required');
      }
      if (settings.containsKey('exposureTimeMs')) {
        final value = settings['exposureTimeMs'];
        if (value is! num ||
            !value.isFinite ||
            value < manual.timeMinMs ||
            value > manual.timeMaxMs) {
          throw const CameraControlException(
            'invalid-camera-control',
            status: HttpStatus.badRequest,
          );
        }
      }
      if (settings.containsKey('iso')) {
        final value = settings['iso'];
        if (value is! num ||
            !value.isFinite ||
            value != value.roundToDouble() ||
            value < manual.isoMin ||
            value > manual.isoMax) {
          throw const CameraControlException(
            'invalid-camera-control',
            status: HttpStatus.badRequest,
          );
        }
      }
    }
    if (settings.containsKey('exposure') &&
        (settings['exposureMode'] ?? manual.mode) == 'manual') {
      throw const CameraControlException('camera-exposure-auto-required');
    }
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
      await _refreshCurrentCaptureReadback(track, session);
      _notifyCameraControls();
    });
  }

  Future<void> _refreshCurrentCaptureReadback(
    MediaStreamTrack track,
    int session,
  ) async {
    try {
      final values = await _readCameraControls(
        track,
      ).timeout(const Duration(seconds: 5));
      _requireCameraCapture(session);
      if (_localStream?.getVideoTracks().firstOrNull?.id != track.id ||
          values['ready'] == false ||
          (values['cameraId'] != null &&
              values['cameraId'] != _currentCamera?.id)) {
        throw StateError(
          'The camera readback belongs to an unavailable capture',
        );
      }
      _cameraCaptureControls = CameraCaptureControls.fromMap({
        ...values,
        'cameraId': values['cameraId'] ?? _currentCamera?.id,
        'trackId': track.id,
      });
    } catch (error) {
      _requireCameraCapture(session);
      // Keep confirmed control values, but never label old sensor observations
      // as evidence for a newer command whose readback was unavailable.
      _cameraCaptureControls = CameraCaptureControls.fromMap({
        ..._cameraCaptureControls.toMap(),
        'observed': <String, dynamic>{},
      });
      _logger.info('Camera control readback is unavailable: $error');
    }
  }

  Future<void> _resetCameraTorch(MediaStream? stream) async {
    _cameraCaptureControls = const CameraCaptureControls();
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

  String? _remoteViewerId(Map<String, dynamic> offer) {
    final id = offer['viewerId'];
    return id is String && RegExp(r'^[a-zA-Z0-9-]{16,64}$').hasMatch(id)
        ? id
        : null;
  }

  Future<T> _serializeRemoteViewer<T>(String id, Future<T> Function() action) {
    final previous = _remoteViewerOperations[id] ?? Future<void>.value();
    final result = previous.then((_) => action());
    late final Future<void> settled;
    settled = result
        .then<void>((_) {}, onError: (Object error) {})
        .whenComplete(() {
          if (_remoteViewerOperations[id] == settled) {
            _remoteViewerOperations.remove(id);
          }
        });
    _remoteViewerOperations[id] = settled;
    return result;
  }

  Future<void> _stopRemoteViewer(String id) =>
      _serializeRemoteViewer(id, () async {
        final peer = _remoteViewers[id];
        if (peer != null) await _releaseSharingPeer(peer);
      });

  Map<String, dynamic> _cameraControlMetadata() => {
    'version': 1,
    'revision': _cameraControlRevision,
    'busy':
        _remoteCameraControlBusy ||
        isSwitchingCamera ||
        _microphoneOperation != null ||
        _cameraOperations != null,
    'microphoneEnabled': _cameraMicrophoneEnabled,
    'torchEnabled': _cameraTorchEnabled,
    'torchAvailable': _cameraTorchAvailable,
    'canSwitchCamera':
        _knownCameras.length > 1 ||
        _cameraCaptureControls.cameras.any(
          (camera) => camera.id != _currentCamera?.id,
        ),
    'capture': _cameraCaptureControls.toMap(),
  };

  void _requireRemoteController(int session, String viewerId, String token) {
    if (!_isCurrentSession(session) ||
        _source != VideoShareSource.camera ||
        _stopping ||
        _sharingServer == null) {
      throw const CameraControlException(
        'camera-share-not-active',
        status: HttpStatus.serviceUnavailable,
      );
    }
    final peer = _remoteViewers[viewerId];
    if (peer == null ||
        !_peers.contains(peer) ||
        _remoteControlTokens[peer] != token) {
      throw const CameraControlException(
        'camera-control-forbidden',
        status: HttpStatus.forbidden,
      );
    }
  }

  Future<CameraControlReply> _controlCamera(
    Map<String, dynamic> command,
  ) async {
    final viewerId = command['viewerId'];
    final token = command['token'];
    final action = command['action'];
    if (viewerId is! String || token is! String || action is! String) {
      throw const CameraControlException(
        'invalid-camera-control',
        status: HttpStatus.badRequest,
      );
    }
    final session = _session;
    _requireRemoteController(session, viewerId, token);
    if (action == 'stop') {
      final server = _sharingServer!;
      return CameraControlReply(
        {..._cameraControlMetadata(), 'stopping': true},
        afterResponse: () async {
          // The viewer may disconnect immediately after receiving the reply.
          // Authorization was checked above; only this capture session may end.
          _checkSession(session);
          if (_source != VideoShareSource.camera || _sharingServer != server) {
            return;
          }
          await stop(server, status: 'Camera share ended');
        },
      );
    }
    if (_remoteCameraControlBusy ||
        _microphoneOperation != null ||
        _switchingCamera != null ||
        _cameraOperations != null) {
      throw const CameraControlException('camera-control-busy');
    }
    if (action != 'microphone' &&
        action != 'torch' &&
        action != 'switch-camera' &&
        action != 'select-camera' &&
        action != 'capture-settings') {
      throw const CameraControlException(
        'invalid-camera-control',
        status: HttpStatus.badRequest,
      );
    }
    if ((action == 'microphone' || action == 'torch') &&
        command['enabled'] is! bool) {
      throw const CameraControlException(
        'invalid-camera-control',
        status: HttpStatus.badRequest,
      );
    }
    if (action == 'capture-settings' &&
        command['settings'] is! Map<String, dynamic>) {
      throw const CameraControlException(
        'invalid-camera-control',
        status: HttpStatus.badRequest,
      );
    }
    if (action == 'capture-settings' &&
        command['cameraId'] != null &&
        command['cameraId'] != _currentCamera?.id) {
      throw const CameraControlException('camera-control-session-ended');
    }
    if (action == 'capture-settings' &&
        command['captureTrackId'] != null &&
        command['captureTrackId'] != _localTrackId) {
      throw const CameraControlException('camera-control-session-ended');
    }
    if (action == 'select-camera' && command['cameraId'] is! String) {
      throw const CameraControlException(
        'invalid-camera-control',
        status: HttpStatus.badRequest,
      );
    }
    _remoteCameraControlBusy = true;
    _notifyCameraControls();
    try {
      if (action == 'microphone') {
        if (command['enabled'] == true) {
          final checkPermission = remoteMicrophonePermissionGranted;
          final granted = checkPermission != null
              ? await checkPermission()
              : !(WebRTC.platformIsAndroid || WebRTC.platformIsIOS) ||
                    (await _permissions.status(
                      Permission.microphone,
                    )).isGranted;
          _requireRemoteController(session, viewerId, token);
          if (!granted) {
            throw const CameraControlException(
              'camera-microphone-permission-denied',
            );
          }
        }
        await setCameraMicrophoneEnabled(command['enabled'] as bool);
      } else if (action == 'torch') {
        await setCameraTorchEnabled(command['enabled'] as bool);
      } else if (action == 'capture-settings') {
        await setCameraCaptureSettings(
          command['settings'] as Map<String, dynamic>,
        );
      } else if (action == 'select-camera') {
        final selected = _cameraCaptureControls.cameras
            .where((camera) => camera.id == command['cameraId'])
            .firstOrNull;
        if (selected == null) {
          throw const CameraControlException(
            'invalid-camera-control',
            status: HttpStatus.badRequest,
          );
        }
        await switchCamera(
          CameraDevice(
            id: selected.id,
            label: selected.label,
            frontFacing: selected.frontFacing,
          ),
          settings: _captureSettings,
        );
      } else {
        final cameras = await enumerateCameras();
        _requireRemoteController(session, viewerId, token);
        final next =
            cameras
                .where(
                  (camera) => camera.frontFacing != _currentCamera?.frontFacing,
                )
                .firstOrNull ??
            cameras
                .where((camera) => camera.id != _currentCamera?.id)
                .firstOrNull;
        if (next == null) {
          throw const CameraControlException('camera-switch-unavailable');
        }
        await switchCamera(next, settings: _captureSettings);
      }
      _requireRemoteController(session, viewerId, token);
    } on CameraControlException {
      rethrow;
    } catch (error) {
      _logger.warn('Remote camera $action failed: $error');
      final permissionDenied = error.toString().contains(
        'Microphone permission was denied',
      );
      throw CameraControlException(
        permissionDenied
            ? 'camera-microphone-permission-denied'
            : 'camera-control-failed',
      );
    } finally {
      if (_isCurrentSession(session)) {
        _remoteCameraControlBusy = false;
        _notifyCameraControls();
      }
    }
    return CameraControlReply(_cameraControlMetadata());
  }

  Future<Map<String, dynamic>> _answerOffer(Map<String, dynamic> offer) {
    final id = _remoteViewerId(offer);
    final session = _session;
    Future<Map<String, dynamic>> answer() async {
      _checkSession(session);
      final previous = _remoteViewers[id];
      if (previous != null) await _releaseSharingPeer(previous);
      _checkSession(session);
      return _answerOfferNow(offer, id);
    }

    return id == null ? answer() : _serializeRemoteViewer(id, answer);
  }

  Future<Map<String, dynamic>> _answerOfferNow(
    Map<String, dynamic> offer,
    String? viewerId,
  ) async {
    final session = _session;
    final stream = _localStream;
    if (stream == null || _stopping || _sharingServer == null) {
      throw StateError('Screen sharing is not active');
    }

    final usbConfiguration = offer.containsKey('usbRelay')
        ? UsbIceConfiguration.validate(offer['usbRelay'])
        : null;
    if (_sharingServer!.usbVideoOnly && usbConfiguration == null) {
      throw const FormatException('USB relay is required');
    }
    final remoteSdp = usbConfiguration == null
        ? offer['sdp'] as String
        : UsbIceConfiguration.relaySdp(offer['sdp'] as String);
    final peer = await _createPeer(usbConfiguration);
    _peers.add(peer);
    if (viewerId != null) _remoteViewers[viewerId] = peer;
    // An abandoned HTTP offer has no remote answer/ICE handshake. Dispose it
    // even if the SDK never leaves the `new` peer state.
    _sharingPeerDisconnectTimers[peer] = Timer(
      const Duration(seconds: 50),
      () => unawaited(_releaseSharingPeer(peer)),
    );
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
          if (offer['compatibilityMode'] == true) {
            _compatibilitySenders.add(sender);
          }
        }
      }

      await peer.setRemoteDescription(
        RTCSessionDescription(remoteSdp, offer['type'] as String),
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
      _checkSession(session);
      // Native senders may have no encodings before SDP is negotiated. Limits
      // applied then are silently ignored by the desktop implementation.
      final sender = _videoSenders[peer];
      if (sender != null) await _configureLowLatencyVideoSender(sender);
      await _waitForIceGatheringComplete(peer);
      final local = await peer.getLocalDescription();
      _checkSession(session);
      _requireLocalCandidates(local?.sdp ?? answer.sdp ?? '');
      return {
        'type': local?.type ?? answer.type,
        'sdp': usbConfiguration == null
            ? _restrictLocalCandidates(local?.sdp ?? answer.sdp ?? '')
            : UsbIceConfiguration.relaySdp(local?.sdp ?? answer.sdp ?? ''),
        if (_source == VideoShareSource.camera && viewerId != null)
          'cameraControls': {
            'token': _remoteControlTokens.putIfAbsent(
              peer,
              () => const Uuid().v4(),
            ),
            ..._cameraControlMetadata(),
          },
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
      const Duration(seconds: 15),
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

  /// Signaling and both relay connections are owned by this viewer session.
  /// There is no LAN candidate or Wi-Fi fallback when the cable is selected.
  Future<void> watchUsb(
    UsbAdbDevice device, {
    VideoShareSource source = VideoShareSource.screen,
    int remotePort = 53317,
  }) async {
    if (_disposed || _localStream != null || _startingShare != null) {
      throw StateError('Stop local capture before opening USB');
    }
    final stopping = stopWatching();
    final generation = ++_usbOpeningGeneration;
    await stopping;
    if (_disposed || generation != _usbOpeningGeneration) {
      throw StateError('USB connection was cancelled');
    }
    final relay = await _usbTransport.open(device, remotePort: remotePort);
    if (_disposed || generation != _usbOpeningGeneration) {
      await relay.close();
      throw StateError('USB connection was cancelled');
    }
    try {
      await _watchSource(
        DeviceInfo(
          id: 'usb-${device.serial}-${device.transportId}',
          name: device.label,
          platform: 'Android',
          ip: relay.signalingUri.host,
          port: relay.signalingUri.port,
          lastSeen: DateTime.now(),
        ),
        source,
        usbSession: relay,
      );
    } catch (_) {
      await relay.close();
      rethrow;
    }
  }

  Future<void> _watchSource(
    DeviceInfo device,
    VideoShareSource source, {
    List<String>? allowedLocalIps,
    UsbRelaySession? usbSession,
  }) {
    if (usbSession == null) ++_usbOpeningGeneration;
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
        _sameLocalIps(_allowedLocalIps, allowedLocalIps) &&
        identical(_usbViewerSession, usbSession);
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
    operation = _watch(device, source, allowed, usbSession).whenComplete(() {
      if (_watching == operation) _watching = null;
    });
    _watching = operation;
    return operation;
  }

  Future<void> _watch(
    DeviceInfo device,
    VideoShareSource source,
    List<String>? allowedLocalIps,
    UsbRelaySession? usbSession,
  ) async {
    final session = ++_session;
    _setViewerConnecting();
    await _stoppingFuture;
    if (!_isCurrentSession(session)) {
      await usbSession?.close();
      return;
    }
    await _stopViewer();
    if (!_isCurrentSession(session)) {
      await usbSession?.close();
      return;
    }
    _source = source;
    _usbViewerSession = usbSession;
    _viewerCompatibility = false;
    _viewerId = const Uuid().v4();
    _viewerStopUri = device.baseUri.replace(
      path: '/api/${source.name}/stop-viewer',
    );
    _allowedLocalIps = allowedLocalIps;
    _configureBoundSignaling(
      usbSession == null ? allowedLocalIps : ['127.0.0.1'],
      device.ip,
    );
    _viewerRequests = CancelToken();
    try {
      await initialize();
      _checkSession(session);
      _startMetadataPolling(device, session);
      final peer = await _connectViewerWithFallback(device, session);
      _checkSession(session);
      _monitorViewerDecode(peer, device, session);
    } catch (error) {
      if (!_isCurrentSession(session)) {
        await _viewerStopping;
        return;
      }
      await _failViewer(session, _connectionFailure(error), error);
      rethrow;
    }
  }

  /// Stops only the viewer. File transfers keep their own server and lifecycle.
  Future<void> stopWatching({String status = 'Idle'}) async {
    ++_usbOpeningGeneration;
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

  void _emitRemoteCameraControls() {
    if (_disposed) return;
    final controls = _remoteCameraSnapshot;
    remoteCameraControls.value = RemoteCameraControls(
      available:
          _source == VideoShareSource.camera &&
          _viewerControlToken != null &&
          _viewerPeer != null &&
          controls.available,
      busy: _remoteControlOperation != null || controls.busy,
      microphoneEnabled: controls.microphoneEnabled,
      torchEnabled: controls.torchEnabled,
      torchAvailable: controls.torchAvailable,
      canSwitchCamera: controls.canSwitchCamera,
      capture: controls.capture,
    );
  }

  void _applyRemoteCameraControls(Map<String, dynamic> controls) {
    if (controls['version'] != 1) return;
    final revision = controls['revision'];
    if (revision is! int || revision < _remoteControlRevision) return;
    _remoteControlRevision = revision;
    _remoteCameraSnapshot = RemoteCameraControls(
      available: true,
      busy: controls['busy'] == true,
      microphoneEnabled: controls['microphoneEnabled'] == true,
      torchEnabled: controls['torchEnabled'] == true,
      torchAvailable: controls['torchAvailable'] == true,
      canSwitchCamera: controls['canSwitchCamera'] == true,
      capture: CameraCaptureControls.fromMap(controls['capture']),
    );
    _emitRemoteCameraControls();
  }

  Future<void> setRemoteCameraMicrophoneEnabled(bool enabled) =>
      _sendRemoteCameraControl('microphone', enabled: enabled);

  Future<void> setRemoteCameraTorchEnabled(bool enabled) =>
      _sendRemoteCameraControl('torch', enabled: enabled);

  Future<void> switchRemoteCamera() =>
      _sendRemoteCameraControl('switch-camera');

  /// Ends the phone's camera broadcast. [stopWatching] only disconnects this PC.
  Future<void> stopRemoteCameraSharing() => _sendRemoteCameraControl('stop');

  Future<void> setRemoteCameraZoom(double value) =>
      _sendRemoteCameraControl('capture-settings', settings: {'zoom': value});
  Future<void> setRemoteCameraWhiteBalance(String value) =>
      _sendRemoteCameraControl(
        'capture-settings',
        settings: {'whiteBalance': value},
      );
  Future<void> setRemoteCameraWhiteBalanceWarmth(double value) =>
      _sendRemoteCameraControl(
        'capture-settings',
        settings: {'whiteBalanceWarmth': value},
      );
  Future<void> setRemoteCameraExposure(double value) =>
      _sendRemoteCameraControl(
        'capture-settings',
        settings: {'exposure': value},
      );
  Future<void> setRemoteCameraBrightness(double value) =>
      _sendRemoteCameraControl(
        'capture-settings',
        settings: {'brightness': value},
      );
  Future<void> setRemoteCameraExposureMode(String value) =>
      _sendRemoteCameraControl(
        'capture-settings',
        settings: {'exposureMode': value},
      );
  Future<void> setRemoteCameraExposureTime(double milliseconds) =>
      _sendRemoteCameraControl(
        'capture-settings',
        settings: {'exposureTimeMs': milliseconds},
      );
  Future<void> setRemoteCameraIso(int value) =>
      _sendRemoteCameraControl('capture-settings', settings: {'iso': value});
  Future<void> selectRemoteCamera(String cameraId) =>
      _sendRemoteCameraControl('select-camera', cameraId: cameraId);

  Future<void> _sendRemoteCameraControl(
    String action, {
    bool? enabled,
    Map<String, dynamic>? settings,
    String? cameraId,
  }) {
    if (_remoteControlOperation != null) {
      return Future.error(const CameraControlException('camera-control-busy'));
    }
    final device = _watchedDevice;
    final id = _viewerId;
    final token = _viewerControlToken;
    if (_disposed ||
        device == null ||
        id == null ||
        token == null ||
        _source != VideoShareSource.camera ||
        state.value.mode != ScreenShareMode.watching ||
        _viewerPeer == null) {
      return Future.error(
        const CameraControlException('camera-control-unavailable'),
      );
    }
    final session = _session;
    if (settings != null) {
      try {
        _validateCameraCaptureSettings(settings, _remoteCameraSnapshot.capture);
      } catch (error, stack) {
        return Future.error(error, stack);
      }
    }
    final targetCameraId =
        cameraId ??
        (settings != null ? _remoteCameraSnapshot.capture.cameraId : null);
    final targetCaptureTrackId = settings != null
        ? _remoteCameraSnapshot.capture.trackId
        : null;
    late final Future<void> operation;
    operation = Future<void>(() async {
      try {
        final response = await (_boundSignalingClient ?? _dio)
            .postUri<Map<String, dynamic>>(
              device.baseUri.replace(path: '/api/camera/control'),
              cancelToken: _viewerRequests,
              data: {
                'viewerId': id,
                'token': token,
                'action': action,
                'enabled': ?enabled,
                'settings': ?settings,
                'cameraId': ?targetCameraId,
                'captureTrackId': ?targetCaptureTrackId,
              },
              options: Options(
                connectTimeout: const Duration(seconds: 3),
                sendTimeout: const Duration(seconds: 3),
                receiveTimeout: const Duration(seconds: 15),
              ),
            );
        _checkSession(session);
        if (_viewerControlToken != token) {
          throw const CameraControlException('camera-control-session-ended');
        }
        if (response.data?['ok'] != true) {
          throw const CameraControlException('camera-control-failed');
        }
        if (action == 'stop') {
          await stopWatching(status: 'Camera share ended');
        } else {
          final controls = response.data?['controls'];
          if (controls is! Map<String, dynamic>) {
            throw const CameraControlException('camera-control-failed');
          }
          _applyRemoteCameraControls(controls);
        }
      } on DioException catch (error) {
        final data = error.response?.data;
        final code = data is Map ? data['error'] : null;
        throw CameraControlException(
          code is String ? code : 'camera-control-failed',
          status: error.response?.statusCode ?? HttpStatus.serviceUnavailable,
        );
      } finally {
        if (identical(_remoteControlOperation, operation)) {
          _remoteControlOperation = null;
          _emitRemoteCameraControls();
        }
      }
    });
    _remoteControlOperation = operation;
    _emitRemoteCameraControls();
    return operation;
  }

  Future<RTCPeerConnection> _connectViewerPeer(
    DeviceInfo device,
    int session,
  ) async {
    // Receiving camera audio requires playout, with no local microphone capture.
    await _setCameraAudioRecording(false);
    _checkSession(session);
    final usb = _usbViewerSession;
    final peer = await _createPeer(usb?.desktopIceConfiguration);
    try {
      _checkSession(session);
      _viewerPeer = peer;
      _viewerHasVideo = false;
      _viewerIceState = null;
      await peer.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      await peer.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      peer.onIceConnectionState = (state) {
        _logger.info('Screen share viewer ICE state: $state');
        if (!_isCurrentSession(session) || _viewerPeer != peer) return;
        _viewerIceState = state;
        if (state == RTCIceConnectionState.RTCIceConnectionStateClosed ||
            state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          unawaited(
            _failViewer(
              session,
              VideoConnectionFailure.network,
              StateError('WebRTC media connection failed: $state'),
            ),
          );
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
        if (event.track.kind == 'audio') {
          _remoteAudioTrack = event.track;
          return;
        }
        _remoteVideoTrack = event.track;
        event.track.onEnded = () {
          if (_isCurrentSession(session) && _viewerPeer == peer) {
            unawaited(_handleRemoteEnded(_endedStatus));
          }
        };
        if (event.streams.isNotEmpty) {
          final stream = event.streams.first;
          try {
            await remoteRenderer.setFrameOutputEnabled(
              remotePreviewEnabled.value,
            );
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
        'offerToReceiveAudio': 1,
      });
      final preferredOffer = RTCSessionDescription(
        VideoSdpPolicy.offer(
          offer.sdp ?? '',
          compatibility: _viewerCompatibility,
        ),
        offer.type,
      );
      await peer.setLocalDescription(preferredOffer);
      await _waitForIceGatheringComplete(peer);
      final local = await peer.getLocalDescription();

      _checkSession(session);
      _requireLocalCandidates(local?.sdp ?? preferredOffer.sdp ?? '');
      final response = await (_boundSignalingClient ?? _dio)
          .postUri<Map<String, dynamic>>(
            device.baseUri.replace(path: '/api/${_source.name}/offer'),
            cancelToken: _viewerRequests,
            data: {
              'type': local?.type ?? preferredOffer.type,
              'viewerId': _viewerId,
              if (_viewerCompatibility) 'compatibilityMode': true,
              if (usb != null) 'usbRelay': usb.androidIceConfiguration,
              'sdp': usb != null
                  ? UsbIceConfiguration.relaySdp(
                      local?.sdp ?? preferredOffer.sdp ?? '',
                    )
                  : _restrictLocalCandidates(
                      VideoSdpPolicy.offer(
                        local?.sdp ?? preferredOffer.sdp ?? '',
                        compatibility: _viewerCompatibility,
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
      final answerSdp = usb == null
          ? answer['sdp'] as String
          : UsbIceConfiguration.relaySdp(answer['sdp'] as String);
      _logger.info(
        'Screen share negotiated codec: '
        '${VideoSdpPolicy.firstVideoCodec(answerSdp) ?? 'rejected'}',
      );
      try {
        if (VideoSdpPolicy.firstVideoCodec(answerSdp) == null) {
          throw StateError('The sender rejected video negotiation');
        }
        await peer.setRemoteDescription(
          RTCSessionDescription(answerSdp, answer['type'] as String),
        );
      } catch (error) {
        throw _VideoNegotiationFailure(error);
      }
      _checkSession(session);
      final controls = answer['cameraControls'];
      if (_source == VideoShareSource.camera &&
          controls is Map<String, dynamic>) {
        final token = controls['token'];
        if (token is String &&
            RegExp(r'^[a-zA-Z0-9-]{16,64}$').hasMatch(token)) {
          if (_viewerControlToken != token) _remoteControlRevision = -1;
          _viewerControlToken = token;
          _applyRemoteCameraControls(controls);
        }
      }
      return peer;
    } catch (_) {
      if (_viewerPeer == peer) _viewerPeer = null;
      await _closePeer(peer);
      rethrow;
    }
  }

  Future<RTCPeerConnection> _connectViewerWithFallback(
    DeviceInfo device,
    int session,
  ) async {
    try {
      return await _connectViewerPeer(device, session);
    } catch (error) {
      _checkSession(session);
      final remoteCodecFailure =
          error is DioException &&
          error.response?.statusCode == HttpStatus.internalServerError &&
          RegExp(
            r'codec|video|m-line|media section|rtp',
            caseSensitive: false,
          ).hasMatch(error.response?.data.toString() ?? '');
      if (_viewerCompatibility ||
          (error is! _VideoNegotiationFailure && !remoteCodecFailure)) {
        rethrow;
      }
      _logger.warn('Video negotiation failed; retrying VP8: $error');
      _viewerCompatibility = true;
      _setViewerConnecting(compatibility: true);
      return _connectViewerPeer(device, session);
    }
  }

  void _monitorViewerDecode(
    RTCPeerConnection peer,
    DeviceInfo device,
    int session,
  ) {
    if (!_isCurrentSession(session) || _viewerPeer != peer) return;
    _viewerStatsTimer?.cancel();
    _viewerStartupTimer?.cancel();
    if (!_viewerHasVideo) {
      _viewerStartupTimer = Timer(videoStartupTimeout, () {
        if (!_isCurrentSession(session) ||
            _viewerPeer != peer ||
            _viewerHasVideo) {
          return;
        }
        final ice = _viewerIceState;
        if (ice == RTCIceConnectionState.RTCIceConnectionStateChecking ||
            ice == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          unawaited(
            _failViewer(
              session,
              VideoConnectionFailure.network,
              TimeoutException('No media connection; check the LAN firewall'),
            ),
          );
        } else {
          unawaited(_retryViewerVideo(device, session));
        }
      });
    }
    var samples = 0;
    Future<void> sample() async {
      if (!_isCurrentSession(session) || _viewerPeer != peer) return;
      samples++;
      try {
        final reports = await peer.getStats().timeout(
          const Duration(seconds: 5),
        );
        if (!_isCurrentSession(session) || _viewerPeer != peer) return;
        for (final report in reports) {
          if (report.type != 'inbound-rtp') continue;
          final values = report.values;
          final kind = values['kind'] ?? values['mediaType'];
          if (kind == 'audio') continue;
          final codecId = values['codecId'];
          final codec = reports.where((r) => r.id == codecId).firstOrNull;
          _logger.info(
            'Remote screen inbound video: '
            'bytes=${values['bytesReceived'] ?? '-'}, '
            'packets=${values['packetsReceived'] ?? '-'}, '
            'frames=${values['framesReceived'] ?? '-'}, '
            'decoded=${values['framesDecoded'] ?? '-'}, '
            'dropped=${values['framesDropped'] ?? '-'}, '
            'codec=${codec?.values['mimeType'] ?? codecId ?? '-'}, '
            'decoder=${values['decoderImplementation'] ?? '-'}',
          );
          if ((num.tryParse('${values['framesDecoded']}') ?? 0) > 0 &&
              remoteRenderer.srcObject != null) {
            _markViewerVideoReady();
          }
        }
      } catch (error) {
        _logger.warn('Could not read screen viewer stats: $error');
      }
      // A report with zero decoded frames is not a successful stream.
      if (!_viewerHasVideo &&
          samples < 12 &&
          _isCurrentSession(session) &&
          _viewerPeer == peer) {
        _viewerStatsTimer = Timer(const Duration(seconds: 2), sample);
      }
    }

    _viewerStatsTimer = Timer(const Duration(seconds: 2), sample);
  }

  Future<void> _retryViewerVideo(DeviceInfo device, int session) async {
    if (!_isCurrentSession(session) || _reconnectingViewer) return;
    if (_viewerCompatibility) {
      await _failViewer(
        session,
        VideoConnectionFailure.video,
        TimeoutException('No decoded video after the compatibility retry'),
      );
      return;
    }
    _viewerCompatibility = true;
    _logger.warn('No video frames; retrying VP8 at up to 720p / 30 FPS');
    await _reconnectViewer(device, session);
  }

  Future<void> _failViewer(
    int session,
    VideoConnectionFailure failure,
    Object error,
  ) async {
    if (!_isCurrentSession(session)) return;
    _logger.warn('Video viewer failed ($failure): $error');
    final endpoint = error is DioException
        ? error.requestOptions.uri.authority
        : _watchedDevice?.baseUri.authority;
    final stoppedSession = ++_session;
    _watching = null;
    _watchedDevice = null;
    await _stopViewer();
    if (!_isCurrentSession(stoppedSession)) return;
    state.value = ScreenShareState(
      mode: ScreenShareMode.idle,
      status: 'Could not connect',
      error: error.toString(),
      failure: failure,
      endpoint: endpoint,
    );
  }

  VideoConnectionFailure _connectionFailure(Object error) {
    if (error is DioException) {
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout) {
        return VideoConnectionFailure.connectionTimeout;
      }
      if (error.type == DioExceptionType.connectionError) {
        final cause = error.error;
        return cause is SocketException &&
                const [111, 61, 10061].contains(cause.osError?.errorCode)
            ? VideoConnectionFailure.connectionRefused
            : VideoConnectionFailure.network;
      }
    }
    return VideoConnectionFailure.signaling;
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
      'audio': _source == VideoShareSource.camera
          ? _cameraMicrophoneEnabled
          : _screenSystemAudioStatus == ScreenSystemAudioStatus.active,
      if (_source == VideoShareSource.camera) 'cameraId': _currentCamera?.id,
      if (_source == VideoShareSource.camera)
        'cameraControls': _cameraControlMetadata(),
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
      final controls = metadata?['cameraControls'];
      if (_source == VideoShareSource.camera &&
          controls is Map<String, dynamic>) {
        _applyRemoteCameraControls(controls);
      }
      final aspectRatio = (metadata?['aspectRatio'] as num?)?.toDouble();
      if (_isHealthyAspectRatio(aspectRatio)) {
        remoteAspectRatio.value = aspectRatio;
      }
      final generation = (metadata?['generation'] as num?)?.toInt();
      if (generation != null) {
        final previous = _lastRemoteGeneration;
        if (previous == null) {
          _lastRemoteGeneration = generation;
        } else if (generation != previous &&
            _watching == null &&
            !_reconnectingViewer) {
          // Keep the old generation during startup. The next poll will pick
          // it up after that offer finishes, without racing a second peer.
          _lastRemoteGeneration = generation;
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
    _viewerReconnectSession = session;
    try {
      _logger.info('Reconnecting viewer (compatibility=$_viewerCompatibility)');
      _setViewerConnecting(compatibility: _viewerCompatibility);
      await _stopViewer(keepMetadataPolling: true);
      _checkSession(session);
      final peer = await _connectViewerWithFallback(device, session);
      _checkSession(session);
      _monitorViewerDecode(peer, device, session);
    } catch (error) {
      if (_isCurrentSession(session)) {
        _logger.warn('Screen viewer reconnect failed: $error');
        await _failViewer(
          session,
          error is DioException
              ? _connectionFailure(error)
              : VideoConnectionFailure.video,
          error,
        );
      }
    } finally {
      if (_viewerReconnectSession == session) _viewerReconnectSession = null;
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

  Future<RTCPeerConnection> _createPeer([Map<String, dynamic>? configuration]) {
    if (configuration == null) return _peerConnectionFactory();
    // Source configurations were validated at the HTTP-offer boundary. Viewer
    // configurations come from its owned cable bridge, including any local-PC
    // socket endpoint required by the desktop SDK's interface binding.
    return configuredPeerConnectionFactory?.call(configuration) ??
        createPeerConnection(configuration);
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
      final compatibility = _compatibilitySenders.contains(sender);
      var scale = options.scaleFor(size.width, size.height);
      final maxFps = compatibility
          ? options.frameRate.clamp(1, 30)
          : options.frameRate;
      final maxBitrate = compatibility
          ? options.maxBitrate.clamp(1, 2500000)
          : options.maxBitrate;
      if (compatibility) {
        final width = size.width;
        final height = size.height;
        final shorter = width < height ? width : height;
        final longer = width > height ? width : height;
        // Tall phone screens also need a long-edge cap; 720x1760 is heavier
        // than 1280x720 despite both being called "720p" in settings.
        for (final limit in [shorter / 720, longer / 1280]) {
          if (limit.isFinite && limit > scale) scale = limit;
        }
      }
      final parameters = sender.parameters;
      parameters.degradationPreference = RTCDegradationPreference.BALANCED;
      final encodings = parameters.encodings;
      if (encodings == null || encodings.isEmpty) {
        parameters.encodings = [
          RTCRtpEncoding(
            maxBitrate: maxBitrate,
            maxFramerate: maxFps,
            scaleResolutionDownBy: scale,
            priority: RTCPriorityType.high,
            networkPriority: RTCPriorityType.high,
          ),
        ];
      } else {
        for (final encoding in encodings) {
          encoding.maxBitrate = maxBitrate;
          encoding.minBitrate = null;
          encoding.maxFramerate = maxFps;
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
    timeout = Timer(iceGatheringTimeout, finish);
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

  void _requireLocalCandidates(String sdp) {
    if (!RegExp(r'^a=candidate:', multiLine: true).hasMatch(sdp)) {
      throw StateError('WebRTC found no local network address for video');
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
      await _stopSystemAudioRecording();
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
      _captureUsbOnly = false;
      if (wasSharing) await onSharingStopped?.call();
    } finally {
      _stopping = false;
    }
  }

  Future<void> dispose() {
    if (_disposing != null) return _disposing!;
    _disposed = true;
    ++_usbOpeningGeneration;
    ++_session;
    _cameraLifecycle.dispose();
    _cancelCameraControls();
    _cancelViewerRequests();
    return _disposing = _disposeResources();
  }

  Future<void> _disposeResources() async {
    _logger.info('Disposing screen share resources');
    await _stopSystemAudioRecording();
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
      remotePreviewEnabled.dispose();
      remoteCameraControls.dispose();
      focusedViewerActive.dispose();
      state.dispose();
      _dio.close(force: true);
    }
  }

  Future<void> _stopSharingPeers() async {
    _remoteCameraControlBusy = false;
    _remoteControlTokens.clear();
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
    _remoteControlTokens.remove(peer);
    _remoteViewers.removeWhere((_, value) => value == peer);
    _compatibilitySenders.remove(_videoSenders.remove(peer));
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
    _viewerStartupTimer?.cancel();
    _viewerStartupTimer = null;
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

  Future<void> _stopViewer({bool keepMetadataPolling = false}) {
    final previous = _viewerStopping ?? Future<void>.value();
    late final Future<void> operation;
    operation = previous
        .then((_) => _disposeViewer(keepMetadataPolling: keepMetadataPolling))
        .whenComplete(() {
          if (_viewerStopping == operation) _viewerStopping = null;
        });
    _viewerStopping = operation;
    return operation;
  }

  Future<void> _disposeViewer({required bool keepMetadataPolling}) async {
    _viewerStartupTimer?.cancel();
    _viewerStartupTimer = null;
    _viewerStatsTimer?.cancel();
    _viewerStatsTimer = null;
    if (!keepMetadataPolling) {
      _viewerControlToken = null;
      _remoteControlRevision = -1;
      _remoteCameraSnapshot = const RemoteCameraControls();
      _emitRemoteCameraControls();
      _cancelViewerRequests();
      _lastRemoteGeneration = null;
      remoteAspectRatio.value = null;
    }
    final peer = _viewerPeer;
    final beforeDetach = beforeRemoteMediaDetach;
    if (peer != null && beforeDetach != null) {
      try {
        await beforeDetach();
      } catch (_) {
        _logger.warn('Could not finalize local camera media before disconnect');
      }
    }
    _viewerPeer = null;
    _remoteVideoTrack = null;
    _remoteAudioTrack = null;
    await _detachRenderer(remoteRenderer);
    if (peer != null) await _closePeer(peer);
    if (!keepMetadataPolling) {
      if (!_disposed) remotePreviewEnabled.value = true;
      final id = _viewerId;
      final uri = _viewerStopUri;
      _viewerId = null;
      _viewerStopUri = null;
      if (id != null && uri != null) {
        try {
          // Older releases have no stop endpoint; their ICE timeout still
          // releases the sender. Stop must remain bounded on an offline LAN.
          await (_boundSignalingClient ?? _dio).postUri<void>(
            uri,
            data: {'viewerId': id},
            options: Options(
              connectTimeout: const Duration(seconds: 2),
              sendTimeout: const Duration(seconds: 2),
              receiveTimeout: const Duration(seconds: 2),
            ),
          );
        } catch (error) {
          _logger.info('Remote viewer cleanup unavailable: $error');
        }
      }
      _boundSignalingClient?.close(force: true);
      _boundSignalingClient = null;
      final usb = _usbViewerSession;
      _usbViewerSession = null;
      try {
        await usb?.close();
      } catch (_) {
        _logger.warn('USB viewer cleanup did not complete');
      }
    }
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
    server.usbVideoOnly = false;
    server.screenOfferHandler = null;
    server.screenMetadataHandler = null;
    server.screenViewerStopHandler = null;
    server.cameraOfferHandler = null;
    server.cameraMetadataHandler = null;
    server.cameraViewerStopHandler = null;
    server.cameraControlHandler = null;
    server.cameraAllowedRemoteSubnets = null;
  }
}

class _VideoNegotiationFailure implements Exception {
  const _VideoNegotiationFailure(this.cause);
  final Object cause;
  @override
  String toString() => 'Video negotiation failed: $cause';
}
