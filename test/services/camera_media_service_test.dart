import 'dart:async';
import 'dart:io';

import 'package:bshare/src/infrastructure/services/android_screen_share_execution_service.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/camera_media_service.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class _Source extends ScreenShareService {
  _Source() : super(const AppLogger(), AndroidScreenShareExecutionService());
}

void main() {
  late Directory directory;
  late SharedPreferences preferences;
  late _Source source;
  late CameraMediaService media;
  late CameraMediaInput? input;
  late List<({String method, Map<String, dynamic> arguments})> calls;
  Completer<void>? startGate;
  Completer<void>? stopGate;
  String? recordingPath;
  bool photoFails = false;
  bool stopFails = false;
  bool supported = true;

  Future<dynamic> invoke(String method, Map<String, dynamic> arguments) async {
    calls.add((method: method, arguments: {...arguments}));
    switch (method) {
      case 'desktopMediaGetDirectories':
        return {
          'supported': supported,
          'pictures': p.join(directory.path, 'KnownPictures'),
          'videos': p.join(directory.path, 'KnownMovies'),
        };
      case 'desktopMediaTakePhoto':
        if (photoFails) throw PlatformException(code: 'disk-full');
        expect(
          await Directory(p.dirname(arguments['path'] as String)).exists(),
          isTrue,
        );
        return {'path': arguments['path']};
      case 'desktopMediaStartRecording':
        await startGate?.future;
        recordingPath = arguments['path'] as String;
        return {'recorderId': 'owned-recorder'};
      case 'desktopMediaStopRecording':
        await stopGate?.future;
        if (stopFails) throw PlatformException(code: 'writer-failed');
        return {'path': recordingPath};
      default:
        throw StateError('Unexpected native operation');
    }
  }

  CameraMediaService create({String os = 'test-os'}) => CameraMediaService(
    source: source,
    nativeInvoke: invoke,
    preferences: () async => preferences,
    readInput: () => input,
    operatingSystem: os,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bshare-camera-media-');
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    source = _Source();
    source.state.value = const ScreenShareState(mode: ScreenShareMode.watching);
    input = const CameraMediaInput(
      peerConnectionId: 'remote-peer',
      videoTrackId: 'remote-video',
      audioTrackId: 'remote-audio',
    );
    calls = [];
    startGate = stopGate = null;
    photoFails = stopFails = false;
    supported = true;
    recordingPath = null;
    media = create();
  });

  tearDown(() async {
    startGate?.completeIfPending();
    stopGate?.completeIfPending();
    await media.dispose();
    await source.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'uses OS known folders lazily and persists selected directories per OS',
    () async {
      await media.initialize();
      expect(media.state.value.ready, isTrue);
      expect(
        media.state.value.photoDirectory,
        p.join(directory.path, 'KnownPictures', 'BShare'),
      );
      expect(
        media.state.value.videoDirectory,
        p.join(directory.path, 'KnownMovies', 'BShare'),
      );
      expect(
        await Directory(media.state.value.photoDirectory!).exists(),
        isFalse,
      );
      final selected = p.join(directory.path, 'Chosen Photos');
      await media.setPhotoDirectory(selected);
      expect(preferences.getString('cameraPhotoDirectory.test-os'), selected);
      expect(await Directory(selected).exists(), isFalse);
      final sameOs = create();
      final otherOs = create(os: 'other-os');
      await sameOs.initialize();
      await otherOs.initialize();
      expect(sameOs.state.value.photoDirectory, selected);
      expect(
        otherOs.state.value.photoDirectory,
        p.join(directory.path, 'KnownPictures', 'BShare'),
      );
      await sameOs.dispose();
      await otherOs.dispose();
      await expectLater(
        media.setVideoDirectory('relative-path'),
        throwsStateError,
      );
      expect(preferences.getString('cameraVideoDirectory.test-os'), isNull);
    },
  );

  test('photos use the received track and unique JPEG destinations', () async {
    await media.initialize();
    final first = await media.takePhoto();
    final second = await media.takePhoto();
    expect(p.extension(first), '.jpg');
    expect(p.dirname(first), media.state.value.photoDirectory);
    expect(second, isNot(first));
    final photos = calls
        .where((call) => call.method == 'desktopMediaTakePhoto')
        .toList();
    expect(photos, hasLength(2));
    expect(photos.first.arguments, {
      'path': first,
      'peerConnectionId': 'remote-peer',
      'videoTrackId': 'remote-video',
    });
    expect(media.state.value.lastSavedPath, second);
    expect(source.state.value.mode, ScreenShareMode.watching);
    expect(media.state.value.busy, isFalse);
  });

  test(
    'recording uses received audio, coalesces stop, and confirms save only after finalize',
    () async {
      await media.initialize();
      await Future.wait([media.startRecording(), media.startRecording()]);
      expect(
        calls.where((call) => call.method == 'desktopMediaStartRecording'),
        hasLength(1),
      );
      final start = calls.singleWhere(
        (call) => call.method == 'desktopMediaStartRecording',
      );
      expect(start.arguments['audioTrackId'], 'remote-audio');
      expect(start.arguments['peerConnectionId'], 'remote-peer');
      expect(p.extension(start.arguments['path'] as String), '.mp4');
      expect(media.state.value.recording, isTrue);
      expect(media.state.value.lastSavedPath, isNull);
      stopGate = Completer<void>();
      final stopping = media.stopRecording();
      expect(identical(media.stopRecording(), stopping), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(media.state.value.recording, isTrue);
      expect(media.state.value.busy, isTrue);
      expect(media.state.value.lastSavedPath, isNull);
      stopGate!.complete();
      expect(await stopping, recordingPath);
      expect(media.state.value.recording, isFalse);
      expect(media.state.value.lastSavedPath, recordingPath);
      expect(
        calls.where((call) => call.method == 'desktopMediaStopRecording'),
        hasLength(1),
      );
    },
  );

  test(
    'source metadata updates keep recording but a changed video track finalizes it',
    () async {
      await media.initialize();
      await media.startRecording();
      source.state.value = const ScreenShareState(
        mode: ScreenShareMode.watching,
        status: 'metadata changed',
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        calls.where((call) => call.method == 'desktopMediaStopRecording'),
        isEmpty,
      );
      input = const CameraMediaInput(
        peerConnectionId: 'remote-peer',
        videoTrackId: 'replacement-video',
      );
      source.state.value = const ScreenShareState(
        mode: ScreenShareMode.watching,
        status: 'new track',
      );
      await media.stopRecording();
      expect(
        calls.where((call) => call.method == 'desktopMediaStopRecording'),
        hasLength(1),
      );
      expect(media.state.value.recording, isFalse);
      expect(media.state.value.lastSavedPath, recordingPath);
    },
  );

  test(
    'dispose waits for an in-flight recorder start and finalizes its writer once',
    () async {
      await media.initialize();
      startGate = Completer<void>();
      final starting = media.startRecording();
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (!calls.any(
        (call) => call.method == 'desktopMediaStartRecording',
      )) {
        expect(
          DateTime.now().isBefore(deadline),
          isTrue,
          reason: 'Recorder start was not reached',
        );
        await Future<void>.delayed(Duration.zero);
      }
      final closing = media.dispose();
      startGate!.complete();
      await starting;
      await closing;
      expect(calls.map((call) => call.method), [
        'desktopMediaGetDirectories',
        'desktopMediaStartRecording',
        'desktopMediaStopRecording',
      ]);
      expect(identical(media.dispose(), closing), isTrue);
    },
  );

  test(
    'save failures clear busy and recording state and permit recovery',
    () async {
      await media.initialize();
      photoFails = true;
      await expectLater(media.takePhoto(), throwsA(isA<PlatformException>()));
      expect(media.state.value.error, 'mediaFailed');
      expect(media.state.value.busy, isFalse);
      expect(media.state.value.lastSavedPath, isNull);
      photoFails = false;
      await media.takePhoto();
      expect(media.state.value.error, isNull);
      await media.startRecording();
      stopFails = true;
      await expectLater(
        media.stopRecording(),
        throwsA(isA<PlatformException>()),
      );
      expect(media.state.value.recording, isFalse);
      expect(media.state.value.busy, isFalse);
      expect(media.state.value.error, 'mediaFailed');
      stopFails = false;
      await media.startRecording();
      await media.stopRecording();
      expect(media.state.value.error, isNull);
      expect(media.state.value.lastSavedPath, isNotNull);
    },
  );

  test('an unsupported backend never starts a local capture', () async {
    supported = false;
    await media.initialize();
    expect(media.state.value.ready, isFalse);
    await expectLater(media.takePhoto(), throwsStateError);
    await expectLater(media.startRecording(), throwsStateError);
    expect(calls.map((call) => call.method), ['desktopMediaGetDirectories']);
    expect(
      await Directory(media.state.value.photoDirectory!).exists(),
      isFalse,
    );
  });
}

extension on Completer<void> {
  void completeIfPending() {
    if (!isCompleted) complete();
  }
}
