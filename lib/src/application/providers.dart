import 'dart:async';
import 'dart:io';

import 'package:bshare/src/application/receive_controller.dart';
import 'package:bshare/src/application/camera_session_controller.dart';
import 'package:bshare/src/application/send_controller.dart';
import 'package:bshare/src/domain/entities/app_settings.dart';
import 'package:bshare/src/domain/entities/camera_device.dart';
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
import 'package:bshare/src/infrastructure/services/android_platform_info_service.dart';
import 'package:bshare/src/infrastructure/services/android_storage_access_service.dart';
import 'package:bshare/src/infrastructure/services/android_background_execution_service.dart';
import 'package:bshare/src/infrastructure/services/android_screen_share_execution_service.dart';
import 'package:bshare/src/infrastructure/services/android_camera_execution_service.dart';
import 'package:bshare/src/infrastructure/services/camera_display_service.dart';
import 'package:bshare/src/infrastructure/services/usb_camera_network_service.dart';
import 'package:bshare/src/infrastructure/services/usb_adb_transport_service.dart';
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

final androidPlatformInfoProvider = Provider(
  (ref) => AndroidPlatformInfoService.instance,
);

final androidStorageAccessProvider = Provider(
  (ref) => AndroidStorageAccessService(
    platformInfo: ref.watch(androidPlatformInfoProvider),
  ),
);

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

