import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bshare/src/infrastructure/services/process_runner.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

enum VirtualCameraAvailability {
  checking,
  available,
  unsupported,
  notInstalled,
  unavailable,
}

/// Reports the installed system camera. Publishing belongs to the native
/// receiver, so it continues when Flutter is minimized or not painting video.
class VirtualCameraService {
  VirtualCameraService({
    bool? isWindows,
    bool? isLinux,
    Future<Map<String, dynamic>> Function()? query,
  }) : _isWindows = isWindows ?? Platform.isWindows,
       _isLinux = isLinux ?? Platform.isLinux,
       _query = query ?? _queryInstalledCamera;

  final bool _isWindows;
  final bool _isLinux;
  final Future<Map<String, dynamic>> Function() _query;
  final ValueNotifier<VirtualCameraAvailability> availability = ValueNotifier(
    VirtualCameraAvailability.checking,
  );
  Future<void>? _refreshing;
  bool _disposed = false;

  Future<void> refresh() {
    if (_disposed) return Future.value();
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<void> _refresh() async {
    if (!_isWindows && !_isLinux) {
      availability.value = VirtualCameraAvailability.unsupported;
      return;
    }
    var result = VirtualCameraAvailability.unavailable;
    try {
      final status = await _query();
      if (status['supported'] == false) {
        result = VirtualCameraAvailability.unsupported;
      } else if (status['installationFailed'] == true) {
        result = VirtualCameraAvailability.unavailable;
      } else if (status['supported'] == true && status['registered'] is bool) {
        result = status['registered'] == true
            ? VirtualCameraAvailability.available
            : VirtualCameraAvailability.notInstalled;
      }
    } on FileSystemException {
      result = VirtualCameraAvailability.notInstalled;
    } on ProcessException {
      result = VirtualCameraAvailability.notInstalled;
    } catch (_) {
      // A missing or damaged optional camera component must not break viewing.
    }
    if (!_disposed) availability.value = result;
  }

  static Future<Map<String, dynamic>> _queryInstalledCamera() async {
    final helper = p.join(
      p.dirname(Platform.resolvedExecutable),
      Platform.isWindows ? 'bshare-camera.exe' : 'bshare-camera',
    );
    if (!await File(helper).exists()) {
      throw FileSystemException('Camera helper');
    }
    Future<Map<String, dynamic>> status() async {
      final result = await const ProcessRunner().run(
        helper,
        const ['--status'],
        timeout: const Duration(seconds: 10),
      );
      if (result.exitCode != 0) throw StateError('Camera status unavailable');
      return Map<String, dynamic>.from(jsonDecode(result.stdout as String) as Map);
    }

    final current = await status();
    if (current['supported'] == true &&
        current['sourceRegistered'] == true &&
        current['registered'] == false) {
      // The separate installer has already registered the trusted source. Add
      // this user's persistent device without elevation or physical capture.
      // This also works when an administrator installed using another account.
      final installed = await const ProcessRunner().run(
        helper,
        const ['--install'],
        timeout: const Duration(seconds: 10),
      );
      if (installed.exitCode != 0) {
        return {...current, 'installationFailed': true};
      }
      return status();
    }
    return current;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    availability.dispose();
  }
}
