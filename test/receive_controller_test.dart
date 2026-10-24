import 'dart:async';
import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/app_settings.dart';
import 'package:bshare/src/domain/entities/incoming_transfer.dart';
import 'package:bshare/src/domain/entities/transfer_progress_status.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/android_background_execution_service.dart';
import 'package:bshare/src/infrastructure/services/android_storage_access_service.dart';
import 'package:bshare/src/infrastructure/services/file_server.dart';
import 'package:bshare/src/infrastructure/services/network_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Settings extends SettingsController {
  _Settings(this.directory);
  final String directory;

  void setDirectory(String path) {
    state = AsyncData(state.requireValue.copyWith(downloadDirectory: path));
  }

  @override
  Future<AppSettings> build() async => AppSettings(
    deviceId: 'receiver',
    deviceName: 'Receiver',
    downloadDirectory: directory,
    autoAccept: true,
    preferredPort: 53317,
    themeMode: 'dark',
    languageCode: 'en',
  );
}

class _Storage extends AndroidStorageAccessService {
  bool granted = true;
  final pathGrants = <String, bool>{};
  final requests = <String>[];
  final checks = <String>[];
  Completer<bool>? checkGate;

  @override
  Future<bool> requestAccess(String path) async {
    requests.add(path);
    return pathGrants[path] ?? granted;
  }

  @override
  Future<bool> hasAccess(String path) async {
    checks.add(path);
    return await checkGate?.future ?? pathGrants[path] ?? granted;
  }
}

class _Execution extends AndroidBackgroundExecutionService {
  _Execution() : super(const AppLogger());
  final acquisitions = <BackgroundExecutionOwner>[];
  final releases = <BackgroundExecutionOwner>[];

  @override
  Future<bool> acquire(BackgroundExecutionOwner owner) async {
    acquisitions.add(owner);
    return true;
  }

  @override
  Future<void> release(BackgroundExecutionOwner owner) async {
    releases.add(owner);
  }
}

class _Discovery extends DiscoveryController {
  final stopping = Completer<void>();
  Completer<void>? stopGate;
  int stops = 0;
  @override
  Future<void> start({bool advertise = false, String? ipOverride}) async {}
  @override
  Future<void> stop() async {
    stops++;
    if (!stopping.isCompleted) stopping.complete();
    await stopGate?.future;
  }
}

class _Server extends FileServer {
  _Server() : super(const AppLogger());
  final started = Completer<void>();
  Completer<void>? startGate;
  ReceiveQueueHandler? onQueue;
  int starts = 0;
  int stops = 0;
  final destinations = <String>[];
  final updates = <String>[];

  @override
  void updateReceiverSettings({
    required String downloadDirectory,
    required bool autoAccept,
  }) {
    updates.add(downloadDirectory);
    super.updateReceiverSettings(
      downloadDirectory: downloadDirectory,
      autoAccept: autoAccept,
    );
  }

