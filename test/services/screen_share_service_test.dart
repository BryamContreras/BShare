import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bshare/src/domain/entities/camera_device.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/domain/entities/screen_capture_settings.dart';
import 'package:bshare/src/infrastructure/services/android_screen_share_execution_service.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/file_server.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

const _sdp =
    'v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
    'a=rtpmap:96 H264/90000\r\n';

const _cameraOfferSdp =
    'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
    'a=mid:audio\r\na=recvonly\r\na=rtpmap:111 opus/48000/2\r\n'
    'm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=mid:video\r\n'
    'a=recvonly\r\na=rtpmap:96 H264/90000\r\n';

class _RealHttpOverrides extends HttpOverrides {}

class _Renderer extends RTCVideoRenderer {
  int initializes = 0;
  int disposes = 0;
  Completer<void>? initialization;
  MediaStream? _stream;
  String? lastBoundTrackId;

  @override
  Future<void> initialize() async {
    initializes++;
    await initialization?.future;
  }

  @override
  MediaStream? get srcObject => _stream;

  @override
  Future<void> setSrcObject({MediaStream? stream, String? trackId}) async {
    _stream = stream;
    lastBoundTrackId = trackId;
  }

  @override
  Future<void> dispose() async {
    disposes++;
    await super.dispose();
  }
}

class _Transceiver extends Fake implements RTCRtpTransceiver {
  _Transceiver(this.kind, this.init, this.track);
  final RTCRtpMediaType? kind;
  final RTCRtpTransceiverInit? init;
  final MediaStreamTrack? track;
  @override
  String mid = '';
  TransceiverDirection? selectedDirection;
  @override
  Future<void> setDirection(TransceiverDirection direction) async {
    selectedDirection = direction;
  }

  @override
  RTCRtpReceiver get receiver => _Receiver(
    kind == RTCRtpMediaType.RTCRtpMediaTypeAudio
        ? _RemoteAudioTrack()
        : _RemoteTrack(),
  );
  @override
  final _Sender sender = _Sender();
}

class _Receiver extends Fake implements RTCRtpReceiver {
  _Receiver(this.track);
  @override
  final MediaStreamTrack track;
}

class _Sender extends Fake implements RTCRtpSender {
  @override
  final parameters = RTCRtpParameters();
  int updates = 0;
  final replacedTracks = <MediaStreamTrack?>[];
  bool failAudioReplacement = false;
  List<MediaStream>? boundStreams;
  @override
  Future<void> setStreams(List<MediaStream> streams) async {
    boundStreams = List.of(streams);
  }

  @override
  Future<void> replaceTrack(MediaStreamTrack? track) async {
    replacedTracks.add(track);
    if (failAudioReplacement && track?.kind == 'audio') {
      throw StateError('Audio sender replacement failed');
    }
  }

  @override
  Future<bool> setParameters(RTCRtpParameters parameters) async {
    updates++;
    return true;
  }
}

class _SharingPeer extends _Peer {
  final _Sender sender = _Sender();
  @override
  Future<RTCRtpSender> addTrack(
    MediaStreamTrack track, [
    MediaStream? stream,
  ]) async => sender;
  @override
  Future<RTCSessionDescription> createAnswer([
    Map<String, dynamic>? constraints,
  ]) async => RTCSessionDescription(_sdp, 'answer');
}

class _RemoteTrack extends MediaStreamTrack {
  @override
  String get id => 'actual-remote-video-id';
  @override
  String get kind => 'video';
  @override
  bool enabled = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RemoteAudioTrack extends _RemoteTrack {
  @override
  String get id => 'remote-audio';
  @override
  String get kind => 'audio';
}

class _RemoteStream extends Fake implements MediaStream {
  _RemoteStream(this.track);
  final MediaStreamTrack track;
  @override
  List<MediaStreamTrack> getVideoTracks() => [track];
}

class _Peer extends RTCPeerConnection {
  int closes = 0;
  int disposes = 0;
  int remoteDescriptions = 0;
  int statsReads = 0;
  bool failOffer = false;
  bool failClose = false;
  String localSdp = _sdp;
  final addedTransceivers = <_Transceiver>[];
  final associatedTransceivers = <_Transceiver>[];
  @override
  Future<List<RTCRtpTransceiver>> getTransceivers() async => [
    ...addedTransceivers,
    ...associatedTransceivers,
  ];
  Map<String, dynamic>? offerConstraints;
  RTCIceGatheringState gathering =
      RTCIceGatheringState.RTCIceGatheringStateComplete;

  @override
  RTCIceGatheringState get iceGatheringState => gathering;

  @override
  Future<RTCRtpTransceiver> addTransceiver({
    MediaStreamTrack? track,
    RTCRtpMediaType? kind,
    RTCRtpTransceiverInit? init,
  }) async {
    final transceiver = _Transceiver(
      kind ??
          (track?.kind == 'audio'
              ? RTCRtpMediaType.RTCRtpMediaTypeAudio
              : null),
      init,
      track,
    );
    addedTransceivers.add(transceiver);
    return transceiver;
  }

  @override
  Future<RTCSessionDescription> createOffer([
    Map<String, dynamic>? constraints,
  ]) async {
    offerConstraints = constraints;
    if (failOffer) throw StateError('Offer failed');
    return RTCSessionDescription(_sdp, 'offer');
  }

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {}

  @override
  Future<RTCSessionDescription?> getLocalDescription() async =>
      RTCSessionDescription(localSdp, 'offer');

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    remoteDescriptions++;
    if (description.type == 'offer' &&
        (description.sdp ?? '').contains('m=audio')) {
      // Match libwebrtc: a trackless addTransceiver made before SRD is not
      // associated with a new remote m-line; SRD creates a receiving one.
      associatedTransceivers.add(
        _Transceiver(
          RTCRtpMediaType.RTCRtpMediaTypeAudio,
          RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
          null,
        )..mid = 'audio',
      );
    }
  }

  @override
  Future<List<StatsReport>> getStats([MediaStreamTrack? track]) async {
    statsReads++;
    return [];
  }

  @override
  Future<void> close() async {
    closes++;
    if (failClose) throw StateError('Close failed');
  }

