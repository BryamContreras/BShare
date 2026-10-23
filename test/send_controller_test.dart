import 'dart:async';
import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/app_settings.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/domain/entities/selected_transfer_file.dart';
import 'package:bshare/src/domain/entities/send_progress.dart';
import 'package:bshare/src/domain/entities/transfer_control.dart';
import 'package:bshare/src/domain/entities/transfer_progress_status.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/file_transfer_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestSettingsController extends SettingsController {
  @override
  Future<AppSettings> build() async => const AppSettings(
    deviceId: 'sender-id',
    deviceName: 'Sender',
    downloadDirectory: '/tmp',
    autoAccept: true,
    preferredPort: 53317,
    themeMode: 'dark',
    languageCode: 'en',
  );
}

class _ImmediateFileTransferClient extends FileTransferClient {
  _ImmediateFileTransferClient() : super(const AppLogger());

  @override
  Future<void> announceQueue({
    required DeviceInfo target,
    required List<SelectedTransferFile> files,
    required Map<String, String> transferIds,
    required String senderId,
    required String senderName,
    String? controlHost,
    int? controlPort,
  }) async {}

  @override
  Stream<SendProgress> sendFile({
    required DeviceInfo target,
    required SelectedTransferFile file,
    required String transferId,
    required String senderId,
    required String senderName,
    required TransferControl control,
    String? controlHost,
    int? controlPort,
  }) async* {
    yield SendProgress(
      id: file.path,
      fileName: file.name,
      sentBytes: 1,
      totalBytes: file.size,
      bytesPerSecond: 1,
      status: TransferProgressStatus.sending,
    );
  }
}

class _BlockingFileTransferClient extends _ImmediateFileTransferClient {
  int sendCount = 0;
  int announcedCount = 0;
  int? controlPort;
  final started = Completer<void>();
  bool finished = false;

  @override
  Future<void> announceQueue({
    required DeviceInfo target,
    required List<SelectedTransferFile> files,
    required Map<String, String> transferIds,
    required String senderId,
    required String senderName,
    String? controlHost,
    int? controlPort,
  }) async {
    announcedCount += files.length;
    this.controlPort = controlPort;
  }

  @override
  Stream<SendProgress> sendFile({
    required DeviceInfo target,
    required SelectedTransferFile file,
    required String transferId,
    required String senderId,
    required String senderName,
    required TransferControl control,
    String? controlHost,
    int? controlPort,
  }) async* {
    sendCount++;
    final cancelled = Completer<void>();
    final detach = control.onCancel(cancelled.complete);
    started.complete();
    try {
      yield SendProgress(
        id: file.path,
        fileName: file.name,
        sentBytes: 0,
        totalBytes: file.size,
        bytesPerSecond: 0,
        status: TransferProgressStatus.sending,
      );
      await cancelled.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    } finally {
      detach();
      finished = true;
    }
  }
}

void main() {
  test(
    'sending keeps selected and temporary files until explicitly removed',
    () async {
      final receiver = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final receiverSubscription = receiver.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
      });
      addTearDown(() async {
        await receiverSubscription.cancel();
        await receiver.close(force: true);
      });

      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'bshare-send-controller-',
      );
      final temporaryFile = File('${temporaryDirectory.path}/shared-file.bin');
      await temporaryFile.writeAsBytes(const [1, 2, 3, 4]);
      addTearDown(() async {
        if (await temporaryDirectory.exists()) {
          await temporaryDirectory.delete(recursive: true);
        }
      });

      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_TestSettingsController.new),
          fileTransferClientProvider.overrideWithValue(
            _ImmediateFileTransferClient(),
          ),
        ],
      );
      addTearDown(container.dispose);

      final selectedFile = SelectedTransferFile(
        path: temporaryFile.path,
        name: 'shared-file.bin',
        size: await temporaryFile.length(),
        deleteAfterSend: true,
      );
      container.read(pickedFilesProvider.notifier).set([selectedFile]);
      container
          .read(selectedDeviceProvider.notifier)
          .set(
            DeviceInfo(
              id: 'receiver-id',
              name: 'Receiver',
              platform: 'Test',
              ip: InternetAddress.loopbackIPv4.address,
              port: receiver.port,
              lastSeen: DateTime.now(),
            ),
          );

      final controller = container.read(sendControllerProvider);
      await controller.send();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(container.read(pickedFilesProvider), [selectedFile]);
      expect(await temporaryFile.exists(), isTrue);

      controller.removeFile(temporaryFile.path);
      for (var attempt = 0; attempt < 20; attempt++) {
        if (!await temporaryFile.exists()) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(container.read(pickedFilesProvider), isEmpty);
      expect(await temporaryFile.exists(), isFalse);
      await controller.dispose();
    },
  );
  test(
    'duplicates are sent once and dispose waits for the active sender to finish',
    () async {
      final receiver = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      receiver.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
      });
      addTearDown(() => receiver.close(force: true));
      final directory = await Directory.systemTemp.createTemp(
        'bshare-send-cleanup-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/shared.bin');
      await file.writeAsBytes([1, 2, 3]);
      final selected = SelectedTransferFile(
        path: file.path,
        name: 'shared.bin',
        size: 3,
        deleteAfterSend: true,
      );
      final client = _BlockingFileTransferClient();
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_TestSettingsController.new),
          fileTransferClientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);
      container.read(pickedFilesProvider.notifier).set([selected, selected]);
      container
          .read(selectedDeviceProvider.notifier)
          .set(
            DeviceInfo(
              id: 'receiver',
              name: 'Receiver',
              platform: 'test',
              ip: '127.0.0.1',
              port: receiver.port,
              lastSeen: DateTime.now(),
            ),
          );
      final controller = container.read(sendControllerProvider);
      await controller.send();
      await client.started.future;
      await controller.send();
      expect(client.sendCount, 1);
      expect(client.announcedCount, 1);
      expect(client.finished, isFalse);
      await controller.dispose(
        cleanupSelectedFiles: true,
        selectedFiles: [selected],
      );
      expect(client.finished, isTrue);
      expect(container.read(transferControlProvider), isEmpty);
      expect(await file.exists(), isFalse);
      expect(
        () => Socket.connect('127.0.0.1', client.controlPort!),
        throwsA(isA<SocketException>()),
      );
    },
  );
}