  @override
  Future<int> start({
    required int preferredPort,
    required String downloadDirectory,
    required bool autoAccept,
    required IncomingTransferHandler onIncoming,
    required TransferSavedHandler onSaved,
    required ReceiveProgressHandler onProgress,
    required ReceiveQueueHandler onQueue,
    required ReceiveControlResolver resolveControl,
  }) async {
    starts++;
    destinations.add(downloadDirectory);
    this.onQueue = onQueue;
    if (!started.isCompleted) started.complete();
    await startGate?.future;
    return 53317;
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}

void main() {
  late _Server server;
  late ProviderContainer container;
  late _Storage storage;
  late _Execution execution;
  late _Discovery discovery;
  late String directory;
  setUp(() {
    server = _Server();
    storage = _Storage();
    execution = _Execution();
    discovery = _Discovery();
    directory = '/tmp';
    container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(() => _Settings(directory)),
        androidStorageAccessProvider.overrideWithValue(storage),
        androidBackgroundExecutionProvider.overrideWithValue(execution),
        networkProvider.overrideWith(
          (ref) async => const NetworkSnapshot(ip: '127.0.0.1'),
        ),
        fileServerProvider.overrideWithValue(server),
        discoveryProvider.overrideWith(() => discovery),
      ],
    );
  });
  tearDown(() => container.dispose());

  test('receiver withdraws its advertisement before closing HTTP', () async {
    await container.read(receiveControllerProvider.future);
    final controller = container.read(receiveControllerProvider.notifier);
    await controller.startForVideoShare();
    discovery.stopGate = Completer<void>();
    final stopping = controller.stopIfScreenShareOnly();
    await discovery.stopping.future;
    expect(server.stops, 0);
    discovery.stopGate!.complete();
    expect(await stopping, isTrue);
    expect(server.stops, 1);
  });

  test(
    'denied storage never creates the destination or starts file reception',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'bshare-denied-receiver-',
      );
      addTearDown(() => temp.delete(recursive: true));
      directory = '${temp.path}/Downloads';
      storage.granted = false;
      await container.read(receiveControllerProvider.future);
      await container.read(receiveControllerProvider.notifier).start();
      final state = container.read(receiveControllerProvider).value!;
      expect(state.visible, isFalse);
      expect(state.acceptingFiles, isFalse);
      expect(state.error, 'storagePermissionRequired');
      expect(storage.requests, [directory]);
      expect(await Directory(directory).exists(), isFalse);
      expect(server.starts, 0);
      expect(server.stops, 0);
      expect(execution.acquisitions, isEmpty);
      expect(
        container.read(settingsProvider).value!.downloadDirectory,
        directory,
      );
    },
  );

  test(
    'video signaling needs no storage grant, destination or file service',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'bshare-video-receiver-',
      );
      addTearDown(() => temp.delete(recursive: true));
      directory = '${temp.path}/Downloads';
      storage.granted = false;
      await container.read(receiveControllerProvider.future);
      final controller = container.read(receiveControllerProvider.notifier);
      await controller.startForVideoShare();
      final state = container.read(receiveControllerProvider).value!;
      expect(state.visible, isTrue);
      expect(state.acceptingFiles, isFalse);
      expect(storage.requests, isEmpty);
      expect(storage.checks, isEmpty);
      expect(await Directory(directory).exists(), isFalse);
      expect(server.destinations, [Directory.systemTemp.path]);
      expect(server.fileReceptionEnabled, isFalse);
      expect(await server.fileAccessHandler!(directory), isFalse);
      expect(execution.acquisitions, isEmpty);
      expect(
        container.read(settingsProvider).value!.downloadDirectory,
        directory,
      );
      await controller.stop(force: true);
    },
  );

  test(
    'denied promotion preserves video and does not retain a file claim',
    () async {
      storage.granted = false;
      await container.read(receiveControllerProvider.future);
      final controller = container.read(receiveControllerProvider.notifier);
      await controller.startForVideoShare();
      await controller.start();
      final state = container.read(receiveControllerProvider).value!;
      expect(state.visible, isTrue);
      expect(state.port, 53317);
      expect(state.acceptingFiles, isFalse);
      expect(state.error, 'storagePermissionRequired');
      expect(server.starts, 1);
      expect(server.stops, 0);
      expect(server.updates, isEmpty);
      expect(server.fileReceptionEnabled, isFalse);
      expect(execution.acquisitions, isEmpty);
      expect(await controller.stopIfScreenShareOnly(), isTrue);
      expect(server.stops, 1);
    },
  );

  test(
    'promotion revalidates and updates the existing listener without duplicates',
    () async {
      await container.read(receiveControllerProvider.future);
      final controller = container.read(receiveControllerProvider.notifier);
      await controller.startForVideoShare();
      await controller.start();
      expect(storage.requests, [directory]);
      expect(server.starts, 1);
      expect(server.stops, 0);
      expect(server.updates, [directory]);
      expect(server.fileReceptionEnabled, isTrue);
      expect(
        container.read(receiveControllerProvider).value!.acceptingFiles,
        isTrue,
      );
      expect(execution.acquisitions, [BackgroundExecutionOwner.fileReceiving]);
      await controller.start();
      expect(storage.requests, [directory, directory]);
      expect(server.starts, 1);
      expect(execution.acquisitions, [BackgroundExecutionOwner.fileReceiving]);
      expect(await controller.stopIfScreenShareOnly(), isFalse);
      expect(discovery.stops, 0);
      await controller.stop(force: true);
    },
  );

  test(
    'revocation disables new files while keeping video and permits a grant retry',
    () async {
      await container.read(receiveControllerProvider.future);
      final controller = container.read(receiveControllerProvider.notifier);
      await controller.startForVideoShare();
      await controller.start();
      storage.granted = false;
      expect(await server.fileAccessHandler!(directory), isFalse);
      var state = container.read(receiveControllerProvider).value!;
      expect(state.visible, isTrue);
      expect(state.acceptingFiles, isFalse);
      expect(state.error, 'storagePermissionRequired');
      expect(server.fileReceptionEnabled, isFalse);
      expect(server.stops, 0);
      await controller.start();
      expect(
        container.read(receiveControllerProvider).value!.acceptingFiles,
        isFalse,
      );
      storage.granted = true;
      await controller.start();
      state = container.read(receiveControllerProvider).value!;
      expect(state.visible, isTrue);
      expect(state.acceptingFiles, isTrue);
      expect(state.error, isNull);
      expect(server.fileReceptionEnabled, isTrue);
      expect(server.starts, 1);
      expect(await server.fileAccessHandler!(directory), isTrue);
      await controller.stop(force: true);
    },
  );

  test(
    'storage revocation finishes queued work without touching active files',
    () async {
      await container.read(receiveControllerProvider.future);
      final controller = container.read(receiveControllerProvider.notifier);
      await controller.start();
      IncomingTransfer transfer(String id) => IncomingTransfer(
        id: id,
        senderName: 'Sender',
        senderId: 'sender',
        fileName: '$id.bin',
        size: 10,
        createdAt: DateTime.now(),
        decision: Completer<bool>(),
      );
      server.onQueue!(
        senderId: 'sender',
        senderName: 'Sender',
        transfers: [
          transfer('queued-1'),
          transfer('queued-2'),
          transfer('pending-paused'),
          transfer('active'),
          transfer('paused'),
        ],
      );
      container
          .read(receiveProgressProvider.notifier)
          .updateStatus('active', TransferProgressStatus.receiving);
      container
          .read(receiveProgressProvider.notifier)
          .updateStatus('paused', TransferProgressStatus.paused);
      container
          .read(receiveProgressProvider.notifier)
          .updateStatus('pending-paused', TransferProgressStatus.paused);
      final controls = {...container.read(receiveTransferControlProvider)};
      final pendingPaused = transfer('pending-paused');
      final pausedResult = container
          .read(incomingTransfersProvider.notifier)
          .requestDecision(pendingPaused);
      final waiting = transfer('waiting-decision');
      final waitingResult = container
          .read(incomingTransfersProvider.notifier)
          .requestDecision(waiting);
      final activeDecision = transfer('active');
      final activeResult = container
          .read(incomingTransfersProvider.notifier)
          .requestDecision(activeDecision);
      storage.granted = false;
      expect(await server.fileAccessHandler!(directory), isFalse);
      expect(await waitingResult, isFalse);
      expect(await pausedResult, isFalse);
      final progress = {
        for (final item in container.read(receiveProgressProvider))
          item.id: item,
      };
      for (final id in ['queued-1', 'queued-2', 'pending-paused']) {
        expect(progress[id]!.status, TransferProgressStatus.cancelled);
        expect(controls[id]!.isCancelled, isTrue);
        expect(
          container.read(receiveTransferControlProvider),
          isNot(contains(id)),
        );
      }
      expect(progress['active']!.status, TransferProgressStatus.receiving);
      expect(progress['paused']!.status, TransferProgressStatus.paused);
      expect(controls['active']!.isCancelled, isFalse);
      expect(controls['paused']!.isCancelled, isFalse);
      expect(activeDecision.decision.isCompleted, isFalse);
      expect(container.read(receiveControllerProvider).value!.visible, isTrue);
      expect(server.stops, 0);
      expect(await controller.stop(), isFalse);
      container.read(incomingTransfersProvider.notifier).decide('active', true);
      expect(await activeResult, isTrue);
      container
          .read(receiveProgressProvider.notifier)
          .updateStatus('active', TransferProgressStatus.completed);
      container
          .read(receiveProgressProvider.notifier)
          .updateStatus('paused', TransferProgressStatus.completed);
      expect(await controller.stop(), isTrue);
      expect(server.stops, 1);
    },
  );

  test(
    'a denied old destination cannot disable a valid new destination',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'bshare-receiver-switch-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final previousDirectory = directory = '${temp.path}/old-shared';
      final currentDirectory = await Directory(
        '${temp.path}/new-private',
      ).create();
      await container.read(receiveControllerProvider.future);
      final controller = container.read(receiveControllerProvider.notifier);
      await controller.start();
      final oldHandler = server.fileAccessHandler!;
      storage.pathGrants[previousDirectory] = false;
      (container.read(settingsProvider.notifier) as _Settings).setDirectory(
        currentDirectory.path,
      );
      server.updateReceiverSettings(
        downloadDirectory: currentDirectory.path,
        autoAccept: true,
      );
      expect(await oldHandler(previousDirectory), isFalse);
      expect(server.fileReceptionEnabled, isTrue);
      expect(
        container.read(receiveControllerProvider).value!.acceptingFiles,
        isTrue,
      );
      expect(container.read(receiveControllerProvider).value!.error, isNull);
      expect(await server.fileAccessHandler!(currentDirectory.path), isTrue);
      expect(server.stops, 0);
      await controller.stop(force: true);
    },
  );

  test('current destinations are compared after path normalization', () async {
    await container.read(receiveControllerProvider.future);
    final controller = container.read(receiveControllerProvider.notifier);
    await controller.start();
    storage.granted = false;
    expect(await server.fileAccessHandler!('$directory/./'), isFalse);
    expect(server.fileReceptionEnabled, isFalse);
    expect(
      container.read(receiveControllerProvider).value!.acceptingFiles,
      isFalse,
    );
    await controller.stop(force: true);
  });

  test(
    'an old denied access result cannot disable a later successful promotion',
    () async {
      await container.read(receiveControllerProvider.future);
      final controller = container.read(receiveControllerProvider.notifier);
      await controller.start();
      final gate = storage.checkGate = Completer<bool>();
      final checking = server.fileAccessHandler!(directory);
      await Future<void>.delayed(Duration.zero);
      await controller.start();
      gate.complete(false);
      expect(await checking, isFalse);
      expect(
        container.read(receiveControllerProvider).value!.acceptingFiles,
        isTrue,
      );
      expect(server.fileReceptionEnabled, isTrue);
      await controller.stop(force: true);
    },
  );

  test(
    'unwritable configured folder never silently changes the destination',
    () async {
      directory = '/proc/bshare-unwritable-test/Downloads';
      await container.read(receiveControllerProvider.future);
      final controller = container.read(receiveControllerProvider.notifier);
      await controller.startForVideoShare();
      await controller.start();
      final state = container.read(receiveControllerProvider).value!;
      expect(state.visible, isTrue);
      expect(state.acceptingFiles, isFalse);
      expect(state.error, 'storageAccessFailed');
      expect(server.starts, 1);
      expect(server.stops, 0);
      expect(server.updates, isEmpty);
      expect(execution.acquisitions, isEmpty);
      expect(
        container.read(settingsProvider).value!.downloadDirectory,
        directory,
      );
      await controller.stop(force: true);
      expect(server.fileAccessHandler, isNull);
      expect(server.fileReceptionEnabled, isFalse);
    },
  );

  test(
    'screen-only receiver is released after capture; manual receiver is retained',
    () async {
      await container.read(receiveControllerProvider.future);
      final controller = container.read(receiveControllerProvider.notifier);
      await controller.startForScreenShare();
      expect(await controller.stopIfScreenShareOnly(), isTrue);
      expect(server.stops, 1);
      await controller.start();
      await controller.startForScreenShare();
      expect(await controller.stopIfScreenShareOnly(), isFalse);
      expect(container.read(receiveControllerProvider).value!.visible, isTrue);
      expect(server.stops, 1);
      await controller.stop(force: true);
    },
  );

  test(
    'claiming a screen receiver for files preserves it after capture ends',
    () async {
      await container.read(receiveControllerProvider.future);
      final controller = container.read(receiveControllerProvider.notifier);
      await controller.startForScreenShare();
      await controller.start();
      expect(await controller.stopIfScreenShareOnly(), isFalse);
      expect(server.starts, 1);
      expect(server.stops, 0);
      await controller.stop(force: true);
    },
  );

  test(
    'screen receiver waits for file responses before automatic cleanup',
    () async {
      await container.read(receiveControllerProvider.future);
      final controller = container.read(receiveControllerProvider.notifier);
      await controller.startForScreenShare();
      server.onQueue!(
        senderId: 'sender',
        senderName: 'Sender',
        transfers: [
          IncomingTransfer(
            id: 'finishing',
            senderName: 'Sender',
            senderId: 'sender',
            fileName: 'x.bin',
            size: 1,
            createdAt: DateTime.now(),
            decision: Completer<bool>(),
          ),
        ],
      );
      expect(await controller.stopIfScreenShareOnly(), isFalse);
      expect(server.stops, 0);
      container
          .read(receiveProgressProvider.notifier)
          .updateStatus('finishing', TransferProgressStatus.completed);
      expect(server.stops, 0);
      server.onIdle!();
      await Future<void>.delayed(Duration.zero);
      expect(server.stops, 1);
      expect(container.read(receiveControllerProvider).value!.visible, isFalse);
    },
  );

  test('concurrent starts initialize the receiver once', () async {
    await container.read(receiveControllerProvider.future);
    final controller = container.read(receiveControllerProvider.notifier);
    await Future.wait(List.generate(8, (_) => controller.start()));
    expect(server.starts, 1);
    expect(
      container.read(receiveControllerProvider).asData!.value.visible,
      isTrue,
    );
    await controller.stop(force: true);
    expect(
      container.read(receiveControllerProvider).asData!.value.visible,
      isFalse,
    );
  });

  test(
    'stop requested during startup waits and leaves receiver stopped',
    () async {
      await container.read(receiveControllerProvider.future);
      final controller = container.read(receiveControllerProvider.notifier);
      server.startGate = Completer<void>();
      final starting = controller.start();
      await server.started.future;
      final stopping = controller.stop(force: true);
      server.startGate!.complete();
      await starting;
      expect(await stopping, isTrue);
      expect(server.stops, 1);
      expect(
        container.read(receiveControllerProvider).asData!.value.visible,
        isFalse,
      );
    },
  );

  test(
    'repeated queue announcements preserve active progress and controls',
    () async {
      await container.read(receiveControllerProvider.future);
      final controller = container.read(receiveControllerProvider.notifier);
      await controller.start();
      final transfer = IncomingTransfer(
        id: 'file-1',
        senderName: 'Sender',
        senderId: 'sender',
        fileName: 'file.bin',
        size: 3,
        createdAt: DateTime.now(),
        decision: Completer<bool>(),
      );
      server.onQueue!(
        senderId: 'sender',
        senderName: 'Sender',
        transfers: [transfer],
      );
      final control = container.read(receiveTransferControlProvider)['file-1'];
      container
          .read(receiveProgressProvider.notifier)
          .updateStatus('file-1', TransferProgressStatus.receiving);
      server.onQueue!(
        senderId: 'sender',
        senderName: 'Sender',
        transfers: [transfer, transfer],
      );
      expect(container.read(receiveProgressProvider), hasLength(1));
      expect(
        container.read(receiveProgressProvider).single.status,
        TransferProgressStatus.receiving,
      );
      expect(
        container.read(receiveTransferControlProvider)['file-1'],
        same(control),
      );
      await controller.stop(force: true);
      expect(control!.isCancelled, isTrue);
      expect(
        container.read(receiveProgressProvider).single.status,
        TransferProgressStatus.cancelled,
      );
      expect(container.read(receiveTransferControlProvider), isEmpty);
    },
  );
}
