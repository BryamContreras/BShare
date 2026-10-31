// Explicit diagnostic target; never imported by main.dart or release builds.
// Uses the production Windows receiver, renderer and right-hand control panel.
// The owner supplies a private token and closes the owned native window after
// /stop. Status retains counters only; the explicit photo/record actions save
// only the media requested by the owner. SDP and capability tokens are omitted.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/application/camera_media_provider.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/infrastructure/services/android_screen_share_execution_service.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/file_server.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:bshare/src/infrastructure/services/camera_media_service.dart';
import 'package:bshare/src/infrastructure/services/usb_adb_transport_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/screens/camera_viewer_screen.dart';
import 'package:bshare/src/presentation/screens/screen_viewer_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final options =
      (ArgParser()
            ..addOption('viewer-ip')
            ..addOption('usb-serial')
            ..addOption('viewer-port', defaultsTo: '53317')
            ..addOption(
              'viewer-source',
              defaultsTo: 'camera',
              allowed: ['camera', 'screen'],
            )
            ..addOption('probe-control-port', defaultsTo: '0')
            ..addOption('probe-token')
            ..addOption('probe-seconds', defaultsTo: '180'))
          .parse(arguments);
  final usbSerial = options['usb-serial'] as String?;
  final ip =
      options['viewer-ip'] as String? ??
      (usbSerial == null ? null : '127.0.0.1');
  final token = options['probe-token'] as String?;
  final port = int.tryParse(options['viewer-port'] as String);
  final controlPort = int.tryParse(options['probe-control-port'] as String);
  final seconds = int.tryParse(options['probe-seconds'] as String);
  if (ip == null ||
      InternetAddress.tryParse(ip) == null ||
      port == null ||
      port < 1 ||
      port > 65535 ||
      controlPort == null ||
      controlPort < 0 ||
      controlPort > 65535 ||
      token == null ||
      token.length < 32 ||
      token.length > 256 ||
      seconds == null ||
      seconds < 10 ||
      seconds > 600) {
    throw ArgumentError(
      'Supply a numeric viewer IP, valid ports, a private '
      '32–256 character probe token, and a 10–600 second deadline.',
    );
  }
  final probe = _ReceiverProbe(
    token,
    source: options['viewer-source'] as String,
    usbSerial: usbSerial,
    device: DeviceInfo(
      id: 'physical-phone-probe',
      name: 'BShare phone',
      platform: 'Android',
      ip: ip,
      port: port,
      lastSeen: DateTime.now(),
    ),
  );
  await probe.start(controlPort, Duration(seconds: seconds));
}

class _ReceiverProbe {
  _ReceiverProbe(
    this._token, {
    required this.device,
    required this.source,
    this.usbSerial,
  }) {
    service = ScreenShareService(
      logger,
      AndroidScreenShareExecutionService(),
      peerConnectionFactory: () async {
        final peer = await createPeerConnection({
          'iceServers': [],
          'sdpSemantics': 'unified-plan',
          'bundlePolicy': 'max-bundle',
          'rtcpMuxPolicy': 'require',
        });
        _latestPeer = peer;
        return peer;
      },
      configuredPeerConnectionFactory: (configuration) async {
        final peer = await createPeerConnection(configuration);
        _latestPeer = peer;
        return peer;
      },
      usbTransport: _usbTransport,
    );
    _providers = ProviderContainer(
      overrides: [
        loggerProvider.overrideWithValue(logger),
        screenShareServiceProvider.overrideWithValue(service),
      ],
    );
  }

