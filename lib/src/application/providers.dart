import 'dart:async';
import 'dart:io';

import 'package:bshare/src/application/receive_controller.dart';
import 'package:bshare/src/application/send_controller.dart';
import 'package:bshare/src/domain/entities/app_settings.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/domain/entities/incoming_transfer.dart';
import 'package:bshare/src/domain/entities/receive_progress.dart';
import 'package:bshare/src/domain/entities/send_progress.dart';
import 'package:bshare/src/domain/entities/selected_transfer_file.dart';
import 'package:bshare/src/domain/entities/transfer_control.dart';
import 'package:bshare/src/domain/entities/transfer_progress_status.dart';
import 'package:bshare/src/domain/entities/transfer_record.dart';
import 'package:bshare/src/infrastructure/repositories/history_repository.dart';
import 'package:bshare/src/infrastructure/repositories/settings_repository.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/android_apps_service.dart';
import 'package:bshare/src/infrastructure/services/android_background_execution_service.dart';
import 'package:bshare/src/infrastructure/services/android_screen_share_execution_service.dart';
import 'package:bshare/src/infrastructure/services/android_share_service.dart';
import 'package:bshare/src/infrastructure/services/direct_network_service.dart';
import 'package:bshare/src/infrastructure/services/file_server.dart';
import 'package:bshare/src/infrastructure/services/file_transfer_client.dart';
import 'package:bshare/src/infrastructure/services/lan_discovery_service.dart';
import 'package:bshare/src/infrastructure/services/network_service.dart';
import 'package:bshare/src/infrastructure/services/open_path_service.dart';
import 'package:bshare/src/infrastructure/services/platform_service.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

final loggerProvider = Provider((ref) => const AppLogger());

final androidAppsServiceProvider = Provider((ref) => AndroidAppsService());

final androidBackgroundExecutionProvider = Provider((ref) {
  final service = AndroidBackgroundExecutionService(ref.watch(loggerProvider));
  ref.onDispose(service.dispose);
  return service;
});

final androidShareServiceProvider = Provider((ref) {
  final service = AndroidShareService();
  ref.onDispose(service.dispose);
  return service;
});

final androidScreenShareExecutionProvider = Provider((ref) {
  final service = AndroidScreenShareExecutionService();
  ref.onDispose(() => unawaited(service.stop()));
  return service;
});

final directNetworkServiceProvider = Provider((ref) => DirectNetworkService());

final sharedPreferencesProvider = FutureProvider(
  (ref) => SharedPreferences.getInstance(),
);

final settingsRepositoryProvider = FutureProvider((ref) async {
  final prefs = await ref.watch(sharedPreferencesProvider.future);
  return SettingsRepository(prefs);
});

final settingsProvider = AsyncNotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);

class SettingsController extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() async {
    final repo = await ref.watch(settingsRepositoryProvider.future);
    return repo.load();
  }

  Future<void> save(AppSettings settings) async {
    final repo = await ref.read(settingsRepositoryProvider.future);
    await repo.save(settings);
    state = AsyncData(settings);
  }
}

final historyRepositoryProvider = Provider(
  (ref) => HistoryRepository(Hive.box<String>('transfer_history')),
);

final historyProvider =
    NotifierProvider<HistoryController, List<TransferRecord>>(
      HistoryController.new,
    );

class HistoryController extends Notifier<List<TransferRecord>> {
  @override
  List<TransferRecord> build() => ref.watch(historyRepositoryProvider).all();

  Future<void> add(TransferRecord record) async {
    await ref.read(historyRepositoryProvider).add(record);
    state = ref.read(historyRepositoryProvider).all();
  }

  Future<void> clear() async {
    await ref.read(historyRepositoryProvider).clear();
    state = const [];
  }
}

final networkProvider = FutureProvider((ref) => NetworkService().snapshot());

final fileServerProvider = Provider((ref) {
  final server = FileServer(ref.watch(loggerProvider));
  ref.onDispose(server.stop);
  return server;
});

final discoveryServiceProvider = Provider((ref) {
  final service = LanDiscoveryService(ref.watch(loggerProvider));
  ref.onDispose(service.dispose);
  return service;
});

final discoveryProvider =
    NotifierProvider<DiscoveryController, List<DeviceInfo>>(
      DiscoveryController.new,
    );

class DiscoveryController extends Notifier<List<DeviceInfo>> {
  StreamSubscription<DeviceInfo>? _subscription;

