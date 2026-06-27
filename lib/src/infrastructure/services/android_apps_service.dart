import 'dart:io';

import 'package:bshare/src/domain/entities/android_app_file.dart';
import 'package:flutter/services.dart';

class AndroidAppsService {
  static const _channel = MethodChannel('bshare/apps');

  Future<List<AndroidAppFile>> listInstalledApps() async {
    if (!Platform.isAndroid) return const [];
    final raw =
        await _channel.invokeListMethod<Map<dynamic, dynamic>>(
          'listInstalledApps',
        ) ??
        const [];
    return raw
        .map(
          (item) => AndroidAppFile(
            name: item['name'] as String,
            packageName: item['packageName'] as String,
            sourcePath: item['sourcePath'] as String,
            size: (item['size'] as num).toInt(),
            iconBase64: item['iconBase64'] as String? ?? '',
          ),
        )
        .toList();
  }
}
