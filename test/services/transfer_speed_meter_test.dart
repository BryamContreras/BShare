import 'package:bshare/src/infrastructure/services/transfer_speed_meter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses a recent moving window instead of lifetime transfer average', () {
    var nowMicros = 0;
    final meter = TransferSpeedMeter(
      window: const Duration(seconds: 1),
      nowMicros: () => nowMicros,
    );

    meter.record(0);
    nowMicros = Duration.microsecondsPerSecond;
    expect(meter.record(1024 * 1024), closeTo(1024 * 1024, 0.1));

    nowMicros = Duration.microsecondsPerSecond * 2;
    expect(meter.record(2 * 1024 * 1024), closeTo(1024 * 1024, 0.1));

    nowMicros = Duration.microsecondsPerSecond * 3;
    expect(meter.record(4 * 1024 * 1024), closeTo(2 * 1024 * 1024, 0.1));
  });
}
