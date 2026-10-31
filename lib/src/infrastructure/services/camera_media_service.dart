import 'dart:async';
import 'dart:io';

import 'package:bshare/src/domain/entities/camera_media_state.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
// The native track exposes its owning peer ID through this implementation.
// ignore: implementation_imports
import 'package:flutter_webrtc/src/native/media_stream_track_impl.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

typedef CameraMediaNativeInvoke =
    Future<dynamic> Function(String method, Map<String, dynamic> arguments);

class CameraMediaInput {
  const CameraMediaInput({
    required this.peerConnectionId,
    required this.videoTrackId,
    this.audioTrackId,
  });
  final String peerConnectionId;
  final String videoTrackId;
  final String? audioTrackId;
  (String, String) get videoIdentity => (peerConnectionId, videoTrackId);
}

/// Saves decoded remote camera media on this computer. It never opens a local
/// camera/microphone or sends a capture command to the phone.
class CameraMediaService {
  CameraMediaService({
    required this.source,
    CameraMediaNativeInvoke? nativeInvoke,
    Future<SharedPreferences> Function()? preferences,
    CameraMediaInput? Function()? readInput,
    String? operatingSystem,
    this.logger = const AppLogger(),
  }) : _nativeInvoke = nativeInvoke ?? WebRTC.invokeMethod<dynamic, dynamic>,
       _preferences = preferences ?? SharedPreferences.getInstance,
       _readInputOverride = readInput,
       _operatingSystem = operatingSystem ?? Platform.operatingSystem {
    source.state.addListener(_sourceChanged);
    source.remoteRenderer.addListener(_sourceChanged);
  }

  final ScreenShareService source;
  final CameraMediaNativeInvoke _nativeInvoke;
  final Future<SharedPreferences> Function() _preferences;
  final CameraMediaInput? Function()? _readInputOverride;
  final String _operatingSystem;
  final AppLogger logger;
  final state = ValueNotifier<CameraMediaState>(
    const CameraMediaState(busy: true),
  );
  SharedPreferences? _prefs;
  Future<void>? _initializing;
  Future<void> _operations = Future.value();
  Future<void>? _disposing;
  Future<String?>? _stoppingRecording;
  bool _initialized = false;
  bool _disposed = false;
  String? _recorderId;
  CameraMediaInput? _recordingInput;
  final _recordingClock = Stopwatch();
  Timer? _durationTimer;

