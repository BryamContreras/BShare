import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/infrastructure/services/android_screen_share_execution_service.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/file_server.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

enum ScreenShareMode { idle, sharing, watching }

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

class ScreenShareService {
  ScreenShareService(this._logger, this._screenShareExecution);

  static const int _androidMaxBitrate = 3500000;
  static const int _desktopMaxBitrate = 8000000;
  static const int _desktopMinBitrate = 1800000;
  static const int _androidMaxFramerate = 24;
  static const int _desktopMaxFramerate = 30;
  static const String _screenCodec = 'H264';
  static const Duration _metadataPollInterval = Duration(milliseconds: 180);
  static const Duration _androidForegroundServiceSettleDelay = Duration(
    milliseconds: 650,
  );

  final AppLogger _logger;
  final AndroidScreenShareExecutionService _screenShareExecution;
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
    ),
  );
  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
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
  Timer? _androidMetricsPollTimer;
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
    state.value = ScreenShareState(mode: mode, status: status, error: error);
  }

  /// Indicates that the compact preview has been replaced by the focused view.
  /// Both views reuse [remoteRenderer], but only one of them is mounted.
  void setFocusedViewerActive(bool active) {
    if (focusedViewerActive.value == active) return;
    focusedViewerActive.value = active;
  }

  Future<void> initialize() async {
    if (_initialized) return;
    await localRenderer.initialize();
    await remoteRenderer.initialize();
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

  Future<void> startSharing(FileServer server) async {
    await initialize();
    _setState(ScreenShareMode.sharing, 'Starting screen capture...');
    try {
      await _stop(server, updateState: false);
      _setState(ScreenShareMode.sharing, 'Starting screen capture...');
      await _prepareCapture();
      _localStream = await _getDisplayMediaWithForegroundRetry({
        'video': await _videoConstraints(),
        'audio': false,
      });
      final videoTrack = _localStream?.getVideoTracks().firstOrNull;
      _localTrackId = videoTrack?.id;
      videoTrack?.onEnded = () {
        unawaited(_handleLocalTrackEnded(server));
      };
      _screenGeneration++;
      localRenderer.srcObject = _localStream;
      server.screenOfferHandler = _answerOffer;
      server.screenMetadataHandler = _screenMetadata;
      _startAndroidMetricsPolling();
      _setState(ScreenShareMode.sharing, 'Sharing screen on LAN');
    } catch (error) {
      await _stop(server, updateState: false);
      _setState(ScreenShareMode.idle, 'Screen share stopped', error.toString());
      rethrow;
    }
  }

  Future<void> _handleLocalTrackEnded(FileServer server) async {
    if (_localStream == null || _stopping) return;
    _logger.info('Local screen-share track ended');
    await stop(server, status: 'Screen share ended');
  }

  Future<MediaStream> _getDisplayMediaWithForegroundRetry(
    Map<String, dynamic> constraints,
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
      await _restartAndroidScreenShareExecution();
      return navigator.mediaDevices.getDisplayMedia(constraints);
    }
  }

  bool _isMediaProjectionForegroundError(Object error) {
    final message = error.toString();
    return message.contains('FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION') ||
        message.contains('mediaProjection');
  }

  Future<Map<String, dynamic>> _answerOffer(Map<String, dynamic> offer) async {
    final stream = _localStream;
    if (stream == null) {
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
      for (final track in stream.getTracks()) {
        final sender = await peer.addTrack(track, stream);
        if (track.kind == 'video') {
          await _configureLowLatencyVideoSender(sender);
        }
      }

      await peer.setRemoteDescription(
        RTCSessionDescription(offer['sdp'] as String, offer['type'] as String),
      );
      final answer = await peer.createAnswer();
      await peer.setLocalDescription(answer);
      await _waitForIceGatheringComplete(peer);
      final local = await peer.getLocalDescription();
      return {
        'type': local?.type ?? answer.type,
        'sdp': local?.sdp ?? answer.sdp ?? '',
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
        final currentState = await peer.getConnectionState();
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
    peer.onConnectionState = null;
    peer.onIceConnectionState = null;
    try {
      await peer.close();
    } catch (error) {
      _logger.warn('Screen share sender peer cleanup failed: $error');
    }
  }

  Future<void> watch(DeviceInfo device) async {
    await initialize();
    _setState(ScreenShareMode.watching, 'Connecting to screen share...');
    await _stopViewer();
    _lastRemoteGeneration = null;
    remoteAspectRatio.value = null;
    try {
      _startMetadataPolling(device);
      _viewerPeer = await _connectViewerPeer(device);
      unawaited(_monitorViewerDecode(_viewerPeer!));
      _setState(ScreenShareMode.watching, 'Watching remote screen');
    } catch (error) {
      await _stopViewer();
      _setState(ScreenShareMode.idle, 'Could not connect', error.toString());
      rethrow;
    }
  }

  /// Stops only the remote viewer peer. It intentionally leaves the local
  /// receiver/server alone because closing a viewer must not stop file sharing.
  Future<void> stopWatching({String status = 'Idle'}) async {
    if (_viewerPeer == null && state.value.mode != ScreenShareMode.watching) {
      return;
    }
    await _stopViewer();
    _setState(ScreenShareMode.idle, status);
  }

  Future<RTCPeerConnection> _connectViewerPeer(DeviceInfo device) async {
    final peer = await _createPeer();
    await peer.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );
    peer.onIceConnectionState = (state) {
      _logger.info('Screen share viewer ICE state: $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateClosed ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        unawaited(_handleRemoteEnded('Screen share ended'));
      }
    };
    peer.onTrack = (event) {
      _logger.info(
        'Screen share viewer received track: ${event.track.kind} '
        '(streams: ${event.streams.length})',
      );
      event.track.onEnded = () {
        unawaited(_handleRemoteEnded('Screen share ended'));
      };
      if (event.streams.isNotEmpty) {
        try {
          event.track.enabled = true;
        } catch (_) {}
        final stream = event.streams.first;
        remoteRenderer.srcObject = stream;
        _logger.info(
          'Remote screen stream tracks: '
          '${stream.getVideoTracks().map((track) => track.id).join(', ')}',
        );
      }
    };

    final offer = await peer.createOffer({
      'offerToReceiveVideo': 1,
      'offerToReceiveAudio': 0,
    });
    final preferredOffer = RTCSessionDescription(
      _preferVideoCodec(offer.sdp ?? '', _screenCodec),
      offer.type,
    );
    await peer.setLocalDescription(preferredOffer);
    await _waitForIceGatheringComplete(peer);
    final local = await peer.getLocalDescription();

    final response = await _dio.postUri<Map<String, dynamic>>(
      device.baseUri.replace(path: '/api/screen/offer'),
      data: {
        'type': local?.type ?? preferredOffer.type,
        'sdp': _preferVideoCodec(
          local?.sdp ?? preferredOffer.sdp ?? '',
          _screenCodec,
        ),
      },
    );
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
    return peer;
  }

  Future<void> _monitorViewerDecode(RTCPeerConnection peer) async {
    for (var attempt = 1; attempt <= 5; attempt++) {
      await Future<void>.delayed(
        attempt == 1 ? const Duration(seconds: 4) : const Duration(seconds: 2),
      );
      if (_viewerPeer != peer || state.value.mode != ScreenShareMode.watching) {
        return;
      }

      try {
        final reports = await peer.getStats();
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

      if (attempt < 5) {
        _logger.info(
          'Remote screen RTP statistics are not available yet '
          '(attempt $attempt/5)',
        );
      }
    }

    _logger.warn(
      'Remote screen RTP statistics stayed unavailable; keeping H.264 active',
    );
  }

  void updateLocalScreenMetrics(double width, double height) {
    if (width <= 0 || height <= 0) return;
    _localScreenWidth = width.round();
    _localScreenHeight = height.round();
    _localAspectRatio = width / height;
  }

  void _startAndroidMetricsPolling() {
    if (!WebRTC.platformIsAndroid) return;
    _androidMetricsPollTimer?.cancel();
    _pollAndroidScreenMetrics(force: true);
    _androidMetricsPollTimer = Timer.periodic(
      const Duration(milliseconds: 450),
      (_) => _pollAndroidScreenMetrics(),
    );
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

  void _stopAndroidMetricsPolling() {
    _androidMetricsPollTimer?.cancel();
    _androidMetricsPollTimer = null;
    _lastAndroidViewSize = null;
  }

  Map<String, dynamic> _screenMetadata() {
    final rendererAspect = localRenderer.value.aspectRatio;
    final aspectRatio = _isHealthyAspectRatio(_localAspectRatio)
        ? _localAspectRatio!
        : _isHealthyAspectRatio(rendererAspect)
        ? rendererAspect
        : 16 / 9;
    return {
      'aspectRatio': aspectRatio,
      'width': _localScreenWidth,
      'height': _localScreenHeight,
      'generation': _screenGeneration,
      'trackId': _localTrackId,
      'updatedAt': DateTime.now().toIso8601String(),
    };
  }

  void _startMetadataPolling(DeviceInfo device) {
    _metadataPollTimer?.cancel();
    _metadataPollTimer = Timer.periodic(_metadataPollInterval, (_) {
      unawaited(_pollScreenMetadata(device));
    });
    unawaited(_pollScreenMetadata(device));
  }

  Future<void> _pollScreenMetadata(DeviceInfo device) async {
    try {
      final response = await _dio.getUri<Map<String, dynamic>>(
        device.baseUri.replace(path: '/api/screen/metadata'),
        options: Options(receiveTimeout: const Duration(seconds: 2)),
      );
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
          unawaited(_handleGenerationChange(device));
        }
      }
    } catch (error) {
      if (_isScreenShareNotActiveError(error)) {
        unawaited(_handleRemoteEnded('Screen share ended'));
      }
    }
  }

  bool _isScreenShareNotActiveError(Object error) {
    if (error is! DioException) return false;
    final response = error.response;
    if (response?.statusCode != HttpStatus.serviceUnavailable) return false;
    final data = response?.data;
    return data is Map && data['error'] == 'screen-share-not-active';
  }

  Future<void> _handleRemoteEnded(String status) async {
    if (state.value.mode != ScreenShareMode.watching || _stopping) return;
    _logger.info('Remote screen share ended');
    await _stopViewer();
    _setState(ScreenShareMode.idle, status);
  }

  Future<void> _reconnectViewer(DeviceInfo device) async {
    if (_reconnectingViewer) return;
    _reconnectingViewer = true;
    try {
      _logger.info('Reconnecting screen viewer after stream restart');
      await _stopViewer(keepMetadataPolling: true);
      final peer = await _connectViewerPeer(device);
      _viewerPeer = peer;
      unawaited(_monitorViewerDecode(peer));
    } catch (error) {
      _logger.warn('Screen viewer reconnect failed: $error');
    } finally {
      _reconnectingViewer = false;
    }
  }

  bool _isHealthyAspectRatio(double? aspectRatio) {
    return aspectRatio != null &&
        !aspectRatio.isNaN &&
        !aspectRatio.isInfinite &&
        aspectRatio >= 0.42 &&
        aspectRatio <= 2.45;
  }

  Future<void> _handleGenerationChange(DeviceInfo device) async {
    await _reconnectViewer(device);
  }

  Future<RTCPeerConnection> _createPeer() {
    return createPeerConnection({
      'iceServers': [],
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
    });
  }

  Future<void> _configureLowLatencyVideoSender(RTCRtpSender sender) async {
    try {
      final parameters = sender.parameters;
      parameters.degradationPreference = WebRTC.platformIsAndroid
          ? RTCDegradationPreference.MAINTAIN_FRAMERATE
          : RTCDegradationPreference.MAINTAIN_RESOLUTION;
      final encodings = parameters.encodings;
      if (encodings == null || encodings.isEmpty) {
        parameters.encodings = [
          RTCRtpEncoding(
            maxBitrate: WebRTC.platformIsAndroid
                ? _androidMaxBitrate
                : _desktopMaxBitrate,
            minBitrate: WebRTC.platformIsAndroid ? null : _desktopMinBitrate,
            maxFramerate: WebRTC.platformIsAndroid
                ? _androidMaxFramerate
                : _desktopMaxFramerate,
            scaleResolutionDownBy: 1,
            priority: RTCPriorityType.high,
            networkPriority: RTCPriorityType.high,
          ),
        ];
      } else {
        for (final encoding in encodings) {
          encoding.maxBitrate = WebRTC.platformIsAndroid
              ? _androidMaxBitrate
              : _desktopMaxBitrate;
          encoding.minBitrate = WebRTC.platformIsAndroid
              ? null
              : _desktopMinBitrate;
          encoding.maxFramerate = WebRTC.platformIsAndroid
              ? _androidMaxFramerate
              : _desktopMaxFramerate;
          encoding.scaleResolutionDownBy = 1;
          encoding.priority = RTCPriorityType.high;
          encoding.networkPriority = RTCPriorityType.high;
        }
      }
      await sender.setParameters(parameters);
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

  Future<void> _prepareCapture() async {
    if (WebRTC.platformIsAndroid) {
      final granted = await Helper.requestCapturePermission();
      if (!granted) {
        throw StateError('Screen capture permission was denied');
      }
      await _enableAndroidScreenShareExecution();
    } else if (WebRTC.platformIsMacOS) {
      final granted = await Helper.requestCapturePermission();
      if (!granted) {
        throw StateError('Screen capture permission was denied');
      }
    }
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
        'mandatory': {'frameRate': 30.0},
      };
    }
    if (WebRTC.platformIsAndroid) {
      return {
        'mandatory': {'minFrameRate': 15, 'maxFrameRate': 24},
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
    peer.onIceGatheringState = (state) {
      _logger.info('Screen share ICE gathering state: $state');
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !completer.isCompleted) {
        timeout?.cancel();
        completer.complete();
      }
    };
    timeout = Timer(const Duration(seconds: 4), () {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    await completer.future;
  }

  Future<void> stop(FileServer server, {String status = 'Idle'}) async {
    await _stop(server, status: status);
  }

  Future<void> _stop(
    FileServer server, {
    bool updateState = true,
    String status = 'Idle',
  }) async {
    _stopping = true;
    try {
      server.screenOfferHandler = null;
      server.screenMetadataHandler = null;
      _stopAndroidMetricsPolling();
      if (_initialized) {
        localRenderer.onResize = null;
      }
      await _stopSharingPeers();
      await _stopViewer();
      if (_initialized) {
        remoteRenderer.srcObject = null;
        localRenderer.srcObject = null;
      }
      await _stopLocalStream();
      await _disableAndroidScreenShareExecution();
      if (updateState) {
        _setState(ScreenShareMode.idle, status);
      }
    } finally {
      _stopping = false;
    }
  }

  Future<void> dispose() async {
    _logger.info('Disposing screen share resources');
    await _stopSharingPeers();
    await _stopViewer();
    _stopAndroidMetricsPolling();
    await _stopLocalStream();
    await localRenderer.dispose();
    await remoteRenderer.dispose();
    remoteAspectRatio.dispose();
    focusedViewerActive.dispose();
    state.dispose();
    _dio.close(force: true);
    await _disableAndroidScreenShareExecution();
  }

  Future<void> _stopSharingPeers() async {
    for (final timer in _sharingPeerDisconnectTimers.values) {
      timer.cancel();
    }
    _sharingPeerDisconnectTimers.clear();
    final peers = List<RTCPeerConnection>.from(_peers);
    _peers.clear();
    for (final peer in peers) {
      peer.onConnectionState = null;
      peer.onIceConnectionState = null;
      try {
        await peer.close();
      } catch (error) {
        _logger.warn('Screen share peer close failed: $error');
      }
    }
  }

  Future<void> _stopViewer({bool keepMetadataPolling = false}) async {
    if (!keepMetadataPolling) {
      _metadataPollTimer?.cancel();
      _metadataPollTimer = null;
      _lastRemoteGeneration = null;
      remoteAspectRatio.value = null;
    }
    final peer = _viewerPeer;
    _viewerPeer = null;
    if (_initialized) {
      remoteRenderer.srcObject = null;
    }
    try {
      await peer?.close();
    } catch (error) {
      _logger.warn('Screen share viewer close failed: $error');
    }
  }

  Future<void> _stopLocalStream() async {
    final stream = _localStream;
    _localStream = null;
    if (_initialized) {
      localRenderer.srcObject = null;
    }
    if (stream == null) return;
    await _disposeStream(stream);
  }

  Future<void> _disposeStream(MediaStream stream) async {
    for (final track in stream.getTracks()) {
      try {
        track.stop();
      } catch (_) {}
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
}
