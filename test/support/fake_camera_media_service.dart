import 'dart:async';

import 'package:bshare/src/domain/entities/camera_media_state.dart';
import 'package:bshare/src/infrastructure/services/camera_media_service.dart';

class FakeCameraMediaService extends CameraMediaService {
  FakeCameraMediaService({required super.source}) {
    state.value = const CameraMediaState(
      supported: true,
      ready: true,
      photoDirectory: '/Pictures/BShare',
      videoDirectory: '/Videos/BShare',
    );
  }

  int photos = 0;
  int starts = 0;
  int stops = 0;
  Completer<void>? action;
  bool fail = false;

  @override
  Future<void> initialize() async {}

  @override
  Future<String> takePhoto() async {
    photos++;
    state.value = state.value.copyWith(
      busy: true,
      clearError: true,
      clearSavedPath: true,
    );
    try {
      await action?.future;
      if (fail) throw StateError('private media failure');
      state.value = state.value.copyWith(
        lastSavedPath: '/Pictures/BShare/photo-$photos.jpg',
      );
      return state.value.lastSavedPath!;
    } finally {
      state.value = state.value.copyWith(busy: false);
    }
  }

  @override
  Future<void> startRecording() async {
    starts++;
    state.value = state.value.copyWith(busy: true, clearSavedPath: true);
    try {
      await action?.future;
      state.value = state.value.copyWith(recording: true);
    } finally {
      state.value = state.value.copyWith(busy: false);
    }
  }

  @override
  Future<String?> stopRecording() async {
    stops++;
    state.value = state.value.copyWith(
      recording: false,
      lastSavedPath: '/Videos/BShare/video.mp4',
    );
    return state.value.lastSavedPath;
  }
}
