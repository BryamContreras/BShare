import 'dart:io';

import 'package:flutter/services.dart';

/// Runs the Android foreground service required while this device captures its
/// screen. It is separate from data transfers because Android 14+ validates
/// the mediaProjection service type against an active capture consent.
class AndroidScreenShareExecutionService {
  static const _channel = MethodChannel('bshare/screen_share');

  Future<void> start() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('startForegroundService');
  }

  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('stopForegroundService');
  }
}
