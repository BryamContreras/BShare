import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Owns the awake/brightness state for an active camera session. The screen
/// stays unlocked while its preview dims after a minute without interaction.
class CameraDisplayService {
  CameraDisplayService({
    this.dimAfter = const Duration(minutes: 1),
    Future<void> Function(bool awake, bool dimmed)? applyState,
  }) : _applyState = applyState ?? _applyPlatformState;

  static const _channel = MethodChannel('bshare/camera');
  final Duration dimAfter;
  final Future<void> Function(bool awake, bool dimmed) _applyState;
  final ValueNotifier<bool> dimmed = ValueNotifier(false);
  bool get active => _active;
  bool _active = false;
  bool _disposed = false;
  bool _restoreNeeded = false;
  Timer? _timer;
  Future<void> _updates = Future.value();
  Future<void>? _disposing;
  Future<void>? _stopping;

  static Future<void> _applyPlatformState(bool awake, bool dimmed) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    await _channel.invokeMethod<void>('setDisplayState', {
      'awake': awake,
      'dimmed': dimmed,
    });
  }

  Future<void> _apply() {
    final awake = _active;
    final dark = dimmed.value;
    final update = _updates.then((_) => _applyState(awake, dark));
    // A failed platform request must not poison subsequent cleanup.
    _updates = update.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return update;
  }

  Future<void> start() async {
    if (_disposed) throw StateError('Camera display is disposed');
    await _stopping;
    if (_disposed) throw StateError('Camera display is disposed');
    _active = true;
    _restoreNeeded = true;
    dimmed.value = false;
    _arm();
    try {
      await _apply();
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  Future<void> wakeDisplay() async {
    if (_disposed || !_active) return;
    _arm();
    if (!dimmed.value) return;
    dimmed.value = false;
    await _apply();
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer(dimAfter, () {
      _timer = null;
      if (_disposed || !_active) return;
      dimmed.value = true;
      // A brightness failure must still allow the UI's black overlay to dim.
      unawaited(_apply().catchError((Object _) {}));
    });
  }

  Future<void> stop() {
    if (_stopping != null) return _stopping!;
    _timer?.cancel();
    _timer = null;
    if (_disposed) return _disposing ?? Future.value();
    _active = false;
    dimmed.value = false;
    if (!_restoreNeeded) return _updates;
    return _stopping = _restore().whenComplete(() => _stopping = null);
  }

  Future<void> _restore() async {
    await _apply();
    _restoreNeeded = false;
  }

  Future<void> dispose() => _disposing ??= _dispose();

  Future<void> _dispose() async {
    _timer?.cancel();
    _timer = null;
    _active = false;
    dimmed.value = false;
    _disposed = true;
    try {
      try {
        await _stopping;
      } catch (_) {}
      if (_restoreNeeded) await _restore();
      await _updates;
    } finally {
      dimmed.dispose();
    }
  }
}
