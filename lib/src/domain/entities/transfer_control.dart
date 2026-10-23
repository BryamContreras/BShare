import 'dart:async';

class TransferControl {
  bool _paused = false;
  bool _cancelled = false;
  Completer<void>? _resumeCompleter;
  final Set<void Function()> _cancelListeners = {};

  bool get isPaused => _paused;
  bool get isCancelled => _cancelled;

  /// Returns a function that detaches the listener after its operation finishes.
  void Function() onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _cancelListeners.add(listener);
    return () => _cancelListeners.remove(listener);
  }

  void pause() {
    if (_cancelled || _paused) return;
    _paused = true;
    _resumeCompleter = Completer<void>();
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    _resumeCompleter?.complete();
    _resumeCompleter = null;
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    resume();
    final listeners = _cancelListeners.toList();
    _cancelListeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  Future<void> waitIfPaused() async {
    final completer = _resumeCompleter;
    if (_paused && completer != null) {
      await completer.future;
    }
    if (_cancelled) {
      throw const TransferCancelledException();
    }
  }
}

class TransferCancelledException implements Exception {
  const TransferCancelledException();

  @override
  String toString() => 'Transfer cancelled';
}
