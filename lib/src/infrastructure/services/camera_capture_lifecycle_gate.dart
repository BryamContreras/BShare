import 'dart:async';

import 'package:flutter/widgets.dart';

/// Android can return a camera permission result before Flutter receives the
/// activity's resumed event. Wait for that event without starting capture while
/// the activity is actually in the background.
class CameraCaptureLifecycleGate with WidgetsBindingObserver {
  CameraCaptureLifecycleGate({this.resumeTimeout = const Duration(seconds: 3)});

  final Duration resumeTimeout;
  Completer<void>? _pending;
  Timer? _timeout;
  bool _disposed = false;

  Future<void> waitForForeground() {
    if (_disposed) return Future.error(StateError('Video sharing is disposed'));
    final pending = _pending;
    if (pending != null) return pending.future;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == null || lifecycle == AppLifecycleState.resumed) {
      return Future.value();
    }
    if (lifecycle != AppLifecycleState.inactive) {
      return Future.error(_backgroundError());
    }

    final completer = Completer<void>();
    _pending = completer;
    WidgetsBinding.instance.addObserver(this);
    _timeout = Timer(resumeTimeout, () => _finish(_backgroundError()));
    // Recheck after subscribing so a resumed event cannot be missed.
    didChangeAppLifecycleState(WidgetsBinding.instance.lifecycleState!);
    return completer.future;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_pending == null) return;
    if (state == AppLifecycleState.resumed) {
      _finish();
    } else if (state != AppLifecycleState.inactive) {
      _finish(_backgroundError());
    }
  }

  void cancel() => _finish(StateError('Screen session ended'));

  void dispose() {
    _disposed = true;
    cancel();
  }

  void _finish([Object? error]) {
    final completer = _pending;
    if (completer == null) return;
    _pending = null;
    _timeout?.cancel();
    _timeout = null;
    WidgetsBinding.instance.removeObserver(this);
    if (error == null) {
      completer.complete();
    } else {
      completer.completeError(error);
    }
  }

  StateError _backgroundError() =>
      StateError('Open the app before starting camera capture');
}