  @override
  Future<void> dispose() async {
    disposes++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DeviceInfo get _device => DeviceInfo(
  id: 'phone',
  name: 'Phone',
  platform: 'Android',
  ip: '127.0.0.1',
  port: 53317,
  lastSeen: DateTime.now(),
);

class _Signaling {
  final Dio dio = Dio();
  final Completer<void> metadataStarted = Completer<void>();
  final Completer<void> offerStarted = Completer<void>();
  Completer<void>? metadataResponse;
  Completer<void>? offerResponse;
  bool invalidAnswer = false;
  bool inactive = false;
  int metadataCalls = 0;
  int activeMetadata = 0;
  int maxActiveMetadata = 0;
  int offerCalls = 0;
  int generation = 1;
  final paths = <String>[];

  _Signaling() {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          paths.add(options.path);
          if (options.path.endsWith('/metadata')) {
            metadataCalls++;
            activeMetadata++;
            if (activeMetadata > maxActiveMetadata) {
              maxActiveMetadata = activeMetadata;
            }
            if (!metadataStarted.isCompleted) metadataStarted.complete();
            await metadataResponse?.future;
            activeMetadata--;
            if (inactive) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response(
                    requestOptions: options,
                    statusCode: 503,
                    data: {
                      'error':
                          '${options.path.contains('/camera/') ? 'camera' : 'screen'}-share-not-active',
                    },
                  ),
                  type: DioExceptionType.badResponse,
                ),
              );
              return;
            }
            handler.resolve(
              Response(
                requestOptions: options,
                data: {
                  'metadata': {
                    'aspectRatio': 1080 / 2640,
                    'generation': generation,
                  },
                },
              ),
            );
            return;
          }
          offerCalls++;
          if (!offerStarted.isCompleted) offerStarted.complete();
          await offerResponse?.future;
          handler.resolve(
            Response(
              requestOptions: options,
              data: invalidAnswer
                  ? <String, dynamic>{}
                  : {
                      'answer': {'sdp': _sdp, 'type': 'answer'},
                    },
            ),
          );
        },
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ScreenShareService makeService({
    _Signaling? signaling,
    _Renderer? local,
    _Renderer? remote,
    Future<RTCPeerConnection> Function()? peerFactory,
    Future<void> Function()? onSharingStopped,
    Future<void> Function(bool)? audioRecordingGate,
  }) {
    final service = ScreenShareService(
      const AppLogger(),
      AndroidScreenShareExecutionService(),
      signalingClient: signaling?.dio,
      localRenderer: local ?? _Renderer(),
      remoteRenderer: remote ?? _Renderer(),
      peerConnectionFactory: peerFactory ?? () async => _Peer(),
      onSharingStopped: onSharingStopped,
      audioRecordingGate: audioRecordingGate,
    );
    addTearDown(service.dispose);
    return service;
  }

  test('focused viewer switches between preview and focused UI', () {
    final service = makeService();
    expect(service.focusedViewerActive.value, isFalse);
    service.setFocusedViewerActive(true);
    expect(service.focusedViewerActive.value, isTrue);
    service.setFocusedViewerActive(false);
    expect(service.focusedViewerActive.value, isFalse);
  });

  test('concurrent initialization creates each renderer once', () async {
    final local = _Renderer()..initialization = Completer<void>();
    final remote = _Renderer();
    final service = makeService(local: local, remote: remote);
    final first = service.initialize();
    final second = service.initialize();
    local.initialization!.complete();
    await Future.wait([first, second]);
    expect(local.initializes, 1);
    expect(remote.initializes, 1);
  });

  test('dispose waits for initialization and releases textures once', () async {
    final local = _Renderer()..initialization = Completer<void>();
    final remote = _Renderer();
    final service = makeService(local: local, remote: remote);
    final initialized = service.initialize();
    final firstDispose = service.dispose();
    final secondDispose = service.dispose();
    local.initialization!.complete();
    await Future.wait([initialized, firstDispose, secondDispose]);
    expect(local.disposes, 1);
    expect(remote.disposes, 1);
    await expectLater(service.initialize(), throwsStateError);
  });

  test('concurrent watch requests share one negotiation', () async {
    final signaling = _Signaling()..offerResponse = Completer<void>();
    final service = makeService(signaling: signaling);
    final first = service.watch(_device);
    final second = service.watch(_device);
    await signaling.offerStarted.future;
    signaling.offerResponse!.complete();
    await Future.wait([first, second]);
    await service.watch(_device);
    expect(signaling.offerCalls, 1);
    await service.stopWatching();
  });

  test(
    'remote rendering selects the negotiated video track explicitly',
    () async {
      final peer = _Peer();
      final renderer = _Renderer();
      final service = makeService(
        signaling: _Signaling(),
        remote: renderer,
        peerFactory: () async => peer,
      );
      await service.watch(_device);
      final track = _RemoteTrack();
      final stream = _RemoteStream(track);
      await peer.onTrack!(RTCTrackEvent(streams: [stream], track: track));
      expect(renderer.srcObject, same(stream));
      expect(renderer.lastBoundTrackId, track.id);
      await service.stopWatching();
    },
  );

  test('failed negotiation closes and disposes the unassigned peer', () async {
    final signaling = _Signaling()..invalidAnswer = true;
    final peer = _Peer();
    final service = makeService(
      signaling: signaling,
      peerFactory: () async => peer,
    );
    await expectLater(service.watch(_device), throwsStateError);
    expect(peer.closes, 1);
    expect(peer.disposes, 1);
    expect(service.state.value.mode, ScreenShareMode.idle);
  });

  test('offer creation failure disposes peer even if close fails', () async {
    final peer = _Peer()
      ..failOffer = true
      ..failClose = true;
    final service = makeService(
      signaling: _Signaling(),
      peerFactory: () async => peer,
    );
    await expectLater(service.watch(_device), throwsStateError);
    expect(peer.closes, 1);
    expect(peer.disposes, 1);
  });

  test(
    'stop during offer cancels signaling and prevents late activation',
    () async {
      final signaling = _Signaling()..offerResponse = Completer<void>();
      final peer = _Peer();
      final service = makeService(
        signaling: signaling,
        peerFactory: () async => peer,
      );
      final watching = service.watch(_device);
      await signaling.offerStarted.future;
      await service.stopWatching();
      signaling.offerResponse!.complete();
      await watching;
      expect(peer.remoteDescriptions, 0);
      expect(peer.closes, 1);
      expect(peer.disposes, 1);
      expect(service.state.value.mode, ScreenShareMode.idle);
    },
  );

  test('stop before peer creation finishes releases the late peer', () async {
    final pendingPeer = Completer<RTCPeerConnection>();
    final peer = _Peer();
    final signaling = _Signaling();
    final service = makeService(
      signaling: signaling,
      peerFactory: () => pendingPeer.future,
    );
    final watching = service.watch(_device);
    await signaling.metadataStarted.future;
    await service.stopWatching();
    pendingPeer.complete(peer);
    await watching;
    expect(peer.closes, 1);
    expect(peer.disposes, 1);
    expect(signaling.offerCalls, 0);
    expect(service.state.value.mode, ScreenShareMode.idle);
  });

  test('metadata is single flight and stale responses are ignored', () async {
    final signaling = _Signaling()..metadataResponse = Completer<void>();
    final service = makeService(signaling: signaling);
    await service.watch(_device);
    await signaling.metadataStarted.future;
    await Future<void>.delayed(const Duration(milliseconds: 1150));
    expect(signaling.metadataCalls, 1);
    expect(signaling.maxActiveMetadata, 1);
    await service.stopWatching();
    signaling.metadataResponse!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(service.remoteAspectRatio.value, isNull);
    expect(signaling.metadataCalls, 1);
  });

  test('accepts tall phone aspect ratio from metadata', () async {
    final signaling = _Signaling();
    final service = makeService(signaling: signaling);
    await service.watch(_device);
    expect(service.remoteAspectRatio.value, closeTo(1080 / 2640, 0.00001));
    await service.stopWatching();
  });

  test(
    'repeated sessions release every peer and cancel stats timers',
    () async {
      final peers = <_Peer>[];
      final service = makeService(
        signaling: _Signaling(),
        peerFactory: () async {
          final peer = _Peer();
          peers.add(peer);
          return peer;
        },
      );
      for (var i = 0; i < 25; i++) {
        await service.watch(_device);
        await service.stopWatching();
      }
      expect(peers, hasLength(25));
      for (final peer in peers) {
        expect(peer.closes, 1);
        expect(peer.disposes, 1);
        expect(peer.onTrack, isNull);
        expect(peer.onIceConnectionState, isNull);
        expect(peer.statsReads, 0);
      }
    },
  );

  test('stop cancels pending ICE timeout and clears its callback', () async {
    final peer = _Peer()
      ..gathering = RTCIceGatheringState.RTCIceGatheringStateGathering;
    final service = makeService(
      signaling: _Signaling(),
      peerFactory: () async => peer,
    );
    final watching = service.watch(_device);
    while (peer.onIceGatheringState == null) {
      await Future<void>.delayed(Duration.zero);
    }
    await service.stopWatching();
    await watching.timeout(const Duration(seconds: 1));
    expect(peer.onIceGatheringState, isNull);
    expect(peer.disposes, 1);
  });

  test('remote capture ending during connection cancels negotiation', () async {
    final signaling = _Signaling()..inactive = true;
    final peer = _Peer();
    final service = makeService(
      signaling: signaling,
      peerFactory: () async => peer,
    );
    await service.watch(_device);
    expect(service.state.value.mode, ScreenShareMode.idle);
    expect(service.state.value.status, 'Screen share ended');
    expect(peer.disposes, 1);
  });

  test(
    'stop during generation reconnect prevents a late replacement peer',
    () async {
      final signaling = _Signaling();
      final peers = <_Peer>[];
      final service = makeService(
        signaling: signaling,
        peerFactory: () async {
          final peer = _Peer();
          peers.add(peer);
          return peer;
        },
      );
      await service.watch(_device);
      signaling.offerResponse = Completer<void>();
      signaling.generation = 2;
      await Future<void>(() async {
        while (signaling.offerCalls < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }).timeout(const Duration(seconds: 2));
      await service.stopWatching();
      signaling.offerResponse!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 550));
      expect(service.state.value.mode, ScreenShareMode.idle);
      expect(peers, hasLength(2));
      expect(peers[1].remoteDescriptions, 0);
      for (final peer in peers) {
        expect(peer.closes, 1);
        expect(peer.disposes, 1);
      }
    },
  );

  test(
    'camera viewer negotiates only camera endpoints and reuses one peer',
    () async {
      final signaling = _Signaling()..offerResponse = Completer<void>();
      final service = makeService(signaling: signaling);
      final first = service.watchCamera(_device);
      final duplicate = service.watchCamera(_device);
      await signaling.offerStarted.future;
      signaling.offerResponse!.complete();
      await Future.wait([first, duplicate]);
      expect(service.source, VideoShareSource.camera);
      expect(signaling.offerCalls, 1);
      expect(
        signaling.paths.every((path) => path.contains('/api/camera/')),
        isTrue,
      );
      await service.stopWatching();
      await service.watch(_device);
      expect(service.source, VideoShareSource.screen);
      expect(signaling.paths.last, contains('/api/screen/'));
      await service.stopWatching();
    },
  );

  test(
    'camera viewer reserves audio and never replaces video with audio',
    () async {
      final peer = _Peer();
      final renderer = _Renderer();
      final service = makeService(
        signaling: _Signaling(),
        remote: renderer,
        peerFactory: () async => peer,
      );
      await service.watchCamera(_device);
      expect(peer.offerConstraints!['offerToReceiveAudio'], 1);
      expect(peer.addedTransceivers.map((entry) => entry.kind), [
        RTCRtpMediaType.RTCRtpMediaTypeVideo,
        RTCRtpMediaType.RTCRtpMediaTypeAudio,
      ]);
      expect(
        peer.addedTransceivers.last.init!.direction,
        TransceiverDirection.RecvOnly,
      );
      final video = _RemoteTrack();
      final videoStream = _RemoteStream(video);
      await peer.onTrack!(RTCTrackEvent(streams: [videoStream], track: video));
      final audio = _RemoteAudioTrack()..enabled = false;
      await peer.onTrack!(RTCTrackEvent(streams: [], track: audio));
      expect(audio.enabled, isTrue);
      expect(audio.onEnded, isNull);
      expect(renderer.srcObject, same(videoStream));
      expect(renderer.lastBoundTrackId, video.id);
      expect(service.state.value.mode, ScreenShareMode.watching);
      await service.stopWatching();
    },
  );

  test('camera viewer recognizes camera capture ending', () async {
    final signaling = _Signaling()..inactive = true;
    final service = makeService(signaling: signaling);
    await service.watchCamera(_device);
    expect(service.state.value.mode, ScreenShareMode.idle);
    expect(service.remoteRenderer.srcObject, isNull);
  });

  test(
    'USB camera viewer binds signaling and filters its offer to the USB IP',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sources = <String>[];
      String? sentOffer;
      final serverTask = () async {
        await for (final request in server) {
          sources.add(request.connectionInfo!.remoteAddress.address);
          request.response.headers.contentType = ContentType.json;
          if (request.uri.path == '/api/camera/metadata') {
            request.response.write(
              jsonEncode({
                'metadata': {'generation': 1, 'aspectRatio': 16 / 9},
              }),
            );
          } else if (request.uri.path == '/api/camera/offer') {
            final body =
                jsonDecode(await utf8.decoder.bind(request).join()) as Map;
            sentOffer = body['sdp'] as String;
            request.response.write(
              jsonEncode({
                'answer': {'type': 'answer', 'sdp': _sdp},
              }),
            );
          } else {
            request.response.statusCode = 404;
          }
          await request.response.close();
        }
      }();
      addTearDown(() async {
        await server.close(force: true);
        await serverTask;
      });
      final peer = _Peer()
        ..localSdp =
            '$_sdp'
            'c=IN IP4 192.168.1.2\r\n'
            'a=candidate:1 1 udp 123 192.168.1.2 5001 typ host\r\n'
            'a=candidate:2 1 udp 123 127.0.0.2 5002 typ host\r\n';
      final service = makeService(peerFactory: () async => peer);
      await HttpOverrides.runWithHttpOverrides(
        () => service.watchCamera(
          _device.copyWith(port: server.port),
          allowedLocalIps: ['127.0.0.2'],
        ),
        _RealHttpOverrides(),
      );
      expect(sources, isNotEmpty);
      expect(sources.toSet(), {'127.0.0.2'});
      expect(sentOffer, contains('127.0.0.2'));
      expect(sentOffer, isNot(contains('192.168.1.2')));
      await service.stopWatching();
      expect(peer.disposes, 1);
    },
  );

  group('native capture cleanup', () {
    const methodChannel = MethodChannel('FlutterWebRTC.Method');
    const eventChannel = MethodChannel('FlutterWebRTC.Event');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<String> calls;
    late Future<dynamic> Function(MethodCall) handle;
    final streamData = <String, dynamic>{
      'streamId': 'capture',
      'audioTracks': <dynamic>[],
      'videoTracks': [
        {
          'id': 'video',
          'label': 'Screen',
          'kind': 'video',
          'enabled': true,
          'settings': <String, dynamic>{},
        },
      ],
    };

    setUp(() {
      calls = [];
      handle = (call) async {
        if (call.method == 'getDesktopSources') {
          return {
            'sources': [
              {
                'id': 'screen:0',
                'name': 'Screen',
                'type': 'screen',
                'thumbnailSize': {'width': 0, 'height': 0},
              },
            ],
          };
        }
        return call.method == 'getDisplayMedia' || call.method == 'getUserMedia'
            ? streamData
            : null;
      };
      messenger.setMockMethodCallHandler(methodChannel, (call) {
        calls.add(call.method);
        return handle(call);
      });
      messenger.setMockMethodCallHandler(eventChannel, (_) async => null);
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(methodChannel, null);
      messenger.setMockMethodCallHandler(eventChannel, null);
    });

    const back = CameraDevice(
      id: '0',
      label: 'Back camera',
      frontFacing: false,
    );
    const front = CameraDevice(
      id: '1',
      label: 'Front camera',
      frontFacing: true,
    );
    Map<String, dynamic> cameraStream(int index, {String camera = '0'}) => {
      'streamId': 'camera-$index',
      'audioTracks': <dynamic>[],
      'videoTracks': [
        {
          'id': 'camera-video-$index',
          'label': 'Camera',
          'kind': 'video',
          'enabled': true,
          'settings': <String, dynamic>{
            'deviceId': camera,
            'width': 1280,
            'height': 720,
          },
        },
      ],
    };

    Map<String, dynamic> microphoneStream(int index) => {
      'streamId': 'microphone-$index',
      'videoTracks': <dynamic>[],
      'audioTracks': [
        {
          'id': 'camera-audio-$index',
          'label': 'Microphone',
          'kind': 'audio',
          'enabled': true,
          'settings': <String, dynamic>{},
        },
      ],
    };

    test(
      'recording gate is off before negotiation and brackets microphone capture',
      () async {
        final events = <String>[];
        var recording = true;
        handle = (call) async {
          if (call.method == 'trackDispose') {
            events.add('dispose-${(call.arguments as Map)['trackId']}');
          }
          if (call.method != 'getUserMedia') return null;
          final audio =
              ((call.arguments as Map)['constraints'] as Map)['audio'] == true;
          events.add(audio ? 'capture-audio' : 'capture-video');
          expect(recording, audio);
          return audio ? microphoneStream(1) : cameraStream(1);
        };
        final peer = _SharingPeer();
        final service = makeService(
          audioRecordingGate: (enabled) async {
            recording = enabled;
            events.add('recording-$enabled');
          },
          peerFactory: () async {
            events.add('peer');
            expect(recording, isFalse);
            return peer;
          },
        );
        final server = FileServer(const AppLogger());
        await service.startCameraSharing(server, camera: back);
        expect(recording, isFalse);
        expect(
          events.indexOf('recording-false'),
          lessThan(events.indexOf('capture-video')),
        );
        await server.cameraOfferHandler!({
          'type': 'offer',
          'sdp': _cameraOfferSdp,
        });
        expect(recording, isFalse);
        await service.setCameraMicrophoneEnabled(true);
        expect(
          events.indexOf('recording-true'),
          lessThan(events.indexOf('capture-audio')),
        );
        events.clear();
        await service.setCameraMicrophoneEnabled(false);
        expect(recording, isFalse);
        expect(
          events.indexOf('recording-false'),
          lessThan(events.indexOf('dispose-camera-audio-1')),
        );
        expect(peer.closes, 0);
        await service.stop(server);
        expect(recording, isFalse);
      },
    );

    test(
      'recording enable failure never acquires microphone and restores off',
      () async {
        final gateValues = <bool>[];
        var microphoneCaptures = 0;
        handle = (call) async {
          if (call.method != 'getUserMedia') return null;
          if (((call.arguments as Map)['constraints'] as Map)['audio'] ==
              true) {
            microphoneCaptures++;
            return microphoneStream(1);
          }
          return cameraStream(1);
        };
        final service = makeService(
          audioRecordingGate: (enabled) async {
            gateValues.add(enabled);
            if (enabled) throw StateError('Cannot enable audio recording');
          },
        );
        final server = FileServer(const AppLogger());
        await service.startCameraSharing(server, camera: back);
        await expectLater(
          service.setCameraMicrophoneEnabled(true),
          throwsStateError,
        );
        expect(microphoneCaptures, 0);
        expect(gateValues, contains(true));
        expect(gateValues.last, isFalse);
        expect(service.cameraMicrophoneEnabled, isFalse);
        expect(service.state.value.mode, ScreenShareMode.sharing);
        await service.stop(server);
      },
    );

    test(
      'recording disable failure closes sending peers and releases microphone',
      () async {
        var failOff = false;
        final stopped = <String>[];
        handle = (call) async {
          if (call.method == 'trackDispose') {
            stopped.add((call.arguments as Map)['trackId'] as String);
          }
          if (call.method != 'getUserMedia') return null;
          return ((call.arguments as Map)['constraints'] as Map)['audio'] ==
                  true
              ? microphoneStream(1)
              : cameraStream(1);
        };
        final peer = _SharingPeer();
        final service = makeService(
          peerFactory: () async => peer,
          audioRecordingGate: (enabled) async {
            if (!enabled && failOff) {
              throw StateError('Cannot stop audio recording');
            }
          },
        );
        final server = FileServer(const AppLogger());
        await service.startCameraSharing(server, camera: back);
        await server.cameraOfferHandler!({
          'type': 'offer',
          'sdp': _cameraOfferSdp,
        });
        await service.setCameraMicrophoneEnabled(true);
        failOff = true;
        await expectLater(
          service.setCameraMicrophoneEnabled(false),
          throwsStateError,
        );
        expect(peer.closes, 1);
        expect(peer.disposes, 1);
        expect(stopped, contains('camera-audio-1'));
        expect(service.cameraMicrophoneEnabled, isFalse);
        failOff = false;
        await service.stop(server);
      },
    );

    test(
      'camera microphone is opt-in and toggles a reserved sender without reconnecting',
      () async {
        var captures = 0;
        final media = <Map<dynamic, dynamic>>[];
        final stops = <String>[];
        handle = (call) async {
          if (call.method == 'trackDispose') {
            stops.add((call.arguments as Map)['trackId'] as String);
          }
          if (call.method != 'getUserMedia') return null;
          final constraints = Map<dynamic, dynamic>.from(
            (call.arguments as Map)['constraints'] as Map,
          );
          media.add(constraints);
          return constraints['audio'] == true
              ? microphoneStream(++captures)
              : cameraStream(0);
        };
        final peer = _SharingPeer();
        final local = _Renderer();
        final service = makeService(
          local: local,
          peerFactory: () async => peer,
        );
        final server = FileServer(const AppLogger());
        await service.startCameraSharing(server, camera: back);
        expect(service.cameraMicrophoneEnabled, isFalse);
        expect(media, hasLength(1));
        await server.cameraOfferHandler!({
          'type': 'offer',
          'sdp': _cameraOfferSdp,
        });
        expect(peer.addedTransceivers, isEmpty);
        final audio = peer.associatedTransceivers.single;
        expect(audio.mid, 'audio');
        expect(audio.selectedDirection, TransceiverDirection.SendOnly);
        expect(audio.sender.boundStreams!.single, same(local.srcObject));
        expect(audio.sender.replacedTracks, isEmpty);
        expect(audio.track, isNull);
        final preview = local.srcObject;
        final first = service.setCameraMicrophoneEnabled(true);
        final duplicate = service.setCameraMicrophoneEnabled(true);
        expect(duplicate, same(first));
        await first;
        expect(service.cameraMicrophoneEnabled, isTrue);
        expect(media.last['audio'], isTrue);
        expect(media.last['video'], isFalse);
        expect(audio.sender.replacedTracks.single!.kind, 'audio');
        expect(local.srcObject, same(preview));
        expect(local.srcObject!.getAudioTracks(), isEmpty);
        await service.setCameraMicrophoneEnabled(false);
        expect(service.cameraMicrophoneEnabled, isFalse);
        expect(audio.sender.replacedTracks.last, isNull);
        expect(stops, contains('camera-audio-1'));
        await service.setCameraMicrophoneEnabled(true);
        expect(captures, 2);
        expect(audio.sender.replacedTracks.last!.id, 'camera-audio-2');
        expect(peer.closes, 0);
        expect(peer.remoteDescriptions, 1);
        await service.stop(server);
        expect(stops, contains('camera-audio-2'));
        expect(service.cameraMicrophoneEnabled, isFalse);
      },
    );

    test(
      'new camera viewers receive an active microphone and flip retains its capture',
      () async {
        var videoCaptures = 0;
        var audioCaptures = 0;
        final stops = <String>[];
        handle = (call) async {
          if (call.method == 'trackDispose') {
            stops.add((call.arguments as Map)['trackId'] as String);
          }
          if (call.method != 'getUserMedia') return null;
          return ((call.arguments as Map)['constraints'] as Map)['audio'] ==
                  true
              ? microphoneStream(++audioCaptures)
              : cameraStream(++videoCaptures);
        };
        final peer = _SharingPeer();
        final service = makeService(peerFactory: () async => peer);
        final server = FileServer(const AppLogger());
        await service.startCameraSharing(server, camera: back);
        await service.setCameraMicrophoneEnabled(true);
        await server.cameraOfferHandler!({
          'type': 'offer',
          'sdp': _cameraOfferSdp,
        });
        expect(peer.addedTransceivers, isEmpty);
        final audio = peer.associatedTransceivers.single;
        expect(audio.sender.replacedTracks.single!.id, 'camera-audio-1');
        expect(audio.selectedDirection, TransceiverDirection.SendOnly);
        await service.switchCamera(
          front,
          settings: const ScreenCaptureSettings(),
        );
        expect(service.cameraMicrophoneEnabled, isTrue);
        expect(audioCaptures, 1);
        expect(stops, isNot(contains('camera-audio-1')));
        expect(audio.sender.replacedTracks, hasLength(1));
        expect(peer.sender.replacedTracks.single!.id, 'camera-video-2');
        await service.stop(server);
        expect(stops, contains('camera-audio-1'));
      },
    );

    test(
      'failed microphone acquisition does not interrupt video or retain capture',
      () async {
        handle = (call) async {
          if (call.method != 'getUserMedia') return null;
          if (((call.arguments as Map)['constraints'] as Map)['audio'] ==
              true) {
            throw PlatformException(code: 'permission-denied');
          }
          return cameraStream(1);
        };
        final local = _Renderer();
        final service = makeService(local: local);
        final server = FileServer(const AppLogger());
        await service.startCameraSharing(server, camera: back);
        final preview = local.srcObject;
        await expectLater(
          service.setCameraMicrophoneEnabled(true),
          throwsA(isA<String>()),
        );
        expect(service.cameraMicrophoneEnabled, isFalse);
        expect(local.srcObject, same(preview));
        expect(service.state.value.mode, ScreenShareMode.sharing);
        expect(server.cameraOfferHandler, isNotNull);
        await service.stop(server);
      },
    );

    test(
      'failed microphone sender replacement releases capture and preserves camera',
      () async {
        final stopped = <String>[];
        handle = (call) async {
          if (call.method == 'trackDispose') {
            stopped.add((call.arguments as Map)['trackId'] as String);
          }
          if (call.method != 'getUserMedia') return null;
          return ((call.arguments as Map)['constraints'] as Map)['audio'] ==
                  true
              ? microphoneStream(1)
              : cameraStream(1);
        };
        final peer = _SharingPeer();
        final service = makeService(peerFactory: () async => peer);
        final server = FileServer(const AppLogger());
        await service.startCameraSharing(server, camera: back);
        await server.cameraOfferHandler!({
          'type': 'offer',
          'sdp': _cameraOfferSdp,
        });
        final sender = peer.associatedTransceivers.single.sender
          ..failAudioReplacement = true;
        await expectLater(
          service.setCameraMicrophoneEnabled(true),
          throwsStateError,
        );
        expect(sender.replacedTracks.last, isNull);
        expect(stopped, contains('camera-audio-1'));
        expect(stopped, isNot(contains('camera-video-1')));
        expect(service.cameraMicrophoneEnabled, isFalse);
        expect(service.state.value.mode, ScreenShareMode.sharing);
        await service.stop(server);
      },
    );

    test(
      'stop waits for late microphone acquisition and releases it without activating',
      () async {
        final pending = Completer<Map<String, dynamic>>();
        final acquiring = Completer<void>();
        final stops = <String>[];
        handle = (call) async {
          if (call.method == 'trackDispose') {
            stops.add((call.arguments as Map)['trackId'] as String);
          }
          if (call.method != 'getUserMedia') return null;
          if (((call.arguments as Map)['constraints'] as Map)['audio'] ==
              true) {
            acquiring.complete();
            return pending.future;
          }
          return cameraStream(1);
        };
        final gateValues = <bool>[];
        final service = makeService(
          audioRecordingGate: (enabled) async {
            gateValues.add(enabled);
          },
        );
        final server = FileServer(const AppLogger());
        await service.startCameraSharing(server, camera: back);
        final enabling = service.setCameraMicrophoneEnabled(true);
        await acquiring.future;
        var stopped = false;
        final stopping = service.stop(server).then((_) => stopped = true);
        await Future<void>.delayed(Duration.zero);
        expect(stopped, isFalse);
        expect(gateValues.last, isFalse);
        pending.complete(microphoneStream(1));
        await Future.wait([enabling, stopping]);
        expect(stops, contains('camera-audio-1'));
        expect(service.cameraMicrophoneEnabled, isFalse);
        expect(service.state.value.mode, ScreenShareMode.idle);
      },
    );

    test(
      'turning off during microphone acquisition releases the late capture',
      () async {
        final pending = Completer<Map<String, dynamic>>();
        final acquiring = Completer<void>();
        final stopped = <String>[];
        handle = (call) async {
          if (call.method == 'trackDispose') {
            stopped.add((call.arguments as Map)['trackId'] as String);
          }
          if (call.method != 'getUserMedia') return null;
          if (((call.arguments as Map)['constraints'] as Map)['audio'] ==
              true) {
            acquiring.complete();
            return pending.future;
          }
          return cameraStream(1);
        };
        final service = makeService();
        final server = FileServer(const AppLogger());
        await service.startCameraSharing(server, camera: back);
        final enabling = service.setCameraMicrophoneEnabled(true);
        await acquiring.future;
        final disabling = service.setCameraMicrophoneEnabled(false);
        pending.complete(microphoneStream(1));
        await Future.wait([enabling, disabling]);
        expect(service.cameraMicrophoneEnabled, isFalse);
        expect(stopped, contains('camera-audio-1'));
        expect(service.state.value.mode, ScreenShareMode.sharing);
        await service.stop(server);
      },
    );

    test(
      'camera flash follows hardware availability and resets on flip and stop',
      () async {
        var captures = 0;
        final torchChanges = <Map<dynamic, dynamic>>[];
        handle = (call) async {
          if (call.method == 'getUserMedia') return cameraStream(++captures);
          if (call.method == 'mediaStreamTrackHasTorch') return captures != 2;
          if (call.method == 'mediaStreamTrackSetTorch') {
            torchChanges.add(Map<dynamic, dynamic>.from(call.arguments as Map));
          }
          return null;
        };
        final service = makeService();
        final server = FileServer(const AppLogger());
        await service.startCameraSharing(server, camera: back);
        expect(service.cameraTorchAvailable, isTrue);
        expect(service.cameraTorchEnabled, isFalse);
        await service.setCameraTorchEnabled(true);
        expect(service.cameraTorchEnabled, isTrue);
        expect(torchChanges.last, {'trackId': 'camera-video-1', 'torch': true});
        await service.switchCamera(
          front,
          settings: const ScreenCaptureSettings(),
        );
        expect(torchChanges.last, {
          'trackId': 'camera-video-1',
          'torch': false,
        });
        expect(service.cameraTorchEnabled, isFalse);
        expect(service.cameraTorchAvailable, isFalse);
        await expectLater(
          service.setCameraTorchEnabled(true),
          throwsStateError,
        );
        await service.switchCamera(
          back,
          settings: const ScreenCaptureSettings(),
        );
        expect(service.cameraTorchAvailable, isTrue);
        await service.setCameraTorchEnabled(true);
        await service.stop(server);
        expect(torchChanges.last, {
          'trackId': 'camera-video-3',
          'torch': false,
        });
        expect(service.cameraTorchEnabled, isFalse);
        expect(service.cameraTorchAvailable, isFalse);
      },
    );

    test(
      'camera enumeration keeps one native camera per side without acquiring it',
      () async {
        handle = (call) async => call.method == 'getSources'
            ? {
                'sources': [
                  {
                    'deviceId': '0',
                    'kind': 'videoinput',
                    'label': 'Camera 0, Facing back',
                    'groupId': 'camera',
                  },
                  {
                    'deviceId': '1',
                    'kind': 'videoinput',
                    'label': 'Camera 1, Facing front',
                    'groupId': 'camera',
                  },
                  {
                    'deviceId': '1',
                    'kind': 'videoinput',
                    'label': 'Duplicate',
                    'groupId': 'camera',
                  },
                  {
                    'deviceId': '2',
                    'kind': 'videoinput',
                    'label': 'Camera 2, Facing back',
                    'facing': 'back',
                  },
                  {
                    'deviceId': '3',
                    'kind': 'videoinput',
                    'label': 'Camera 3, Facing front',
                    'facing': 'front',
                  },
                  {
                    'deviceId': 'audio',
                    'kind': 'audioinput',
                    'label': 'Microphone',
                    'groupId': 'audio',
                  },
                ],
              }
            : null;
        final local = _Renderer();
        final service = makeService(local: local);
        final cameras = await service.enumerateCameras();
        expect(cameras.map((camera) => camera.id), ['0', '1']);
        expect(cameras.map((camera) => camera.frontFacing), [false, true]);
        expect(cameras.map((camera) => camera.label), [
          'Rear camera',
          'Front camera',
        ]);
        expect(calls, contains('getSources'));
        expect(calls, isNot(contains('getUserMedia')));
        expect(calls, isNot(contains('getDisplayMedia')));
        expect(local.initializes, 0);
      },
    );

    test(
      'native facing groups localized sensors and preserves SDK preferred logical IDs',
      () async {
        handle = (call) async => call.method == 'getSources'
            ? {
                'sources': [
                  {
                    'deviceId': 'front-logical',
                    'kind': 'videoinput',
                    'label': 'Kamera für Selfies',
                    'facing': 'front',
                  },
                  {
                    'deviceId': 'rear-logical',
                    'kind': 'videoinput',
                    'label': 'Cámara triple',
                    'facing': 'back',
                  },
                  {
                    'deviceId': 'rear-wide',
                    'kind': 'videoinput',
                    'label': 'Gran angular',
                    'facing': 'back',
                  },
                  {
                    'deviceId': 'front-sensor',
                    'kind': 'videoinput',
                    'label': 'Sensor',
                    'facing': 'front',
                  },
                  {
                    'deviceId': '',
                    'kind': 'videoinput',
                    'label': 'Unavailable',
                    'facing': 'back',
                  },
                ],
              }
            : null;
        final service = makeService();
        final cameras = await service.enumerateCameras();
        expect(cameras.map((camera) => camera.id), [
          'rear-logical',
          'front-logical',
        ]);
        expect(cameras.map((camera) => camera.frontFacing), [false, true]);
        expect(calls, ['getSources']);
      },
    );

    test('a front-only device does not invent a rear camera', () async {
      handle = (call) async => {
        'sources': [
          {
            'deviceId': 'front-only',
            'kind': 'videoinput',
            'label': 'Kamera',
            'facing': 'front',
          },
        ],
      };
      final cameras = await makeService().enumerateCameras();
      expect(cameras, hasLength(1));
      expect(cameras.single.id, 'front-only');
      expect(cameras.single.frontFacing, isTrue);
    });

    test(
      'unknown external inputs collapse to one camera without inventing a front',
      () async {
        handle = (call) async => {
          'sources': [
            {'deviceId': 'usb-a', 'kind': 'videoinput', 'label': 'USB camera'},
            {'deviceId': 'usb-b', 'kind': 'videoinput', 'label': 'USB camera'},
          ],
        };
        final cameras = await makeService().enumerateCameras();
        expect(cameras, hasLength(1));
        expect(cameras.single.id, 'usb-a');
        expect(cameras.single.frontFacing, isFalse);
      },
    );

    test(
      'camera capture is video only, coalesces starts and blocks screen overlap',
      () async {
        Map? constraints;
        final defaultHandler = handle;
        handle = (call) async {
          if (call.method == 'getUserMedia') {
            constraints = (call.arguments as Map)['constraints'] as Map;
          }
          return defaultHandler(call);
        };
        final service = makeService();
        final server = FileServer(const AppLogger());
        await Future.wait([
          service.startCameraSharing(
            server,
            camera: back,
            settings: const ScreenCaptureSettings(
              resolution: 720,
              frameRate: 60,
            ),
          ),
          service.startCameraSharing(
            server,
            camera: back,
            settings: const ScreenCaptureSettings(
              resolution: 720,
              frameRate: 60,
            ),
          ),
        ]);
        expect(calls.where((call) => call == 'getUserMedia'), hasLength(1));
        expect(constraints!['audio'], false);
        expect(constraints!['video'], {
          'deviceId': '0',
          'facingMode': 'environment',
          'width': 1280,
          'height': 720,
          'frameRate': 60,
        });
        expect(service.source, VideoShareSource.camera);
        expect(service.currentCamera, same(back));
        expect(server.screenOfferHandler, isNull);
        expect(server.cameraOfferHandler, isNotNull);
        expect(server.cameraMetadataHandler!()['source'], 'camera');
        await expectLater(service.startSharing(server), throwsStateError);
        await expectLater(service.watch(_device), throwsStateError);
        await service.stop(server);
        expect(server.cameraOfferHandler, isNull);
        expect(server.cameraMetadataHandler, isNull);
        expect(service.currentCamera, isNull);
      },
    );

    test(
      'switching physical cameras replaces tracks without another peer or simultaneous capturers',
      () async {
        var captures = 0;
        handle = (call) async =>
            call.method == 'getUserMedia' ? cameraStream(++captures) : null;
        final peer = _SharingPeer();
        final service = makeService(peerFactory: () async => peer);
        final server = FileServer(const AppLogger());
        await service.startCameraSharing(server, camera: back);
        await service.switchCamera(
          back,
          settings: const ScreenCaptureSettings(),
        );
        expect(captures, 1);
        await server.cameraOfferHandler!({
          'type': 'offer',
          'sdp': _cameraOfferSdp,
        });
        final generation = server.cameraMetadataHandler!()['generation'];
        await service.switchCamera(
          front,
          settings: const ScreenCaptureSettings(resolution: 480, frameRate: 15),
        );
        expect(service.currentCamera, same(front));
        expect(peer.sender.replacedTracks.single!.id, 'camera-video-2');
        expect(peer.sender.parameters.encodings!.single.maxFramerate, 15);
        expect(server.cameraMetadataHandler!()['generation'], generation);
        expect(server.cameraMetadataHandler!()['cameraId'], '1');
        expect(
          calls.indexOf('trackDispose'),
          lessThan(calls.lastIndexOf('getUserMedia')),
        );
        expect(
          calls.indexOf('streamDispose'),
          lessThan(calls.lastIndexOf('getUserMedia')),
        );
        expect(peer.closes, 0);
        await service.switchCamera(
          back,
          settings: const ScreenCaptureSettings(
            resolution: 1080,
            frameRate: 60,
          ),
        );
        expect(peer.sender.replacedTracks.last!.id, 'camera-video-3');
        expect(peer.sender.parameters.encodings!.single.maxFramerate, 60);
        expect(captures, 3);
        await service.stop(server);
        expect(peer.disposes, 1);
        expect(calls.where((call) => call == 'trackDispose'), hasLength(3));
        expect(calls.where((call) => call == 'streamDispose'), hasLength(3));
      },
    );

    test(
      'stop waits for an in-flight camera switch and releases its late capture',
      () async {
        final pending = Completer<dynamic>();
        final switchingStarted = Completer<void>();
        var captures = 0;
        handle = (call) async {
          if (call.method != 'getUserMedia') return null;
          captures++;
          if (captures == 1) return cameraStream(1);
          switchingStarted.complete();
          return pending.future;
        };
        var peerCreations = 0;
        final service = makeService(
          peerFactory: () async {
            peerCreations++;
            return _SharingPeer();
          },
        );
        final server = FileServer(const AppLogger());
        await service.startCameraSharing(server, camera: back);
        final switching = service.switchCamera(
          front,
          settings: const ScreenCaptureSettings(),
        );
        final duplicate = service.switchCamera(
          front,
          settings: const ScreenCaptureSettings(),
        );
        expect(identical(switching, duplicate), isTrue);
        await switchingStarted.future;
        expect(
          identical(
            switching,
            service.switchCamera(
              front,
              settings: const ScreenCaptureSettings(),
            ),
          ),
          isTrue,
        );
        await expectLater(service.watchCamera(_device), throwsStateError);
        await expectLater(service.startSharing(server), throwsStateError);
        await expectLater(
          service.startCameraSharing(server, camera: back),
          throwsStateError,
        );
        final queuedOffer = server
            .cameraOfferHandler!({'type': 'offer', 'sdp': _cameraOfferSdp})
            .then<Object?>(
              (answer) => answer,
              onError: (Object error) => error,
            );
        var stopped = false;
        final stopping = service.stop(server).then((_) => stopped = true);
        await Future<void>.delayed(Duration.zero);
        expect(stopped, isFalse);
        pending.complete(cameraStream(2));
        await Future.wait([switching, duplicate, stopping]);
        expect(await queuedOffer, isA<StateError>());
        expect(peerCreations, 0);
        expect(service.state.value.mode, ScreenShareMode.idle);
        expect(service.localRenderer.srcObject, isNull);
        expect(server.cameraOfferHandler, isNull);
        expect(calls.where((call) => call == 'trackDispose'), hasLength(2));
        expect(calls.where((call) => call == 'streamDispose'), hasLength(2));
      },
    );

    test(
      'failed camera switch restores the previous camera and existing sender',
      () async {
        var captures = 0;
        handle = (call) async {
          if (call.method != 'getUserMedia') return null;
          captures++;
          if (captures == 2) {
            throw PlatformException(code: 'camera-unavailable');
          }
          return cameraStream(captures);
        };
        final peer = _SharingPeer();
        final service = makeService(peerFactory: () async => peer);
        final server = FileServer(const AppLogger());
        await service.startCameraSharing(server, camera: back);
        await server.cameraOfferHandler!({
          'type': 'offer',
          'sdp': _cameraOfferSdp,
        });
        await expectLater(
          service.switchCamera(
            front,
            settings: const ScreenCaptureSettings(frameRate: 60),
          ),
          throwsA(anything),
        );
        expect(service.currentCamera, same(back));
        expect(service.captureSettings.frameRate, 30);
        expect(peer.sender.replacedTracks.single!.id, 'camera-video-3');
        expect(service.state.value.mode, ScreenShareMode.sharing);
        expect(peer.disposes, 0);
        await service.stop(server);
      },
    );

    test(
      'camera rollback failure closes the session and releases receiver ownership',
      () async {
        var captures = 0;
        var releases = 0;
        handle = (call) async {
          if (call.method != 'getUserMedia') return null;
          captures++;
          if (captures > 1) throw PlatformException(code: 'camera-unavailable');
          return cameraStream(1);
        };
        final peer = _SharingPeer();
        final service = makeService(
          peerFactory: () async => peer,
          onSharingStopped: () async => releases++,
        );
        final server = FileServer(const AppLogger());
        await service.startCameraSharing(server, camera: back);
        await server.cameraOfferHandler!({
          'type': 'offer',
          'sdp': _cameraOfferSdp,
        });
        await expectLater(
          service.switchCamera(front, settings: const ScreenCaptureSettings()),
          throwsA(anything),
        );
        expect(service.state.value.mode, ScreenShareMode.idle);
        expect(service.currentCamera, isNull);
        expect(server.cameraOfferHandler, isNull);
        expect(peer.disposes, 1);
        expect(releases, 1);
      },
    );

    test(
      'USB camera answer keeps only candidates on the selected interface',
      () async {
        final peer = _SharingPeer()
          ..localSdp =
              '$_sdp'
              'c=IN IP4 192.168.1.4\r\n'
              'a=candidate:1 1 udp 123 192.168.1.4 5001 typ host\r\n'
              'a=candidate:2 1 udp 123 127.0.0.2 5002 typ host\r\n'
              'a=candidate:3 1 udp 123 198.51.100.7 5003 typ relay raddr 192.168.1.4 rport 5001\r\n';
        final service = makeService(peerFactory: () async => peer);
        final server = FileServer(const AppLogger());
        await service.startCameraSharing(
          server,
          camera: back,
          allowedLocalIps: ['127.0.0.2'],
          allowedRemoteSubnets: ['127.0.0.0/8'],
        );
        final answer = await server.cameraOfferHandler!({
          'type': 'offer',
          'sdp': _sdp,
        });
        final sdp = answer['sdp'] as String;
        expect(sdp, contains('127.0.0.2'));
        expect(sdp, isNot(contains('192.168.1.4')));
        expect(sdp, isNot(contains('198.51.100.7')));
        expect(server.cameraAllowedRemoteSubnets, ['127.0.0.0/8']);
        await service.stop(server);
        expect(server.cameraAllowedRemoteSubnets, isNull);
      },
    );

    test(
      'USB camera does not fall back when WebRTC lacks a USB candidate',
      () async {
        final peer = _SharingPeer();
        final service = makeService(peerFactory: () async => peer);
        final server = FileServer(const AppLogger());
        await expectLater(
          service.startCameraSharing(server, camera: back, allowedLocalIps: []),
          throwsStateError,
        );
        await expectLater(
          service.startCameraSharing(
            server,
            camera: back,
            allowedLocalIps: ['127.0.0.2'],
          ),
          throwsStateError,
        );
        expect(calls, isNot(contains('getUserMedia')));
        await service.startCameraSharing(
          server,
          camera: back,
          allowedLocalIps: ['127.0.0.2'],
          allowedRemoteSubnets: ['127.0.0.0/8'],
        );
        await expectLater(
          server.cameraOfferHandler!({'type': 'offer', 'sdp': _cameraOfferSdp}),
          throwsStateError,
        );
        expect(peer.disposes, 1);
        expect(service.state.value.mode, ScreenShareMode.sharing);
        await service.stop(server);
      },
    );

    test(
      'chosen capture cadence and encoder limits survive rotation without another capture',
      () async {
        final peer = _SharingPeer();
        final renderer = _Renderer();
        renderer.value = renderer.value.copyWith(width: 2160, height: 4632);
        Map<dynamic, dynamic>? captureArguments;
        final defaultHandler = handle;
        handle = (call) async {
          if (call.method == 'getDisplayMedia') {
            captureArguments = call.arguments as Map<dynamic, dynamic>;
          }
          return defaultHandler(call);
        };
        final service = makeService(
          local: renderer,
          peerFactory: () async => peer,
        );
        final server = FileServer(const AppLogger());
        await service.startSharing(
          server,
          settings: const ScreenCaptureSettings(resolution: 720, frameRate: 60),
        );
        expect(
          ((captureArguments!['constraints'] as Map)['video']
              as Map)['mandatory'],
          {'frameRate': 60.0},
        );
        await server.screenOfferHandler!({'type': 'offer', 'sdp': _sdp});
        expect(peer.sender.parameters.encodings!.single.maxFramerate, 60);
        expect(
          peer.sender.parameters.encodings!.single.scaleResolutionDownBy,
          3,
        );
        renderer.value = renderer.value.copyWith(width: 4632, height: 2160);
        renderer.onResize!();
        await Future<void>.delayed(Duration.zero);
        expect(
          peer.sender.parameters.encodings!.single.scaleResolutionDownBy,
          3,
        );
        expect(calls.where((name) => name == 'getDisplayMedia'), hasLength(1));
        await service.stop(server);
        final updates = peer.sender.updates;
        renderer.onResize!();
        await Future<void>.delayed(Duration.zero);
        expect(peer.sender.updates, updates);
      },
    );

    test('capture stop waits for its receiver cleanup once', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var releases = 0;
      final service = makeService(
        onSharingStopped: () async {
          releases++;
          entered.complete();
          await release.future;
        },
      );
      final server = FileServer(const AppLogger());
      await service.startSharing(server);
      final first = service.stop(server);
      final second = service.stop(server);
      await entered.future;
      expect(releases, 1);
      release.complete();
      await Future.wait([first, second]);
      expect(service.state.value.mode, ScreenShareMode.idle);
    });

    test('immediate stop aborts startup and leaves the service idle', () async {
      final service = makeService();
      final server = FileServer(const AppLogger());
      final starting = service.startSharing(server);
      await service.stop(server);
      await starting;
      expect(service.state.value.mode, ScreenShareMode.idle);
      expect(calls, isNot(contains('getDisplayMedia')));
      await service.dispose();
    });

    test(
      'duplicate sharing captures once and stop awaits native track cleanup',
      () async {
        final stoppedTrack = Completer<dynamic>();
        final stopStarted = Completer<void>();
        final defaultHandler = handle;
        handle = (call) async {
          if (call.method == 'trackDispose') {
            stopStarted.complete();
            return stoppedTrack.future;
          }
          return defaultHandler(call);
        };
        final service = makeService();
        final server = FileServer(const AppLogger());
        await Future.wait([
          service.startSharing(server),
          service.startSharing(server),
        ]);
        await service.startSharing(server);
        expect(calls.where((call) => call == 'getDisplayMedia'), hasLength(1));
        expect(server.screenOfferHandler, isNotNull);
        expect((service.localRenderer as _Renderer).lastBoundTrackId, 'video');
        final stopping = service.stop(server);
        await stopStarted.future;
        expect(calls, isNot(contains('streamDispose')));
        stoppedTrack.complete();
        await stopping;
        expect(calls.where((call) => call == 'trackDispose'), hasLength(1));
        expect(calls.where((call) => call == 'streamDispose'), hasLength(1));
        expect(server.screenOfferHandler, isNull);
        expect(server.screenMetadataHandler, isNull);
        expect(service.localRenderer.srcObject, isNull);
        await service.dispose();
      },
    );

    test(
      'capture completing after stop is disposed without reactivating',
      () async {
        final capture = Completer<dynamic>();
        final captureStarted = Completer<void>();
        final defaultHandler = handle;
        handle = (call) async {
          if (call.method == 'getDisplayMedia') {
            captureStarted.complete();
            return capture.future;
          }
          return defaultHandler(call);
        };
        final service = makeService();
        final server = FileServer(const AppLogger());
        final starting = service.startSharing(server);
        await captureStarted.future;
        await service.stop(server);
        capture.complete(streamData);
        await starting;
        expect(service.state.value.mode, ScreenShareMode.idle);
        expect(service.localRenderer.srcObject, isNull);
        expect(server.screenOfferHandler, isNull);
        expect(calls.where((call) => call == 'trackDispose'), hasLength(1));
        expect(calls.where((call) => call == 'streamDispose'), hasLength(1));
        await service.dispose();
      },
    );

    test('stop during source lookup prevents a late capture request', () async {
      final sources = Completer<dynamic>();
      final lookupStarted = Completer<void>();
      handle = (call) async {
        if (call.method == 'getDesktopSources') {
          lookupStarted.complete();
          return sources.future;
        }
        return null;
      };
      final service = makeService();
      final server = FileServer(const AppLogger());
      final starting = service.startSharing(server);
      await lookupStarted.future;
      await service.stop(server);
      sources.complete({
        'sources': [
          {
            'id': 'screen:0',
            'name': 'Screen',
            'type': 'screen',
            'thumbnailSize': {'width': 0, 'height': 0},
          },
        ],
      });
      await starting;
      expect(calls, isNot(contains('getDisplayMedia')));
      expect(service.state.value.mode, ScreenShareMode.idle);
      await service.dispose();
    });

    test(
      'dispose clears server callbacks and native capture resources',
      () async {
        final service = makeService();
        final server = FileServer(const AppLogger());
        await service.startSharing(server);
        await service.dispose();
        expect(server.screenOfferHandler, isNull);
        expect(server.screenMetadataHandler, isNull);
        expect(calls.where((call) => call == 'trackDispose'), hasLength(1));
        expect(calls.where((call) => call == 'streamDispose'), hasLength(1));
      },
    );
    test(
      'metadata dimensions match captured frames instead of activity insets',
      () async {
        final renderer = _Renderer();
        final service = makeService(local: renderer);
        final server = FileServer(const AppLogger());
        await service.startSharing(server);
        service.updateLocalScreenMetrics(1080, 2181);
        for (final rotation in [0, 90, 180, 270]) {
          renderer.value = RTCVideoValue(
            width: 1080,
            height: 2316,
            rotation: rotation,
            renderVideo: true,
          );
          final metadata = server.screenMetadataHandler!();
          final quarterTurn = rotation == 90 || rotation == 270;
          expect(metadata['width'], quarterTurn ? 2316 : 1080);
          expect(metadata['height'], quarterTurn ? 1080 : 2316);
          expect(
            metadata['aspectRatio'],
            closeTo(
              (metadata['width'] as int) / (metadata['height'] as int),
              0.00001,
            ),
          );
        }
        await service.stop(server);
        await service.dispose();
      },
    );
  });
}