  final String _token;
  final DeviceInfo device;
  final String source;
  final String? usbSerial;
  final _usbTransport = _ProbeUsbTransport();
  final logger = _ProbeLogger();
  late final ScreenShareService service;
  late final ProviderContainer _providers;
  CameraMediaService get _media => _providers.read(cameraMediaServiceProvider);
  late final HttpServer _server;
  final _requests = <Future<void>>{};
  final _closedViewer = ValueNotifier(false);
  Timer? _deadline;
  Timer? _statsTimer;
  RTCPeerConnection? _latestPeer;
  Future<void>? _readingStats;
  Map<String, Object?> _mediaStats = const {};
  Future<void>? _cleaning;
  Future<void>? _finishing;
  bool _stopping = false;
  bool _cleanupComplete = false;
  bool _accepting = true;

  Future<void> start(int port, Duration duration) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    // The token is deliberately absent from this public startup metadata.
    logger.info(
      'BSHARE_VIRTUAL_RECEIVER_PROBE ${jsonEncode({'controlPort': _server.port, 'deadlineSeconds': duration.inSeconds})}',
    );
    _deadline = Timer(duration, () {
      unawaited(() async {
        await _cleanup();
        await _finish();
      }());
    });
    unawaited(_serve());
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_stopping && _readingStats == null) {
        unawaited(_sampleStats());
      }
    });
    if (usbSerial != null) {
      runApp(
        const MaterialApp(
          home: Scaffold(body: Center(child: CircularProgressIndicator())),
        ),
      );
      final devices = await UsbAdbTransportService().listDevices();
      final physical = devices.singleWhere(
        (candidate) =>
            candidate.serial == usbSerial &&
            candidate.state == UsbAdbDeviceState.authorized,
      );
      try {
        await service.watchUsb(
          physical,
          source: source == 'camera'
              ? VideoShareSource.camera
              : VideoShareSource.screen,
          remotePort: device.port,
        );
      } catch (_) {
        logger.warn(
          'USB transport counters: ${jsonEncode(_usbTransport.lastSession?.diagnostics)}',
        );
        rethrow;
      }
      if (_stopping) return;
    }
    runApp(
      UncontrolledProviderScope(
        container: _providers,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.dark(useMaterial3: true),
          home: ValueListenableBuilder<bool>(
            valueListenable: _closedViewer,
            builder: (context, closed, _) => closed
                ? const Scaffold(
                    body: Center(child: Text('Receiver disconnected')),
                  )
                : source == 'screen'
                ? FocusedScreenViewer(
                    device: usbSerial == null ? device : null,
                    onClose: () async {
                      if (!_stopping) _closedViewer.value = true;
                    },
                  )
                : FocusedCameraViewer(
                    device: usbSerial == null ? device : null,
                    onClose: () async {
                      if (!_stopping) _closedViewer.value = true;
                    },
                  ),
          ),
        ),
      ),
    );
  }

  Future<void> _sampleStats() {
    final peer = _latestPeer;
    if (peer == null || _stopping) return Future.value();
    return _readingStats ??= () async {
      try {
        final reports = await peer.getStats().timeout(
          const Duration(seconds: 3),
        );
        if (_stopping || _latestPeer != peer) return;
        final byId = {for (final item in reports) item.id: item};
        const keys = {
          'kind',
          'mediaType',
          'bytesReceived',
          'packetsReceived',
          'packetsLost',
          'framesReceived',
          'framesDecoded',
          'framesDropped',
          'frameWidth',
          'frameHeight',
          'framesPerSecond',
          'totalDecodeTime',
          'totalProcessingDelay',
          'jitter',
          'jitterBufferDelay',
          'jitterBufferTargetDelay',
          'jitterBufferMinimumDelay',
          'jitterBufferEmittedCount',
          'totalInterFrameDelay',
          'totalSquaredInterFrameDelay',
          'totalAssemblyTime',
          'framesAssembledFromMultiplePackets',
          'freezeCount',
          'totalFreezesDuration',
          'decoderImplementation',
          'totalSamplesReceived',
          'concealedSamples',
          'totalSamplesDuration',
          'totalAudioEnergy',
          'insertedSamplesForDeceleration',
          'removedSamplesForAcceleration',
          'currentRoundTripTime',
          'availableIncomingBitrate',
          'availableOutgoingBitrate',
          'state',
          'nominated',
          'bytesSent',
        };
        _mediaStats = {
          'sampledAtMs': DateTime.now().millisecondsSinceEpoch,
          'reports': [
            for (final item in reports)
              if (item.type == 'inbound-rtp' ||
                  item.type == 'candidate-pair' ||
                  item.type == 'media-playout')
                {
                  'type': item.type,
                  if (usbSerial != null && item.type == 'candidate-pair') ...{
                    'localCandidateType': byId[item.values['localCandidateId']]
                        ?.values['candidateType'],
                    'remoteCandidateType':
                        byId[item.values['remoteCandidateId']]
                            ?.values['candidateType'],
                    'localAddress': byId[item.values['localCandidateId']]
                        ?.values['address'],
                    'remoteAddress': byId[item.values['remoteCandidateId']]
                        ?.values['address'],
                    'relayProtocol': byId[item.values['localCandidateId']]
                        ?.values['relayProtocol'],
                  },
                  if (item.values['codecId'] case final String id?)
                    'codec': byId[id]?.values['mimeType'],
                  for (final key in keys)
                    if (item.values.containsKey(key)) key: item.values[key],
                },
          ],
        };
      } catch (_) {
        // A stopped/replaced diagnostic peer has no useful new timing sample.
      }
    }().whenComplete(() => _readingStats = null);
  }

  Future<void> _serve() async {
    try {
      await for (final request in _server) {
        late final Future<void> pending;
        pending = _handle(
          request,
        ).whenComplete(() => _requests.remove(pending));
        _requests.add(pending);
      }
    } catch (_) {
      if (_accepting) logger.warn('Probe HTTP listener stopped unexpectedly');
    }
  }

  Map<String, Object?> _status() {
    if (_cleanupComplete) {
      return {'ready': false, 'mode': 'idle', 'cleanupComplete': true};
    }
    final state = service.state.value;
    final frame = service.remoteRenderer.value;
    final controls = service.remoteCameraControls.value;
    final media = _media.state.value;
    return {
      'ready':
          !_stopping &&
          state.mode == ScreenShareMode.watching &&
          !state.awaitingVideo &&
          state.error == null &&
          frame.width > 0 &&
          frame.height > 0,
      'mode': state.mode.name,
      'source': source,
      'usb': service.watchingUsb,
      if (usbSerial != null)
        'usbDiagnostics': _usbTransport.lastSession?.diagnostics,
      'mediaStats': _mediaStats,
      'awaitingVideo': state.awaitingVideo,
      'frameWidth': frame.width,
      'frameHeight': frame.height,
      'rotation': frame.rotation,
      'firstFrameRendered': logger.firstFrameRendered,
      'decodedFrames': logger.decodedFrames,
      'negotiatedCodec': logger.negotiatedCodec,
      'viewerClosed': _closedViewer.value,
      'previewEnabled': service.remotePreviewEnabled.value,
      'media': {
        'ready': media.ready,
        'supported': media.supported,
        'busy': media.busy,
        'recording': media.recording,
        'elapsedMs': media.elapsed.inMilliseconds,
        'photoDirectory': media.photoDirectory,
        'videoDirectory': media.videoDirectory,
        'lastSavedPath': media.lastSavedPath,
        'error': media.error,
      },
      'controls': {
        'available': controls.available,
        'busy': controls.busy,
        'microphoneEnabled': controls.microphoneEnabled,
        'torchEnabled': controls.torchEnabled,
        'torchAvailable': controls.torchAvailable,
        'canSwitchCamera': controls.canSwitchCamera,
        'capture': controls.capture.toMap(),
      },
      'stopping': _stopping,
      'cleanupComplete': false,
    };
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      if (bytes.length + chunk.length > 4096) {
        throw const FormatException('Request too large');
      }
      bytes.addAll(chunk);
    }
    if (bytes.isEmpty) return {};
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Expected JSON object');
    }
    return decoded;
  }

  Future<void> _json(
    HttpRequest request,
    Map<String, Object?> body, [
    int status = HttpStatus.ok,
  ]) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set('Cache-Control', 'no-store');
    if (status >= 400) request.response.persistentConnection = false;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.connectionInfo?.remoteAddress.isLoopback != true ||
          request.headers.value('X-BShare-Probe-Token') != _token) {
        await _json(request, {
          'ok': false,
          'error': 'forbidden',
        }, HttpStatus.forbidden);
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/status') {
        await _json(request, _status());
        return;
      }
      if (request.method != 'POST' || !_accepting || _stopping) {
        await _json(request, {
          'ok': false,
          'error': 'unavailable',
        }, HttpStatus.conflict);
        return;
      }
      final body = await _body(request).timeout(const Duration(seconds: 3));
      double number(String key) {
        final value = body[key];
        if (value is! num || !value.isFinite) {
          throw FormatException('Expected finite $key');
        }
        return value.toDouble();
      }

      switch (request.uri.path) {
        case '/preview':
          final enabled = body['enabled'];
          if (enabled is! bool) throw const FormatException('Expected enabled');
          await service.setRemotePreviewEnabled(enabled);
        case '/photo':
          await _media.takePhoto();
        case '/record-start':
          await _media.startRecording();
        case '/record-stop':
          await _media.stopRecording();
        case '/media-directories':
          final pictures = body['pictures'];
          final videos = body['videos'];
          if (pictures is! String ||
              videos is! String ||
              !p.isAbsolute(pictures) ||
              !p.isAbsolute(videos)) {
            throw const FormatException('Expected absolute media directories');
          }
          await _media.setPhotoDirectory(pictures);
          await _media.setVideoDirectory(videos);
        case '/microphone':
          final enabled = body['enabled'];
          if (enabled is! bool) throw const FormatException('Expected enabled');
          await service.setRemoteCameraMicrophoneEnabled(enabled);
        case '/switch':
          await service.switchRemoteCamera();
        case '/torch':
          final enabled = body['enabled'];
          if (enabled is! bool) throw const FormatException('Expected enabled');
          await service.setRemoteCameraTorchEnabled(enabled);
        case '/zoom':
          await service.setRemoteCameraZoom(number('value'));
        case '/white-balance':
          final value = body['value'];
          if (value is! String) throw const FormatException('Expected preset');
          await service.setRemoteCameraWhiteBalance(value);
        case '/white-balance-warmth':
          await service.setRemoteCameraWhiteBalanceWarmth(number('value'));
        case '/exposure':
          await service.setRemoteCameraExposure(number('value'));
        case '/exposure-mode':
          final value = body['value'];
          if (value is! String) throw const FormatException('Expected mode');
          await service.setRemoteCameraExposureMode(value);
        case '/exposure-time':
          await service.setRemoteCameraExposureTime(number('value'));
        case '/iso':
          final value = number('value');
          if (value != value.roundToDouble()) {
            throw const FormatException('Expected integer ISO');
          }
          await service.setRemoteCameraIso(value.toInt());
        case '/camera':
          final value = body['value'];
          if (value is! String) {
            throw const FormatException('Expected camera ID');
          }
          await service.selectRemoteCamera(value);
        case '/stop-sharing':
          await service.stopRemoteCameraSharing();
        case '/disconnect':
          await service.stopWatching();
        case '/stop':
          await _cleanup();
          await _json(request, {
            'ok': _cleanupComplete,
            'cleanupComplete': _cleanupComplete,
          }, _cleanupComplete ? HttpStatus.ok : HttpStatus.internalServerError);
          // This request must leave the tracked set before listener drain.
          unawaited(Future<void>(() => _finish()));
          return;
        default:
          await _json(request, {
            'ok': false,
            'error': 'not-found',
          }, HttpStatus.notFound);
          return;
      }
      await _json(request, {'ok': true, ..._status()});
    } on PlatformException catch (error) {
      logger.warn('Probe native failure: ${error.code}: ${error.message}');
      await _json(request, {
        'ok': false,
        'error': 'native-operation-failed',
        'nativeCode': error.code,
      }, HttpStatus.internalServerError);
    } on CameraControlException catch (error) {
      await _json(request, {'ok': false, 'error': error.code}, error.status);
    } on FormatException {
      await _json(request, {
        'ok': false,
        'error': 'invalid-body',
      }, HttpStatus.badRequest);
    } on TimeoutException {
      await _json(request, {
        'ok': false,
        'error': 'timeout',
      }, HttpStatus.requestTimeout);
    } catch (_) {
      // Avoid serializing Dio/native exceptions that may contain private data.
      try {
        await _json(request, {
          'ok': false,
          'error': 'operation-failed',
        }, HttpStatus.internalServerError);
      } catch (_) {}
    } finally {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _cleanup() => _cleaning ??= () async {
    _stopping = true;
    _deadline?.cancel();
    _statsTimer?.cancel();
    await _readingStats;
    runApp(const SizedBox.shrink());
    // Unmount the production viewer before disposing its shared renderer.
    try {
      await WidgetsBinding.instance.endOfFrame.timeout(
        const Duration(seconds: 3),
      );
    } on TimeoutException {
      // A minimized native window may withhold a vsync. Service disposal still
      // cancels requests and detaches its native track; its UI cleanup methods
      // safely ignore subsequent widget disposal.
      logger.warn('Probe unmount frame was delayed while closing');
    }
    try {
      await _media.dispose();
      await service.dispose().timeout(const Duration(seconds: 15));
      _cleanupComplete = true;
    } catch (_) {
      logger.warn('Probe native cleanup did not complete within its deadline');
    }
    _providers.dispose();
    _closedViewer.dispose();
    logger.info(
      _cleanupComplete
          ? 'BSHARE_VIRTUAL_RECEIVER_CLEANUP_COMPLETE'
          : 'BSHARE_VIRTUAL_RECEIVER_CLEANUP_FAILED',
    );
  }();

  Future<void> _finish() => _finishing ??= () async {
    _accepting = false;
    await _server.close(force: true);
    try {
      await Future.wait(_requests.toList()).timeout(const Duration(seconds: 4));
    } on TimeoutException {
      logger.warn('Probe request drain did not complete within its deadline');
    }
    // The owner may also send WM_CLOSE once /stop confirms native cleanup.
    // A missing owner must not leave a diagnostic process alive indefinitely.
    Timer(const Duration(seconds: 10), () => exit(2));
    try {
      await SystemNavigator.pop().timeout(const Duration(seconds: 3));
    } catch (_) {
      logger.warn('Probe owner must close its native window');
    }
  }();
}

class _ProbeUsbTransport extends UsbAdbTransportService {
  UsbRelaySession? lastSession;

  @override
  Future<UsbRelaySession> open(
    UsbAdbDevice device, {
    int remotePort = 53317,
  }) async {
    return lastSession = await super.open(device, remotePort: remotePort);
  }
}

class _ProbeLogger extends AppLogger {
  bool firstFrameRendered = false;
  int decodedFrames = 0;
  String? negotiatedCodec;

  @override
  void info(String message) {
    firstFrameRendered |= message.contains('renderer received its first frame');
    final decoded = RegExp(r'decoded=(\d+)').firstMatch(message);
    if (decoded != null) decodedFrames = int.parse(decoded.group(1)!);
    const prefix = 'Screen share negotiated codec: ';
    if (message.startsWith(prefix)) {
      negotiatedCodec = message.substring(prefix.length);
    }
    super.info(message);
  }
}
