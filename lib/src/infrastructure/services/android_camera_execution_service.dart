import 'dart:io';

import 'package:flutter/services.dart';

/// Camera capture uses its own foreground-service type, independently of
/// MediaProjection. Permission must be granted before starting this service.
class AndroidCameraExecutionService {
  static const _channel = MethodChannel('bshare/camera');

  Future<void> start() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('startForegroundService');
  }

  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('stopForegroundService');
  }

  /// Upgrade the existing camera foreground service only after RECORD_AUDIO
  /// permission and foreground lifecycle checks. Native acknowledgement precedes
  /// audio acquisition; disabling removes its microphone foreground-service type.
  Future<void> setMicrophoneActive(bool active) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('setMicrophoneActive', {
      'active': active,
    });
  }
}