  String get _photoKey => 'cameraPhotoDirectory.$_operatingSystem';
  String get _videoKey => 'cameraVideoDirectory.$_operatingSystem';

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    try {
      try {
        _prefs = await _preferences();
      } catch (error) {
        logger.warn(
          'Camera media preferences unavailable: ${error.runtimeType}',
        );
      }
      final result = await _nativeInvoke('desktopMediaGetDirectories', {});
      final directories = result is Map ? result : const {};
      String? directory(String preference, String nativeKey) {
        final saved = _prefs?.getString(preference);
        if (saved != null && p.isAbsolute(saved)) return p.normalize(saved);
        final known = directories[nativeKey];
        return known is String && p.isAbsolute(known)
            ? p.join(known, 'BShare')
            : null;
      }

      final photos = directory(_photoKey, 'pictures');
      final videos = directory(_videoKey, 'videos');
      _initialized = true;
      if (_disposed) return;
      final supported =
          directories['supported'] == true && photos != null && videos != null;
      state.value = CameraMediaState(
        supported: supported,
        ready: supported && _input() != null,
        photoDirectory: photos,
        videoDirectory: videos,
      );
    } catch (error) {
      _initialized = true;
      logger.warn(
        'Camera media initialization unavailable: ${error.runtimeType}',
      );
      if (!_disposed) state.value = const CameraMediaState();
    }
  }

  CameraMediaInput? _input() {
    if (_readInputOverride case final read?) return read();
    final connection = source.state.value;
    if (source.source != VideoShareSource.camera ||
        connection.mode != ScreenShareMode.watching ||
        connection.error != null ||
        connection.awaitingVideo) {
      return null;
    }
    final video = source.remoteVideoTrack;
    if (video is! MediaStreamTrackNative || video.kind != 'video') return null;
    final audio = source.remoteAudioTrack;
    return CameraMediaInput(
      peerConnectionId: video.peerConnectionId,
      videoTrackId: video.id,
      audioTrackId: audio?.id,
    );
  }

  void _sourceChanged() {
    if (_disposed || _disposing != null) return;
    final input = _input();
    if (_initialized) {
      final ready = state.value.supported && input != null;
      if (ready != state.value.ready) {
        state.value = state.value.copyWith(ready: ready);
      }
    }
    if (_recordingInput != null &&
        input?.videoIdentity != _recordingInput!.videoIdentity) {
      unawaited(stopRecording().catchError((Object error) => null));
    }
  }

  Future<void> setPhotoDirectory(String path) =>
      _setDirectory(path, photo: true);
  Future<void> setVideoDirectory(String path) =>
      _setDirectory(path, photo: false);

  Future<void> _setDirectory(String path, {required bool photo}) =>
      _serialize(() async {
        await initialize();
        _checkOpen();
        if (!p.isAbsolute(path) ||
            path.trim().isEmpty ||
            (!photo && state.value.recording)) {
          throw StateError('Invalid camera media directory');
        }
        state.value = state.value.copyWith(busy: true, clearError: true);
        try {
          final normalized = p.normalize(path);
          if (_prefs == null) {
            throw StateError('Camera media preferences unavailable');
          }
          final stored = await _prefs!.setString(
            photo ? _photoKey : _videoKey,
            normalized,
          );
          if (stored == false) {
            throw StateError('Camera media preference was not stored');
          }
          state.value = state.value.copyWith(
            photoDirectory: photo ? normalized : null,
            videoDirectory: photo ? null : normalized,
          );
        } catch (error) {
          state.value = state.value.copyWith(error: 'folderFailed');
          rethrow;
        } finally {
          state.value = state.value.copyWith(busy: false);
        }
      });

  void _checkOpen() {
    if (_disposed || _disposing != null) {
      throw StateError('Camera media service is closing');
    }
  }

  CameraMediaInput _requireInput() {
    _checkOpen();
    final input = _input();
    if (!state.value.supported || input == null) {
      throw StateError('Remote camera media is not available');
    }
    return input;
  }

  Future<String> _destination(String directory, String extension) async {
    await Directory(directory).create(recursive: true);
    final stamp = DateTime.now().toIso8601String().replaceAll(
      RegExp(r'[^0-9]'),
      '',
    );
    return p.join(directory, 'BShare_${stamp}_${const Uuid().v4()}.$extension');
  }

  Map<String, dynamic> _arguments(CameraMediaInput input, String path) => {
    'path': path,
    'peerConnectionId': input.peerConnectionId,
    'videoTrackId': input.videoTrackId,
  };

  String _savedPath(dynamic result) {
    final path = result is Map ? result['path'] : null;
    if (path is! String || !p.isAbsolute(path)) {
      throw const FormatException('Camera media path missing');
    }
    return path;
  }

  Future<String> takePhoto() => _serialize(() async {
    await initialize();
    _checkOpen();
    state.value = state.value.copyWith(
      busy: true,
      clearError: true,
      clearSavedPath: true,
    );
    try {
      final input = _requireInput();
      final path = await _destination(state.value.photoDirectory!, 'jpg');
      final result = await _nativeInvoke(
        'desktopMediaTakePhoto',
        _arguments(input, path),
      );
      final saved = _savedPath(result);
      state.value = state.value.copyWith(lastSavedPath: saved);
      return saved;
    } catch (error) {
      state.value = state.value.copyWith(error: 'mediaFailed');
      rethrow;
    } finally {
      state.value = state.value.copyWith(busy: false);
    }
  });

  Future<void> startRecording() => _serialize(() async {
    await initialize();
    _checkOpen();
    if (_recorderId != null) return;
    state.value = state.value.copyWith(
      busy: true,
      clearError: true,
      clearSavedPath: true,
    );
    try {
      final input = _requireInput();
      final path = await _destination(state.value.videoDirectory!, 'mp4');
      final result = await _nativeInvoke('desktopMediaStartRecording', {
        ..._arguments(input, path),
        if (input.audioTrackId != null) 'audioTrackId': input.audioTrackId,
      });
      final id = result is Map ? result['recorderId'] : null;
      if (id is! String || id.isEmpty) {
        throw const FormatException('Camera recorder ID missing');
      }
      _recorderId = id;
      _recordingInput = input;
      _recordingClock
        ..reset()
        ..start();
      state.value = state.value.copyWith(
        recording: true,
        elapsed: Duration.zero,
      );
      _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!_disposed && _recorderId != null) {
          state.value = state.value.copyWith(elapsed: _recordingClock.elapsed);
        }
      });
      // A source can disappear while the native writer is being created.
      if (_input()?.videoIdentity != input.videoIdentity) {
        unawaited(stopRecording().catchError((Object error) => null));
      }
    } catch (error) {
      state.value = state.value.copyWith(error: 'mediaFailed');
      rethrow;
    } finally {
      state.value = state.value.copyWith(busy: false);
    }
  });

  Future<String?> stopRecording() => _stoppingRecording ??= _serialize(
    _stopRecording,
  ).whenComplete(() => _stoppingRecording = null);

  Future<String?> _stopRecording() async {
    final id = _recorderId;
    if (id == null || _disposed) return null;
    _durationTimer?.cancel();
    _durationTimer = null;
    _recordingClock.stop();
    state.value = state.value.copyWith(
      busy: true,
      elapsed: _recordingClock.elapsed,
      clearError: true,
    );
    try {
      final result = await _nativeInvoke('desktopMediaStopRecording', {
        'recorderId': id,
      });
      final saved = _savedPath(result);
      state.value = state.value.copyWith(lastSavedPath: saved);
      return saved;
    } catch (error) {
      state.value = state.value.copyWith(error: 'mediaFailed');
      rethrow;
    } finally {
      _recorderId = null;
      _recordingInput = null;
      state.value = state.value.copyWith(busy: false, recording: false);
    }
  }

  Future<void> dispose() {
    if (_disposing case final pending?) return pending;
    source.state.removeListener(_sourceChanged);
    source.remoteRenderer.removeListener(_sourceChanged);
    return _disposing = _serialize(() async {
      try {
        await _stopRecording();
      } catch (error) {
        logger.warn(
          'Camera recording finalization failed: ${error.runtimeType}',
        );
      } finally {
        _durationTimer?.cancel();
        _disposed = true;
        state.dispose();
      }
    });
  }
}