  @override
  List<DeviceInfo> build() {
    ref.onDispose(() => _subscription?.cancel());
    return const [];
  }

  Future<void> start({bool advertise = false, String? ipOverride}) async {
    final settings = await ref.read(settingsProvider.future);
    final ip = ipOverride ?? (await ref.read(networkProvider.future)).ip;
    if (ip == null) return;
    final server = ref.read(fileServerProvider);
    final self = DeviceInfo(
      id: settings.deviceId,
      name: settings.deviceName,
      platform: currentPlatformName(),
      ip: ip,
      port: server.port ?? settings.preferredPort,
      lastSeen: DateTime.now(),
    );
    final service = ref.read(discoveryServiceProvider);
    await service.start(self, advertise: advertise);
    await _subscription?.cancel();
    _subscription = service.devices.listen((device) {
      final now = DateTime.now();
      final fresh = state
          .where(
            (item) =>
                now.difference(item.lastSeen) < const Duration(seconds: 20) &&
                item.id != device.id,
          )
          .toList();
      state = [...fresh, device]..sort((a, b) => a.name.compareTo(b.name));
    });
  }

  Future<void> refresh() async {
    state = const [];
    await start(advertise: false);
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await ref.read(discoveryServiceProvider).stop();
    state = const [];
  }
}

final incomingTransfersProvider =
    NotifierProvider<IncomingTransfersController, List<IncomingTransfer>>(
      IncomingTransfersController.new,
    );

class IncomingTransfersController extends Notifier<List<IncomingTransfer>> {
  @override
  List<IncomingTransfer> build() => const [];

  Future<bool> requestDecision(IncomingTransfer transfer) async {
    state = [...state, transfer];
    final accepted = await transfer.decision.future;
    state = state.where((item) => item.id != transfer.id).toList();
    return accepted;
  }

  void decide(String id, bool accepted) {
    final transfer = state.where((item) => item.id == id).firstOrNull;
    if (transfer != null && !transfer.decision.isCompleted) {
      transfer.decision.complete(accepted);
    }
  }

  void rejectAll() {
    for (final transfer in state) {
      if (!transfer.decision.isCompleted) {
        transfer.decision.complete(false);
      }
    }
    state = const [];
  }
}

final receiveProgressProvider =
    NotifierProvider<ReceiveProgressController, List<ReceiveProgress>>(
      ReceiveProgressController.new,
    );

class ReceiveProgressController extends Notifier<List<ReceiveProgress>> {
  @override
  List<ReceiveProgress> build() => const [];

  void upsert(ReceiveProgress progress) {
    state = [
      for (final item in state)
        if (item.id == progress.id)
          progress.copyWith(
            controlHost: progress.controlHost ?? item.controlHost,
            controlPort: progress.controlPort ?? item.controlPort,
          )
        else
          item,
      if (!state.any((item) => item.id == progress.id)) progress,
    ];
  }

  void clearCompleted() {
    state = state.where((item) => !item.status.isTerminal).toList();
  }

  void clear() => state = const [];

  void updateStatus(
    String id,
    TransferProgressStatus status, {
    String? message,
  }) {
    state = [
      for (final item in state)
        if (item.id == id)
          item.copyWith(
            bytesPerSecond: 0,
            status: status,
            message: message,
            clearMessage: message == null,
          )
        else
          item,
    ];
  }
}

final receiveControllerProvider =
    AsyncNotifierProvider<ReceiveController, ReceiveState>(
      ReceiveController.new,
    );

final fileTransferClientProvider = Provider((ref) {
  final client = FileTransferClient(ref.watch(loggerProvider));
  ref.onDispose(client.dispose);
  return client;
});

final openPathServiceProvider = Provider((ref) => OpenPathService());

