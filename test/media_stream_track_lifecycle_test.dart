import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/src/native/event_channel.dart';
import 'package:flutter_webrtc/src/native/media_stream_track_impl.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('FlutterWebRTC.Method');
  const events = MethodChannel('FlutterWebRTC.Event');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late List<MediaStreamTrackNative> tracks;
  late Future<dynamic> Function(MethodCall) handleCall;

  MediaStreamTrackNative track([String id = 'screen-1']) {
    final result = MediaStreamTrackNative(id, id, 'video', true, 'local');
    tracks.add(result);
    return result;
  }

  Future<void> emit(Map<String, dynamic> event) async {
    await messenger.handlePlatformMessage(
      events.name,
      codec.encodeSuccessEnvelope(event),
      null,
    );
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> ended(String id) =>
      emit({'event': 'onScreenCaptureStopped', 'trackId': id});

  int disposalCount() =>
      calls.where((call) => call.method == 'trackDispose').length;

  setUp(() {
    calls = [];
    tracks = [];
    handleCall = (_) async => null;
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(methods, (call) {
      calls.add(call);
      return handleCall(call);
    });
  });

  tearDown(() async {
    for (final value in tracks) {
      value.onEnded = null;
      await value.dispose();
    }
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  test(
    'callback clearing and native end cancel the track subscription',
    () async {
      final value = track();
      final controller = FlutterWebRTCEventChannel.instance.handleEvents;
      expect(controller.hasListener, isFalse);
      var notifications = 0;
      value.onEnded = () => notifications++;
      expect(controller.hasListener, isTrue);

      value.onEnded = null;
      await Future<void>.delayed(Duration.zero);
      expect(controller.hasListener, isFalse);
      await ended(value.id);
      expect(notifications, 0);

      value.onEnded = () => notifications++;
      expect(controller.hasListener, isTrue);
      await ended(value.id);
      expect(notifications, 1);
      expect(value.onEnded, isNull);
      expect(controller.hasListener, isFalse);
    },
  );

  test(
    'global capture events are filtered by event type and track ID',
    () async {
      final first = track();
      final second = track('screen-2');
      var firstEnded = 0;
      var secondEnded = 0;
      first.onEnded = () => firstEnded++;
      second.onEnded = () => secondEnded++;

      await ended('unrelated-track');
      await emit({'event': 'onDeviceChange', 'trackId': first.id});
      await emit({'event': 'onScreenCaptureStopped'});
      expect(firstEnded, 0);
      expect(secondEnded, 0);

      await ended(first.id);
      expect(firstEnded, 1);
      expect(secondEnded, 0);
      await ended(second.id);
      expect(secondEnded, 1);
    },
  );

  test(
    'a native end is delivered once even if the callback is reassigned',
    () async {
      final value = track();
      var notifications = 0;
      value.onEnded = () => notifications++;

      await ended(value.id);
      await ended(value.id);
      value.onEnded = () => notifications += 10;
      await ended(value.id);
      expect(notifications, 1);
      expect(disposalCount(), 0);
      await value.stop();
      expect(disposalCount(), 1);
    },
  );

  test('playback audio failure ends only its audio track once', () async {
    final video = track();
    final audio = MediaStreamTrackNative(
      'playback-1',
      'Device playback',
      'audio',
      true,
      'local',
    );
    tracks.add(audio);
    var videoEnded = 0;
    var audioEnded = 0;
    video.onEnded = () => videoEnded++;
    audio.onEnded = () => audioEnded++;
    await emit({'event': 'onAudioCaptureStopped', 'trackId': audio.id});
    await emit({'event': 'onAudioCaptureStopped', 'trackId': audio.id});
    expect(audioEnded, 1);
    expect(audio.onEnded, isNull);
    expect(videoEnded, 0);
    expect(video.onEnded, isNotNull);
    await ended(video.id);
    expect(videoEnded, 1);
  });

  test('replacing an active callback uses only its latest value', () async {
    final value = track();
    var first = 0;
    var second = 0;
    value.onEnded = () => first++;
    value.onEnded = () => second++;

    await ended(value.id);
    expect(first, 0);
    expect(second, 1);
  });

  test('concurrent stop and dispose await one native disposal', () async {
    final value = track();
    final nativeDisposal = Completer<void>();
    handleCall = (call) async {
      if (call.method == 'trackDispose') await nativeDisposal.future;
      return null;
    };
    var notifications = 0;
    value.onEnded = () => notifications++;

    final first = value.stop();
    final second = value.stop();
    final disposing = value.dispose();
    var completed = false;
    unawaited(disposing.then((_) => completed = true));
    await ended(value.id);
    expect(value.onEnded, isNull);
    expect(notifications, 0);
    expect(disposalCount(), 1);
    expect(completed, isFalse);

    nativeDisposal.complete();
    await Future.wait([first, second, disposing]);
    await value.dispose();
    expect(completed, isTrue);
    expect(disposalCount(), 1);
  });

  test(
    'callbacks assigned after explicit stop cannot reactivate listeners',
    () async {
      final value = track();
      var notifications = 0;
      value.onEnded = () => notifications++;
      await value.stop();
      value.onEnded = () => notifications++;

      await ended(value.id);
      expect(value.onEnded, isNull);
      expect(notifications, 0);
      expect(disposalCount(), 1);
    },
  );

  test(
    'failed native disposal can retry without restoring callbacks',
    () async {
      final value = track();
      var attempts = 0;
      handleCall = (call) async {
        if (call.method == 'trackDispose' && ++attempts == 1) {
          throw PlatformException(code: 'retry-disposal');
        }
        return null;
      };
      var notifications = 0;
      value.onEnded = () => notifications++;

      await expectLater(value.stop(), throwsA(isA<PlatformException>()));
      await ended(value.id);
      expect(value.onEnded, isNull);
      expect(notifications, 0);
      await value.dispose();
      expect(attempts, 2);
      expect(disposalCount(), 2);
    },
  );

  test(
    'native-ended callback can stop the track during notification',
    () async {
      final value = track();
      Future<void>? stopping;
      var notifications = 0;
      value.onEnded = () {
        notifications++;
        stopping = value.stop();
      };

      await ended(value.id);
      await stopping;
      await ended(value.id);
      expect(notifications, 1);
      expect(disposalCount(), 1);
    },
  );
}
