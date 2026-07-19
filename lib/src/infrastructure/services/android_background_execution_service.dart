import 'dart:async';
import 'dart:io';

import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:flutter_background/flutter_background.dart';

enum BackgroundExecutionOwner { fileSending, fileReceiving, screenSharing }

/// Shares the single Android foreground service required by long-running LAN
/// work. Each owner keeps the service alive until it releases its claim.
class AndroidBackgroundExecutionService {
  AndroidBackgroundExecutionService(this._logger);

  static const _androidConfig = FlutterBackgroundAndroidConfig(
    notificationTitle: 'BShare is active',
    notificationText: 'BShare is transferring data on your local network.',
    notificationImportance: AndroidNotificationImportance.normal,
    notificationIcon: AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
    enableWifiLock: true,
    shouldRequestBatteryOptimizationsOff: false,
  );

  final AppLogger _logger;
  final Set<BackgroundExecutionOwner> _owners = {};
  Future<void> _pendingOperation = Future.value();
  var _startedByBShare = false;

  Future<bool> acquire(BackgroundExecutionOwner owner) {
    return _synchronized(() async {
      if (!Platform.isAndroid) return true;

      _owners.add(owner);
      if (FlutterBackground.isBackgroundExecutionEnabled) return true;

      try {
        final initialized = await FlutterBackground.initialize(
          androidConfig: _androidConfig,
        );
        if (!initialized) {
          _owners.remove(owner);
          return false;
        }

        final enabled = await FlutterBackground.enableBackgroundExecution();
        if (!enabled) {
          _owners.remove(owner);
          return false;
        }
        _startedByBShare = true;
        return true;
      } catch (error) {
        _owners.remove(owner);
        _logger.warn(
          'Could not start Android foreground execution for ${owner.name}: '
          '$error',
        );
        return false;
      }
    });
  }

  Future<void> release(BackgroundExecutionOwner owner) {
    return _synchronized(() async {
      _owners.remove(owner);
      await _disableIfUnused();
    });
  }

  Future<void> dispose() {
    return _synchronized(() async {
      _owners.clear();
      await _disableIfUnused();
    });
  }

  Future<void> _disableIfUnused() async {
    if (!Platform.isAndroid || _owners.isNotEmpty || !_startedByBShare) return;

    try {
      if (FlutterBackground.isBackgroundExecutionEnabled) {
        await FlutterBackground.disableBackgroundExecution();
      }
    } catch (error) {
      _logger.warn('Could not stop Android foreground execution: $error');
    } finally {
      _startedByBShare = false;
    }
  }

  Future<T> _synchronized<T>(Future<T> Function() operation) {
    final next = _pendingOperation.then(
      (_) => operation(),
      onError: (_) => operation(),
    );
    _pendingOperation = next.then<void>((_) {}, onError: (_) {});
    return next;
  }
}