final screenShareServiceProvider = Provider((ref) {
  final service = ScreenShareService(
    ref.watch(loggerProvider),
    ref.watch(androidScreenShareExecutionProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

final pickedFilesProvider =
    NotifierProvider<PickedFilesController, List<SelectedTransferFile>>(
      PickedFilesController.new,
    );

class PickedFilesController extends Notifier<List<SelectedTransferFile>> {
  @override
  List<SelectedTransferFile> build() => const [];

  void set(List<SelectedTransferFile> files) => state = files;

  void append(List<SelectedTransferFile> files) => state = [...state, ...files];

  void remove(String path) =>
      state = state.where((file) => file.path != path).toList();

  void clear() => state = const [];
}

final selectedDeviceProvider =
    NotifierProvider<SelectedDeviceController, DeviceInfo?>(
      SelectedDeviceController.new,
    );

class SelectedDeviceController extends Notifier<DeviceInfo?> {
  @override
  DeviceInfo? build() => null;

  void set(DeviceInfo? device) => state = device;
}

final sendProgressProvider =
    NotifierProvider<SendProgressController, List<SendProgress>>(
      SendProgressController.new,
    );

class SendProgressController extends Notifier<List<SendProgress>> {
  @override
  List<SendProgress> build() => const [];

  void upsert(SendProgress progress) {
    state = [
      for (final item in state)
        if (item.id == progress.id) progress else item,
      if (!state.any((item) => item.id == progress.id)) progress,
    ];
  }

  void clear() => state = const [];

  void clearCompleted() {
    state = state.where((item) => !item.status.isTerminal).toList();
  }

  void updateStatus(
    String id,
    TransferProgressStatus status, {
    String? message,
  }) {
    state = [
      for (final item in state)
        if (item.id == id)
          item.copyWith(
            bytesPerSecond: 0,
            status: status,
            message: message,
            clearMessage: message == null,
          )
        else
          item,
    ];
  }
}

final transferControlProvider =
    NotifierProvider<TransferControlController, Map<String, TransferControl>>(
      TransferControlController.new,
    );

final receiveTransferControlProvider =
    NotifierProvider<TransferControlController, Map<String, TransferControl>>(
      TransferControlController.new,
    );

class TransferControlController extends Notifier<Map<String, TransferControl>> {
  @override
  Map<String, TransferControl> build() => const {};

  void set(Map<String, TransferControl> controls) => state = controls;

  void clear() => state = const {};

  void remove(String id) => state = {...state}..remove(id);

  void pause(String id) {
    final control = state[id];
    control?.pause();
    state = {...state};
  }

  void resume(String id) {
    final control = state[id];
    control?.resume();
    state = {...state};
  }

  void cancel(String id) {
    final control = state[id];
    control?.cancel();
    state = {...state};
  }
}

final sendControllerProvider = Provider((ref) {
  final controller = SendController(ref);
  ref.onDispose(() => unawaited(controller.dispose(updateState: false)));
  return controller;
});

final runtimeCleanupProvider = Provider((ref) => RuntimeCleanup(ref));

class RuntimeCleanup {
  const RuntimeCleanup(this._ref);

  final Ref _ref;

  Future<void> cleanupNetworking({
    bool cancelTransfers = true,
    bool cleanupSelectedFiles = false,
  }) async {
    if (cancelTransfers) {
      final selectedFiles = _ref.read(pickedFilesProvider);
      await _ref
          .read(sendControllerProvider)
          .dispose(
            cleanupSelectedFiles: cleanupSelectedFiles,
            selectedFiles: selectedFiles,
          );
      if (cleanupSelectedFiles) {
        _ref.read(pickedFilesProvider.notifier).clear();
      }
      _ref.read(transferControlProvider.notifier).clear();
      _ref.read(incomingTransfersProvider.notifier).rejectAll();
    }
    await _ref
        .read(screenShareServiceProvider)
        .stop(_ref.read(fileServerProvider));
    await _ref
        .read(receiveControllerProvider.notifier)
        .stop(force: cancelTransfers);
    await _ref.read(discoveryProvider.notifier).stop();
    await _ref.read(directNetworkServiceProvider).stopLocalOnlyHotspot();
    await _ref.read(directNetworkServiceProvider).disconnectWifi();
    if (cancelTransfers) {
      _ref.read(sendProgressProvider.notifier).clear();
      _ref.read(receiveProgressProvider.notifier).clear();
      _ref.read(receiveTransferControlProvider.notifier).clear();
    }
  }
}

TransferRecord transferRecord({
  required TransferDirection direction,
  required String fileName,
  required int size,
  required String remoteDevice,
  required TransferStatus status,
  String? error,
}) {
  return TransferRecord(
    id: const Uuid().v4(),
    direction: direction,
    fileName: fileName,
    size: size,
    createdAt: DateTime.now(),
    remoteDevice: remoteDevice,
    status: status,
    error: error,
  );
}

Future<void> ensureDirectory(String path) async {
  final dir = Directory(path);
  if (!await dir.exists()) await dir.create(recursive: true);
}
