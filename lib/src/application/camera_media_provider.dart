import 'dart:async';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/infrastructure/services/camera_media_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final cameraMediaServiceProvider = Provider((ref) {
  final source = ref.watch(screenShareServiceProvider);
  final media = CameraMediaService(source: source);
  Future<void> beforeDetach() async {
    await media.stopRecording();
  }

  source.beforeRemoteMediaDetach = beforeDetach;
  ref.onDispose(() {
    // Retain the hook until finalization finishes. The source provider can be
    // disposed in the same turn and must still await its writer before closing
    // the peer and releasing the decoded tracks.
    unawaited(
      media.dispose().whenComplete(() {
        if (identical(source.beforeRemoteMediaDetach, beforeDetach)) {
          source.beforeRemoteMediaDetach = null;
        }
      }),
    );
  });
  unawaited(media.initialize());
  return media;
});
