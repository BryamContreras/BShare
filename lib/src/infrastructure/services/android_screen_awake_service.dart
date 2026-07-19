import 'dart:io';

import 'package:flutter/services.dart';

/// Prevents Android from dimming or locking the active activity while a
/// full-screen remote screen is being viewed.
class AndroidScreenAwakeService {
  static const _channel = MethodChannel('bshare/screen');

  Future<void> setViewerActive(bool active) async {
    if (!Platform.isAndroid) return;

    try {
      await _channel.invokeMethod<void>('setKeepScreenOn', <String, bool>{
        'enabled': active,
      });
    } on PlatformException {
      // The viewer remains usable if this optional Android behavior fails.
    } on MissingPluginException {
      // Allows older Android builds to keep using the viewer normally.
    }
  }
}
