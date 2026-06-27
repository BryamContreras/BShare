import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/domain/entities/transfer_control.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/file_transfer_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAppLogger implements AppLogger {
  @override
  void error(String message, [Object? error]) {}

  @override
  void info(String message) {}

  @override
  void warn(String message) {}
}

void main() {
  group(FileTransferClient, () {
    test('sendFiles with empty list closes stream without hanging', () async {
      final client = FileTransferClient(_FakeAppLogger());
      final stream = client.sendFiles(
        target: DeviceInfo(
          id: 'test',
          name: 'Test',
          platform: 'Test',
          ip: '127.0.0.1',
          port: 53317,
          lastSeen: DateTime.now(),
        ),
        files: const [],
        senderId: 'sender',
        senderName: 'Sender',
        controls: const {},
      );

      final events = <dynamic>[];
      final subscription = stream.listen(events.add, onDone: () {});

      await Future<void>.delayed(const Duration(milliseconds: 200));
      await subscription.cancel();

      expect(events, isEmpty);
    });

    test('sendFiles with empty list completes within timeout', () async {
      final client = FileTransferClient(_FakeAppLogger());
      final stream = client.sendFiles(
        target: DeviceInfo(
          id: 'test',
          name: 'Test',
          platform: 'Test',
          ip: '127.0.0.1',
          port: 53317,
          lastSeen: DateTime.now(),
        ),
        files: const [],
        senderId: 'sender',
        senderName: 'Sender',
        controls: const {},
      );

      var completed = false;
      stream.listen((_) {}, onDone: () => completed = true);

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(completed, isTrue);
    });
  });

  group(TransferControl, () {
    test('cancel sets isCancelled to true', () {
      final control = TransferControl();
      expect(control.isCancelled, isFalse);
      control.cancel();
      expect(control.isCancelled, isTrue);
    });

    test('cancel also resumes paused state', () {
      final control = TransferControl();
      control.pause();
      expect(control.isPaused, isTrue);
      control.cancel();
      expect(control.isCancelled, isTrue);
      expect(control.isPaused, isFalse);
    });

    test('waitIfPaused throws TransferCancelledException when cancelled', () {
      final control = TransferControl()..cancel();
      expect(
        () => control.waitIfPaused(),
        throwsA(isA<TransferCancelledException>()),
      );
    });

    test('pause does not affect isCancelled', () {
      final control = TransferControl();
      expect(control.isPaused, isFalse);
      control.pause();
      expect(control.isPaused, isTrue);
      expect(control.isCancelled, isFalse);
    });

    test('resume clears paused state', () async {
      final control = TransferControl()..pause();
      expect(control.isPaused, isTrue);

      final waitFuture = control.waitIfPaused();
      control.resume();
      expect(control.isPaused, isFalse);

      await waitFuture;
      expect(control.isPaused, isFalse);
    });
  });
}
