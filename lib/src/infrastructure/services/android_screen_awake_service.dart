import 'dart:io';

import 'package:flutter/services.dart';

/// Prevents Android from dimming or locking the active activity while a
/// screen is being shared or viewed.
class AndroidScreenAwakeService {
  static const _channel = MethodChannel('bshare/screen');

  Future<void> setKeepScreenOn(bool enabled) async {
    if (!Platform.isAndroid) return;

    try {
      await _channel.invokeMethod<void>('setKeepScreenOn', <String, bool>{
        'enabled': enabled,
      });
    } on PlatformException {
      // The viewer remains usable if this optional Android behavior fails.
    } on MissingPluginException {
      // Allows older Android builds to keep using the viewer normally.
    }
  }

  Future<void> setViewerActive(bool active) => setKeepScreenOn(active);
}
