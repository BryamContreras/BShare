import 'dart:async';
import 'dart:io';

import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/domain/entities/transfer_control.dart';
import 'package:bshare/src/domain/entities/selected_transfer_file.dart';
import 'package:bshare/src/domain/entities/transfer_progress_status.dart';
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

  group('transfer cleanup', () {
    late Directory directory;
    late FileTransferClient client;
    HttpServer? receiver;

    DeviceInfo target(int port) => DeviceInfo(
      id: 'receiver',
      name: 'Receiver',
      platform: 'test',
      ip: '127.0.0.1',
      port: port,
      lastSeen: DateTime.now(),
    );

    Future<SelectedTransferFile> createFile() async {
      final file = File('${directory.path}/source.bin');
      await file.writeAsBytes(List.filled(64 * 1024, 42));
      return SelectedTransferFile(
        path: file.path,
        name: 'source.bin',
        size: await file.length(),
      );
    }

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('bshare-client-test-');
      client = FileTransferClient(_FakeAppLogger());
    });
    tearDown(() async {
      client.dispose();
      await receiver?.close(force: true);
      receiver = null;
      await directory.delete(recursive: true);
    });

    test(
      'missing source reports failure and closes its progress stream',
      () async {
        final file = SelectedTransferFile(
          path: '${directory.path}/missing',
          name: 'missing',
          size: 5,
        );
        final events = await client
            .sendFile(
              target: target(1),
              file: file,
              transferId: 'missing',
              senderId: 'sender',
              senderName: 'Sender',
              control: TransferControl(),
            )
            .toList()
            .timeout(const Duration(seconds: 2));
        expect(events, hasLength(1));
        expect(events.single.status, TransferProgressStatus.failed);
      },
    );

    test(
      'cancel interrupts a sender waiting for receiver acknowledgement',
      () async {
        receiver = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final received = Completer<void>();
        receiver!.listen((request) async {
          await request.drain<void>();
          received.complete();
          // Intentionally withhold acknowledgement until the server is closed.
        });
        final control = TransferControl();
        final events = client
            .sendFile(
              target: target(receiver!.port),
              file: await createFile(),
              transferId: 'cancel-wait',
              senderId: 'sender',
              senderName: 'Sender',
              control: control,
            )
            .toList();
        await received.future.timeout(const Duration(seconds: 3));
        control.cancel();
        final result = await events.timeout(const Duration(seconds: 2));
        expect(result.last.status, TransferProgressStatus.cancelled);
      },
    );

    test(
      'dispose interrupts active HTTP requests and closes streams',
      () async {
        receiver = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final received = Completer<void>();
        receiver!.listen((request) async {
          await request.drain<void>();
          received.complete();
        });
        final events = client
            .sendFile(
              target: target(receiver!.port),
              file: await createFile(),
              transferId: 'dispose-wait',
              senderId: 'sender',
              senderName: 'Sender',
              control: TransferControl(),
            )
            .toList();
        await received.future.timeout(const Duration(seconds: 3));
        client.dispose();
        expect(
          (await events.timeout(const Duration(seconds: 2))).last.status,
          TransferProgressStatus.cancelled,
        );
      },
    );

    test('cancelled stream also cancels its transfer control', () async {
      final control = TransferControl()..pause();
      final subscription = client
          .sendFile(
            target: target(1),
            file: await createFile(),
            transferId: 'cancel-subscription',
            senderId: 'sender',
            senderName: 'Sender',
            control: control,
          )
          .listen((_) {});
      await subscription.cancel();
      expect(control.isCancelled, isTrue);
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