final directNetworkServiceProvider = Provider((ref) {
  final service = DirectNetworkService(
    platformInfo: ref.watch(androidPlatformInfoProvider),
  );
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

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
  Future<void> _saving = Future<void>.value();
  @override
  Future<AppSettings> build() async {
    final repo = await ref.watch(settingsRepositoryProvider.future);
    return repo.load();
  }

  Future<void> save(AppSettings settings) => saveChanges((_) => settings);

  Future<void> saveChanges(
    FutureOr<AppSettings> Function(AppSettings current) change,
  ) {
    final operation = _saving.then((_) async {
      final repo = await ref.read(settingsRepositoryProvider.future);
      final current = state.asData?.value ?? await repo.load();
      final settings = await change(current);
      if (settings.downloadDirectory != current.downloadDirectory) {
        await ref
            .read(androidStorageAccessProvider)
            .ensureAccess(settings.downloadDirectory);
        await ensureDirectory(settings.downloadDirectory);
      }
      await repo.save(settings);
      if (!ref.mounted) return;
      state = AsyncData(settings);
      if (settings.downloadDirectory != current.downloadDirectory ||
          settings.autoAccept != current.autoAccept) {
        ref
            .read(fileServerProvider)
            .updateReceiverSettings(
              downloadDirectory: settings.downloadDirectory,
              autoAccept: settings.autoAccept,
            );
      }
      if (settings.deviceName != current.deviceName &&
          ref.read(discoveryStatusProvider).isListening) {
        await ref.read(discoveryProvider.notifier).start();
      }
    });
    _saving = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
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

enum DiscoveryPhase { idle, searching, listening, error }

class DiscoveryStatus {
  const DiscoveryStatus({
    this.phase = DiscoveryPhase.idle,
    this.error,
    this.lastScanAt,
  });

  final DiscoveryPhase phase;
  final Object? error;
  final DateTime? lastScanAt;

  bool get isSearching => phase == DiscoveryPhase.searching;
  bool get isListening => isSearching || phase == DiscoveryPhase.listening;
}

final discoveryStatusProvider =
    NotifierProvider<DiscoveryStatusController, DiscoveryStatus>(
      DiscoveryStatusController.new,
    );

class DiscoveryStatusController extends Notifier<DiscoveryStatus> {
  @override
  DiscoveryStatus build() => const DiscoveryStatus();

  void set(DiscoveryStatus value) => state = value;
}

class DiscoveryController extends Notifier<List<DeviceInfo>> {
  DiscoveryController({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  // Receivers announce every three seconds. One complete announcement cycle
  // fits inside this finite window; the socket keeps listening afterwards.
  static const searchWindow = Duration(seconds: 12);
  static const deviceLifetime = Duration(seconds: 20);

  final DateTime Function() _clock;
  StreamSubscription<DeviceInfo>? _subscription;
  StreamSubscription<DeviceInfo>? _departureSubscription;
  LanDiscoveryService? _service;
  DeviceInfo? _self;
  List<LanInterface> _interfaces = const [];
  String _networkSignature = '';
  final _candidates = <String, ({DeviceInfo device, int sequence})>{};
  int _announcementSequence = 0;
  static const _maximumCandidates = 512;
  bool _advertise = false;
  bool _running = false;
  Timer? _searchTimer;
  Timer? _expiryTimer;
  Completer<void>? _searchCompletion;
  Future<void>? _refreshFuture;
  Future<void> _operation = Future<void>.value();

  Future<void> _serialize(Future<void> Function() action) {
    final operation = _operation.then((_) => action());
    _operation = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return operation;
  }

  @override
  List<DeviceInfo> build() {
    ref.onDispose(() {
      _finishSearch();
      _expiryTimer?.cancel();
      _expiryTimer = null;
      unawaited(_subscription?.cancel());
      _subscription = null;
      unawaited(_departureSubscription?.cancel());
      _departureSubscription = null;
      _candidates.clear();
      _interfaces = const [];
    });
    return const [];
  }

  Future<void> start({bool advertise = false, String? ipOverride}) =>
      _serialize(() => _start(advertise: advertise, ipOverride: ipOverride));

  Future<void> _start({
    required bool advertise,
    String? ipOverride,
    bool beginSearch = true,
  }) async {
    if (!ref.mounted) return;
    if (!_running) _setStatus(DiscoveryPhase.searching);
    try {
      final settings = await ref.read(settingsProvider.future);
      if (!ref.mounted) return;
      final network = ipOverride == null
          ? await ref.read(networkProvider.future)
          : ref.exists(networkProvider)
          ? ref.read(networkProvider).asData?.value ??
                NetworkSnapshot(ip: ipOverride)
          : NetworkSnapshot(ip: ipOverride);
      final ip = ipOverride ?? network.ip;
      if (!ref.mounted) return;
      if (ip == null || ip.isEmpty) {
        throw StateError('No local network address is available');
      }
      final server = ref.read(fileServerProvider);
      final self = DeviceInfo(
        id: settings.deviceId,
        name: settings.deviceName,
        platform: currentPlatformName(),
        ip: ip,
        port: server.port ?? settings.preferredPort,
        lastSeen: _clock(),
      );
      // A sending/discovery screen must not turn off an active receiver's
      // advertisements when it also requests discovery.
      final shouldAdvertise = _advertise || advertise;
      final signature = _interfaceSignature(network.interfaces);
      if (_running &&
          _sameEndpoint(self, _self) &&
          signature == _networkSignature &&
          shouldAdvertise == _advertise) {
        return;
      }
      final service = ref.read(discoveryServiceProvider);
      _service = service;
      if (_self?.ip != self.ip) {
        _candidates.clear();
        state = const [];
      }
      _interfaces = network.interfaces;
      _pruneCandidates();
      _publishCandidates();
      // Subscribe before binding: a receiver may announce immediately.
      _subscription ??= service.devices.listen(_onDevice);
      _departureSubscription ??= service.departures.listen(_onDeparture);
      await service.start(self, advertise: shouldAdvertise);
      if (!ref.mounted) {
        await service.stop();
        return;
      }
      _self = self;
      _networkSignature = signature;
      _advertise = shouldAdvertise;
      _running = true;
      _expiryTimer ??= Timer.periodic(
        const Duration(seconds: 1),
        (_) => _pruneDevices(),
      );
      if (beginSearch) _beginSearch();
    } catch (error) {
      if (!ref.mounted) return;
      ref.read(loggerProvider).warn('Discovery could not start: $error');
      await _stopListening();
      if (ref.mounted) _setStatus(DiscoveryPhase.error, error: error);
    }
  }

  bool _sameEndpoint(DeviceInfo self, DeviceInfo? previous) =>
      previous != null &&
      self.id == previous.id &&
      self.ip == previous.ip &&
      self.port == previous.port &&
      self.name == previous.name &&
      self.platform == previous.platform;

  String _interfaceSignature(List<LanInterface> interfaces) => interfaces
      .map((interface) {
        final addresses = [
          for (final address in interface.addresses)
            '${address.address}/${interface.prefixLengths[address.address]}',
        ]..sort();
        return '${interface.index}:${interface.metric}:'
            '${interface.hasDefaultRoute}:${interface.kind}:'
            '${addresses.join(',')}';
      })
      .join('|');

  String _candidateKey(DeviceInfo device) =>
      '${device.id}:${device.ip}:${device.port}';

  void _onDevice(DeviceInfo device) {
    if (!ref.mounted) return;
    final pruned = _pruneCandidates();
    if (_clock().difference(device.lastSeen) >= deviceLifetime) {
      if (pruned) _publishCandidates();
      return;
    }
    final key = _candidateKey(device);
    // Refresh insertion order so a bounded cache keeps recently heard endpoints.
    _candidates.remove(key);
    _candidates[key] = (device: device, sequence: ++_announcementSequence);
    while (_candidates.length > _maximumCandidates) {
      _candidates.remove(_candidates.keys.first);
    }
    _publishCandidates();
  }

  ({int interfaceRank, int prefixLength}) _routePreference(DeviceInfo device) {
    final remote = InternetAddress.tryParse(device.ip);
    if (remote != null) {
      for (var index = 0; index < _interfaces.length; index++) {
        var matchingPrefix = 0;
        final interface = _interfaces[index];
        for (final local in interface.addresses) {
          final prefix = interface.prefixLengths[local.address];
          if (prefix != null &&
              sameIpv4Subnet(local, remote, prefix) &&
              prefix > matchingPrefix) {
            matchingPrefix = prefix;
          }
        }
        if (matchingPrefix > 0) {
          return (interfaceRank: index, prefixLength: matchingPrefix);
        }
      }
    }
    return (interfaceRank: _interfaces.length, prefixLength: 0);
  }

  int _compareCandidates(
    ({DeviceInfo device, int sequence}) a,
    ({DeviceInfo device, int sequence}) b,
  ) {
    if (_interfaces.isNotEmpty) {
      final firstRoute = _routePreference(a.device);
      final secondRoute = _routePreference(b.device);
      final byInterface = firstRoute.interfaceRank.compareTo(
        secondRoute.interfaceRank,
      );
      if (byInterface != 0) return byInterface;
      final byPrefix = secondRoute.prefixLength.compareTo(
        firstRoute.prefixLength,
      );
      if (byPrefix != 0) return byPrefix;
      final bySeen = b.device.lastSeen.compareTo(a.device.lastSeen);
      if (bySeen != 0) return bySeen;
    }
    // Without OS metadata retain the existing last-announcement behavior.
    return b.sequence.compareTo(a.sequence);
  }

  void _publishCandidates() {
    if (!ref.mounted) return;
    final previous = state;
    final winners = <String, ({DeviceInfo device, int sequence})>{};
    for (final candidate in _candidates.values) {
      final current = winners[candidate.device.id];
      if (current == null || _compareCandidates(candidate, current) < 0) {
        winners[candidate.device.id] = candidate;
      }
    }
    state = winners.values.map((candidate) => candidate.device).toList()
      ..sort((a, b) {
        final byName = a.name.compareTo(b.name);
        return byName == 0 ? a.id.compareTo(b.id) : byName;
      });
    // Keep the selected destination aligned with renewed announcements after
    // DHCP or receiver configuration changes. Running transfers retain their
    // immutable destination captured when send() started.
    final selected = ref.read(selectedDeviceProvider);
    if (selected == null) return;
    final winner = winners[selected.id]?.device;
    if (winner != null && !_sameEndpoint(winner, selected)) {
      ref.read(selectedDeviceProvider.notifier).set(winner);
    } else if (winner == null &&
        previous.any((device) => _sameEndpoint(device, selected))) {
      // A manually selected QR endpoint never heard by discovery is retained.
      ref.read(selectedDeviceProvider.notifier).set(null);
    }
  }

  bool _pruneCandidates() {
    final before = _candidates.length;
    final now = _clock();
    _candidates.removeWhere(
      (_, candidate) =>
          now.difference(candidate.device.lastSeen) >= deviceLifetime,
    );
    return before != _candidates.length;
  }

  void _pruneDevices() {
    if (!ref.mounted) return;
    if (_pruneCandidates()) _publishCandidates();
  }

  void _onDeparture(DeviceInfo device) {
    if (!ref.mounted) return;
    if (_candidates.remove(_candidateKey(device)) == null) return;
    _pruneCandidates();
    _publishCandidates();
  }

  void _setStatus(DiscoveryPhase phase, {Object? error}) {
    if (!ref.mounted) return;
    final previous = ref.read(discoveryStatusProvider);
    ref
        .read(discoveryStatusProvider.notifier)
        .set(
          DiscoveryStatus(
            phase: phase,
            error: error,
            lastScanAt: previous.lastScanAt,
          ),
        );
  }

  Future<void> _beginSearch() {
    _finishSearch();
    final completion = Completer<void>();
    _searchCompletion = completion;
    _setStatus(DiscoveryPhase.searching);
    _searchTimer = Timer(searchWindow, () {
      _searchTimer = null;
      if (ref.mounted && _running) {
        ref
            .read(discoveryStatusProvider.notifier)
            .set(
              DiscoveryStatus(
                phase: DiscoveryPhase.listening,
                lastScanAt: _clock(),
              ),
            );
      }
      if (!completion.isCompleted) completion.complete();
      if (identical(_searchCompletion, completion)) _searchCompletion = null;
    });
    return completion.future;
  }

  void _finishSearch() {
    _searchTimer?.cancel();
    _searchTimer = null;
    final completion = _searchCompletion;
    _searchCompletion = null;
    if (completion != null && !completion.isCompleted) completion.complete();
  }

  Future<void> refresh() {
    final pending = _refreshFuture;
    if (pending != null) return pending;
    Future<void>? search;
    final operation = _serialize(() async {
      if (!ref.mounted) return;
      // Re-read the interface after a Wi-Fi change, preserving the open socket
      // when its configuration is still valid.
      ref.invalidate(networkProvider);
      await _start(advertise: _advertise, beginSearch: false);
      if (!ref.mounted || !_running) return;
      _service?.requestDiscovery();
      _pruneDevices();
      search = _beginSearch();
    }).then((_) => search ?? Future<void>.value());
    _refreshFuture = operation;
    void clearPending() {
      if (identical(_refreshFuture, operation)) _refreshFuture = null;
    }

    unawaited(
      operation.then<void>(
        (_) => clearPending(),
        onError: (Object _, StackTrace _) => clearPending(),
      ),
    );
    return operation;
  }

  Future<void> _stopListening() async {
    _finishSearch();
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _running = false;
    _advertise = false;
    _self = null;
    _networkSignature = '';
    _interfaces = const [];
    _candidates.clear();
    await _subscription?.cancel();
    _subscription = null;
    await _departureSubscription?.cancel();
    _departureSubscription = null;
    await _service?.stop();
    if (ref.mounted) state = const [];
  }

  Future<void> stop() => _serialize(() async {
    await _stopListening();
    if (ref.mounted) _setStatus(DiscoveryPhase.idle);
  });
}

final incomingTransfersProvider =
    NotifierProvider<IncomingTransfersController, List<IncomingTransfer>>(
      IncomingTransfersController.new,
    );

class IncomingTransfersController extends Notifier<List<IncomingTransfer>> {
  final Set<Completer<bool>> _pendingDecisions = {};

  @override
  List<IncomingTransfer> build() {
    ref.onDispose(() {
      for (final decision in _pendingDecisions.toList()) {
        if (!decision.isCompleted) decision.complete(false);
      }
    });
    return const [];
  }

  Future<bool> requestDecision(IncomingTransfer transfer) async {
    _pendingDecisions.add(transfer.decision);
    state = [...state, transfer];
    try {
      return await transfer.decision.future;
    } finally {
      _pendingDecisions.remove(transfer.decision);
      if (ref.mounted) {
        state = state.where((item) => item.id != transfer.id).toList();
      }
    }
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
    cameraExecution: ref.watch(androidCameraExecutionProvider),
    onSharingStopped: () async {
      if (ref.mounted) {
        try {
          await ref.read(cameraDisplayServiceProvider).stop();
        } finally {
          await ref
              .read(receiveControllerProvider.notifier)
              .stopIfScreenShareOnly();
        }
      }
    },
  );
  ref.onDispose(service.dispose);
  return service;
});

final androidCameraExecutionProvider = Provider(
  (ref) => AndroidCameraExecutionService(),
);

final cameraDisplayServiceProvider = Provider((ref) {
  final service = CameraDisplayService();
  ref.onDispose(service.dispose);
  return service;
});

final cameraDevicesProvider = FutureProvider<List<CameraDevice>>(
  (ref) => ref.read(screenShareServiceProvider).enumerateCameras(),
);

final usbCameraNetworkServiceProvider = Provider(
  (ref) => UsbCameraNetworkService(),
);
final usbAdbTransportServiceProvider = Provider(
  (ref) => UsbAdbTransportService(),
);
final usbAdbDevicesProvider = FutureProvider<List<UsbAdbDevice>>(
  (ref) => ref.read(usbAdbTransportServiceProvider).listDevices(),
  retry: (retryCount, error) => null,
);
final usbCameraNetworkProvider = FutureProvider<UsbCameraNetworkSnapshot>(
  (ref) => ref.read(usbCameraNetworkServiceProvider).snapshot(),
);
final cameraSessionProvider =
    NotifierProvider<CameraSessionController, CameraSessionState>(
      CameraSessionController.new,
    );

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
  RuntimeCleanup(this._ref);

  final Ref _ref;
  Future<void> _operation = Future<void>.value();
  final Map<({bool cancelTransfers, bool cleanupSelectedFiles}), Future<void>>
  _pending = {};

  Future<void> cleanupNetworking({
    bool cancelTransfers = true,
    bool cleanupSelectedFiles = false,
  }) {
    final key = (
      cancelTransfers: cancelTransfers,
      cleanupSelectedFiles: cleanupSelectedFiles,
    );
    final existing = _pending[key];
    if (existing != null) return existing;
    late final Future<void> operation;
    operation = _operation
        .then(
          (_) => _cleanupNetworking(
            cancelTransfers: cancelTransfers,
            cleanupSelectedFiles: cleanupSelectedFiles,
          ),
        )
        .whenComplete(() {
          _pending.remove(key);
        });
    _pending[key] = operation;
    _operation = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return operation;
  }

  Future<void> _cleanupNetworking({
    required bool cancelTransfers,
    required bool cleanupSelectedFiles,
  }) async {
    final logger = _ref.read(loggerProvider);
    Future<void> attempt(String step, FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error) {
        logger.warn('Could not clean up $step: $error');
      }
    }

    if (cancelTransfers) {
      await attempt('outgoing transfers', () async {
        final selectedFiles = _ref.read(pickedFilesProvider);
        await _ref
            .read(sendControllerProvider)
            .dispose(
              cleanupSelectedFiles: cleanupSelectedFiles,
              selectedFiles: selectedFiles,
            );
      });
      if (cleanupSelectedFiles) {
        await attempt(
          'selected files',
          () => _ref.read(pickedFilesProvider.notifier).clear(),
        );
      }
      await attempt('outgoing controls', () {
        for (final control in _ref.read(transferControlProvider).values) {
          control.cancel();
        }
        _ref.read(transferControlProvider.notifier).clear();
      });
      await attempt(
        'incoming decisions',
        () => _ref.read(incomingTransfersProvider.notifier).rejectAll(),
      );
      await attempt('incoming controls', () {
        for (final control
            in _ref.read(receiveTransferControlProvider).values) {
          control.cancel();
        }
      });
    }
    await attempt(
      'screen sharing',
      () => _ref
          .read(screenShareServiceProvider)
          .stop(_ref.read(fileServerProvider)),
    );
    await attempt(
      'camera display',
      () => _ref.read(cameraDisplayServiceProvider).stop(),
    );
    await attempt('receiver', () async {
      await _ref
          .read(receiveControllerProvider.notifier)
          .stop(force: cancelTransfers);
    });
    if (cancelTransfers) {
      // Also close the listener when a controller cleanup step has failed.
      await attempt(
        'HTTP receiver',
        () => _ref.read(fileServerProvider).stop(),
      );
    }
    await attempt(
      'discovery',
      () => _ref.read(discoveryProvider.notifier).stop(),
    );
    await attempt(
      'discovery socket',
      () => _ref.read(discoveryServiceProvider).stop(),
    );
    await attempt(
      'hotspot',
      () => _ref.read(directNetworkServiceProvider).stopLocalOnlyHotspot(),
    );
    await attempt(
      'Wi-Fi binding',
      () => _ref.read(directNetworkServiceProvider).disconnectWifi(),
    );
    if (cancelTransfers) {
      await attempt(
        'sending foreground execution',
        () => _ref
            .read(androidBackgroundExecutionProvider)
            .release(BackgroundExecutionOwner.fileSending),
      );
      await attempt(
        'receiving foreground execution',
        () => _ref
            .read(androidBackgroundExecutionProvider)
            .release(BackgroundExecutionOwner.fileReceiving),
      );
      await attempt(
        'screen capture execution',
        () => _ref.read(androidScreenShareExecutionProvider).stop(),
      );
      await attempt(
        'camera capture execution',
        () => _ref.read(androidCameraExecutionProvider).stop(),
      );
      await attempt(
        'send progress',
        () => _ref.read(sendProgressProvider.notifier).clear(),
      );
      await attempt(
        'receive progress',
        () => _ref.read(receiveProgressProvider.notifier).clear(),
      );
      await attempt(
        'receive controls',
        () => _ref.read(receiveTransferControlProvider.notifier).clear(),
      );
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
