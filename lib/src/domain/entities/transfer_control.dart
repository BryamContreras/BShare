import 'dart:async';

class TransferControl {
  bool _paused = false;
  bool _cancelled = false;
  Completer<void>? _resumeCompleter;

  bool get isPaused => _paused;
  bool get isCancelled => _cancelled;

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
    _cancelled = true;
    resume();
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
