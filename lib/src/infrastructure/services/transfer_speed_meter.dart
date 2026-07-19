import 'dart:collection';

/// Estimates transfer speed over a recent moving window instead of averaging
/// every byte since the transfer started.
class TransferSpeedMeter {
  TransferSpeedMeter({
    Duration window = const Duration(seconds: 2),
    this.nowMicros,
  }) : _windowMicros = window.inMicroseconds,
       _clock = Stopwatch()..start();

  static const _sampleInterval = Duration(milliseconds: 120);

  final int _windowMicros;
  final int Function()? nowMicros;
  final Stopwatch _clock;
  final Queue<_TransferSample> _samples = Queue();

  double record(int transferredBytes) {
    final now = nowMicros?.call() ?? _clock.elapsedMicroseconds;
    final sample = _TransferSample(now, transferredBytes);

    if (_samples.length >= 2 &&
        now - _samples.last.elapsedMicros < _sampleInterval.inMicroseconds) {
      _samples.removeLast();
    }
    _samples.addLast(sample);

    final cutoff = now - _windowMicros;
    while (_samples.length > 1 &&
        _samples.elementAt(1).elapsedMicros <= cutoff) {
      _samples.removeFirst();
    }

    final first = _samples.first;
    final elapsedMicros = now - first.elapsedMicros;
    if (elapsedMicros <= 0) return 0;
    return (transferredBytes - first.transferredBytes) *
        Duration.microsecondsPerSecond /
        elapsedMicros;
  }
}

class _TransferSample {
  const _TransferSample(this.elapsedMicros, this.transferredBytes);

  final int elapsedMicros;
  final int transferredBytes;
}
