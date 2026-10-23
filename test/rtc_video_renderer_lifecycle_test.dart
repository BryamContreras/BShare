import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class _TestMediaStream extends Fake implements MediaStream {
  @override
  String get id => 'stream-1';

  @override
  String get ownerTag => 'local';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('FlutterWebRTC.Method');
  const events = MethodChannel('FlutterWebRTC/Texture7');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> calls;
  late Future<dynamic> Function(MethodCall) handleCall;

  setUp(() {
    calls = [];
    handleCall = (call) async =>
        call.method == 'createVideoRenderer' ? {'textureId': 7} : null;
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call.method);
      return handleCall(call);
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  test('failed initialization permits a retry', () async {
    final renderer = RTCVideoRenderer();
    var attempts = 0;
    handleCall = (call) async {
      if (call.method == 'createVideoRenderer') {
        if (++attempts == 1) {
          throw PlatformException(code: 'temporarily_unavailable');
        }
        return {'textureId': 7};
      }
      return null;
    };

    await expectLater(renderer.initialize(), throwsA(isA<PlatformException>()));
    await renderer.initialize().timeout(const Duration(seconds: 2));
    expect(attempts, 2);
    expect(renderer.textureId, 7);
    await renderer.dispose();
  });

  test('concurrent initialization creates one native texture', () async {
    final renderer = RTCVideoRenderer();
    final creation = Completer<dynamic>();
    handleCall = (call) async =>
        call.method == 'createVideoRenderer' ? creation.future : null;
    final first = renderer.initialize();
    final second = renderer.initialize();
    creation.complete({'textureId': 7});
    await Future.wait([first, second]);
    expect(
      calls.where((method) => method == 'createVideoRenderer'),
      hasLength(1),
    );
    await renderer.dispose();
  });

  test('dispose waits for creation and releases its texture once', () async {
    final renderer = RTCVideoRenderer();
    final creation = Completer<dynamic>();
    handleCall = (call) async =>
        call.method == 'createVideoRenderer' ? creation.future : null;
    final initialization = renderer.initialize();
    final firstDisposal = renderer.dispose();
    final secondDisposal = renderer.dispose();
    creation.complete({'textureId': 7});
    await Future.wait([initialization, firstDisposal, secondDisposal]);
    expect(
      calls.where((method) => method == 'videoRendererDispose'),
      hasLength(1),
    );
    expect(renderer.textureId, isNull);
    await renderer.dispose();
    await expectLater(renderer.initialize(), throwsStateError);
  });

  test('dispose without initialization is idempotent', () async {
    final renderer = RTCVideoRenderer();
    await renderer.dispose();
    await renderer.dispose();
    expect(calls, isEmpty);
    await expectLater(renderer.initialize(), throwsStateError);
  });

  test('a pending source change cannot notify after disposal', () async {
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    final sourceChanged = Completer<dynamic>();
    handleCall = (call) async => call.method == 'videoRendererSetSrcObject'
        ? sourceChanged.future
        : null;
    final changingSource = renderer.setSrcObject();
    await renderer.dispose();
    sourceChanged.complete();
    await changingSource;
  });

  test(
    'default async source assignment matches setter track selection',
    () async {
      final renderer = RTCVideoRenderer();
      await renderer.initialize();
      final assignments = <Map<dynamic, dynamic>>[];
      handleCall = (call) async {
        if (call.method == 'videoRendererSetSrcObject') {
          assignments.add(call.arguments as Map<dynamic, dynamic>);
        }
        return null;
      };
      final stream = _TestMediaStream();

      renderer.srcObject = stream;
      await Future<void>.delayed(Duration.zero);
      await renderer.setSrcObject(stream: stream);

      expect(assignments, hasLength(2));
      expect(assignments.last, assignments.first);
      // Desktop selects the first stream track when this optional ID is absent.
      expect(assignments.last, isNot(contains('trackId')));
      expect(assignments.last['streamId'], 'stream-1');
      await renderer.dispose();
    },
  );

  test('explicit source track IDs are preserved', () async {
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    final assignments = <Map<dynamic, dynamic>>[];
    handleCall = (call) async {
      if (call.method == 'videoRendererSetSrcObject') {
        assignments.add(call.arguments as Map<dynamic, dynamic>);
      }
      return null;
    };

    await renderer.setSrcObject(
      stream: _TestMediaStream(),
      trackId: 'track-42',
    );

    expect(assignments.single['trackId'], 'track-42');
    expect(assignments.single['streamId'], 'stream-1');
    await renderer.dispose();
  });
}
