import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// The OS version is immutable for this process. Permission grants are not;
/// callers must continue checking them whenever a protected action is started.
class AndroidPlatformInfoService {
  AndroidPlatformInfoService({
    Future<int> Function()? readSdkInt,
    bool? isAndroid,
  }) : _readSdkInt = readSdkInt ?? _readNativeSdkInt,
       isAndroid = isAndroid ?? Platform.isAndroid;

  static final instance = AndroidPlatformInfoService();
  static const _channel = MethodChannel('bshare/device');

  final bool isAndroid;
  final Future<int> Function() _readSdkInt;
  Future<int>? _sdkInt;

  Future<int> sdkInt() {
    if (!isAndroid) {
      return Future.error(
        UnsupportedError('Android OS version is unavailable'),
      );
    }
    return _sdkInt ??= Future.sync(_readSdkInt)
        .then((value) {
          if (value < 1) throw StateError('Invalid Android OS version');
          return value;
        })
        .catchError((Object error, StackTrace stack) {
          // A transient channel failure must not permanently block this process.
          _sdkInt = null;
          Error.throwWithStackTrace(error, stack);
        });
  }

  static Future<int> _readNativeSdkInt() async {
    final value = await _channel.invokeMethod<int>('getAndroidSdkInt');
    if (value == null) throw StateError('Android OS version was not returned');
    return value;
  }
}
