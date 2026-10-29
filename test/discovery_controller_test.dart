import 'dart:async';
import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/app_settings.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/lan_discovery_service.dart';
import 'package:bshare/src/infrastructure/services/network_service.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Settings extends SettingsController {
  @override
  Future<AppSettings> build() async => const AppSettings(
    deviceId: 'device',
    deviceName: 'Device',
    downloadDirectory: '/tmp',
    autoAccept: true,
    preferredPort: 53317,
    themeMode: 'dark',
    languageCode: 'en',
  );
}

class _DiscoveryService extends LanDiscoveryService {
  _DiscoveryService() : super(const AppLogger());
  final events = StreamController<DeviceInfo>.broadcast(sync: true);
  final departureEvents = StreamController<DeviceInfo>.broadcast(sync: true);
  final started = Completer<void>();
  final gate = Completer<void>();
  int starts = 0;
  int stops = 0;
  int queries = 0;
  final advertisements = <bool>[];
  Object? startError;
  void Function()? onStart;
  @override
  Stream<DeviceInfo> get devices => _DiscoveryStream(events.stream);
  @override
  Stream<DeviceInfo> get departures => _DiscoveryStream(departureEvents.stream);
  @override
  Future<void> start(DeviceInfo self, {required bool advertise}) async {
    starts++;
    advertisements.add(advertise);
    if (!started.isCompleted) started.complete();
    await gate.future;
    final error = startError;
    if (error != null) throw error;
    onStart?.call();
  }

  @override
  void requestDiscovery() => queries++;

  @override
  Future<void> stop() {
    stops++;
    final completion = Completer<void>()..complete();
    return completion.future;
  }

  @override
  Future<void> dispose() async {
    await events.close();
    await departureEvents.close();
  }
}

// StreamController.cancel uses a shared Future completed outside FakeAsync.
// Detaching a broadcast listener is synchronous; expose its completion inside
// the test clock. Real UDP lifecycle coverage lives in
// services/lan_discovery_service_test.dart.
class _DiscoveryStream extends Stream<DeviceInfo> {
  _DiscoveryStream(this._stream);
  final Stream<DeviceInfo> _stream;

  @override
  StreamSubscription<DeviceInfo> listen(
    void Function(DeviceInfo)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _DiscoverySubscription(
    _stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    ),
  );
}

class _DiscoverySubscription implements StreamSubscription<DeviceInfo> {
  _DiscoverySubscription(this._subscription);
  final StreamSubscription<DeviceInfo> _subscription;

  @override
  Future<void> cancel() {
    unawaited(_subscription.cancel());
    return (Completer<void>.sync()..complete()).future;
  }

  @override
  bool get isPaused => _subscription.isPaused;
  @override
  void onData(void Function(DeviceInfo)? handleData) =>
      _subscription.onData(handleData);
  @override
  void onDone(void Function()? handleDone) => _subscription.onDone(handleDone);
  @override
  void onError(Function? handleError) => _subscription.onError(handleError);
  @override
  void pause([Future<void>? resumeSignal]) => _subscription.pause(resumeSignal);
  @override
  void resume() => _subscription.resume();
  @override
  Future<E> asFuture<E>([E? futureValue]) =>
      _subscription.asFuture(futureValue);
}

void _flush(FakeAsync time) {
  time.flushMicrotasks();
  time.elapse(Duration.zero);
  time.flushMicrotasks();
}

void _expectCompleted(Future<void> future, FakeAsync time) {
  var completed = false;
  Object? failure;
  unawaited(
    future.then<void>(
      (_) => completed = true,
      onError: (Object error, StackTrace stack) => failure = error,
    ),
  );
  _flush(time);
  expect(failure, isNull);
  expect(completed, isTrue);
}

DeviceInfo _remote(DateTime lastSeen, {String id = 'peer'}) => DeviceInfo(
  id: id,
  name: 'Peer',
  platform: 'test',
  ip: '127.0.0.2',
  port: 53317,
  lastSeen: lastSeen,
);

NetworkSnapshot _multiLanNetwork({
  String secondaryIp = '10.40.0.2',
  int secondaryIndex = 8,
  int secondaryPrefix = 24,
  int secondaryMetric = 30,
}) => NetworkSnapshot(
  ip: '192.168.50.2',
  interfaces: [
    LanInterface(
      name: 'Preferred office connection',
      index: 4,
      addresses: [InternetAddress('192.168.50.2')],
      prefixLengths: const {'192.168.50.2': 24},
      kind: 'ethernet',
      isLan: true,
      hasDefaultRoute: true,
      metric: 10,
    ),
    LanInterface(
      name: 'Secondary connection',
      index: secondaryIndex,
      addresses: [InternetAddress(secondaryIp)],
      prefixLengths: {secondaryIp: secondaryPrefix},
      kind: 'wifi',
      isLan: true,
      hasDefaultRoute: true,
      metric: secondaryMetric,
    ),
  ],
);

void _withDiscovery(
  void Function(
    FakeAsync time,
    _DiscoveryService service,
    ProviderContainer container,
    DiscoveryController controller,
    DateTime Function() now,
  )
  body, {
  NetworkSnapshot network = const NetworkSnapshot(ip: '127.0.0.1'),
  NetworkSnapshot Function()? readNetwork,
}) {
  fakeAsync((time) {
    final service = _DiscoveryService()..gate.complete();
    DateTime now() => DateTime(2026, 1, 1).add(time.elapsed);
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        discoveryServiceProvider.overrideWithValue(service),
        networkProvider.overrideWith(
          (ref) async => readNetwork?.call() ?? network,
        ),
        discoveryProvider.overrideWith(() => DiscoveryController(clock: now)),
      ],
    );
    try {
      body(
        time,
        service,
        container,
        container.read(discoveryProvider.notifier),
        now,
      );
    } finally {
      container.dispose();
      unawaited(service.dispose());
      _flush(time);
      expect(time.nonPeriodicTimerCount, 0);
      expect(time.periodicTimerCount, 0);
    }
  });
}

void main() {
  test(
    'overlapping starts are idempotent and stop leaves no subscription',
    () async {
      final service = _DiscoveryService();
      addTearDown(service.dispose);
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          discoveryServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(discoveryProvider.notifier);
      final first = controller.start(ipOverride: '127.0.0.1');
      await service.started.future;
      final second = controller.start(ipOverride: '127.0.0.1');
      final stopping = controller.stop();
      service.gate.complete();
      await Future.wait([first, second, stopping]);
      expect(service.starts, 1);
      expect(service.stops, 1);
      expect(service.events.hasListener, isFalse);
      expect(container.read(discoveryProvider), isEmpty);
    },
  );

  test(
    'dispose during binding stops the late socket and skips listening',
    () async {
      final service = _DiscoveryService();
      addTearDown(service.dispose);
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          discoveryServiceProvider.overrideWithValue(service),
        ],
      );
      final controller = container.read(discoveryProvider.notifier);
      final starting = controller.start(ipOverride: '127.0.0.1');
      await service.started.future;
      container.dispose();
      service.gate.complete();
      await starting;
      expect(service.stops, 1);
      expect(service.events.hasListener, isFalse);
    },
  );

  test('initial scan finishes and continues receiving announcements', () {
    _withDiscovery((time, service, container, controller, now) {
      _expectCompleted(controller.start(), time);
      expect(container.read(discoveryStatusProvider).isSearching, isTrue);
      time.elapse(const Duration(seconds: 4));
      expect(container.read(discoveryStatusProvider).isSearching, isTrue);
      time.elapse(
        DiscoveryController.searchWindow - const Duration(milliseconds: 4001),
      );
      expect(container.read(discoveryStatusProvider).isSearching, isTrue);
      time.elapse(const Duration(milliseconds: 1));
      final status = container.read(discoveryStatusProvider);
      expect(status.phase, DiscoveryPhase.listening);
      expect(status.lastScanAt, now());
      service.events.add(_remote(now()));
      _flush(time);
      expect(container.read(discoveryProvider), hasLength(1));
      _expectCompleted(controller.stop(), time);
      expect(
        container.read(discoveryStatusProvider).phase,
        DiscoveryPhase.idle,
      );
      expect(service.events.hasListener, isFalse);
    });
  });

  test('refresh coalesces and preserves the listening socket and peers', () {
    _withDiscovery((time, service, container, controller, now) {
      _expectCompleted(controller.start(), time);
      service.events.add(_remote(now()));
      _flush(time);
      final first = controller.refresh();
      final second = controller.refresh();
      expect(identical(first, second), isTrue);
      var finished = false;
      unawaited(first.then((_) => finished = true));
      _flush(time);
      expect(container.read(discoveryProvider), hasLength(1));
      expect(service.starts, 1);
      expect(service.stops, 0);
      expect(service.queries, 1);
      expect(finished, isFalse);
      time.elapse(DiscoveryController.searchWindow);
      _expectCompleted(first, time);
      expect(finished, isTrue);
      expect(
        container.read(discoveryStatusProvider).phase,
        DiscoveryPhase.listening,
      );
      _expectCompleted(controller.stop(), time);
    });
  });

  test('stop completes an awaited refresh and cancels scan timers', () {
    _withDiscovery((time, service, container, controller, now) {
      _expectCompleted(controller.start(), time);
      final refresh = controller.refresh();
      _flush(time);
      _expectCompleted(controller.stop(), time);
      _expectCompleted(refresh, time);
      time.elapse(const Duration(seconds: 30));
      expect(
        container.read(discoveryStatusProvider).phase,
        DiscoveryPhase.idle,
      );
      expect(service.stops, 1);
    });
  });

  test('expired devices disappear without another announcement', () {
    _withDiscovery((time, service, container, controller, now) {
      _expectCompleted(controller.start(), time);
      service.events.add(_remote(now()));
      _flush(time);
      expect(container.read(discoveryProvider), hasLength(1));
      time.elapse(const Duration(seconds: 19));
      expect(container.read(discoveryProvider), hasLength(1));
      time.elapse(const Duration(seconds: 1));
      expect(container.read(discoveryProvider), isEmpty);
      _expectCompleted(controller.stop(), time);
    });
  });

  test('an expired announcement cannot restore an outdated endpoint', () {
    _withDiscovery((time, service, container, controller, now) {
      _expectCompleted(controller.start(), time);
      final outdated = _remote(now());
      service.events.add(outdated);
      time.elapse(const Duration(seconds: 21));
      expect(container.read(discoveryProvider), isEmpty);
      service.events.add(outdated);
      _flush(time);
      expect(container.read(discoveryProvider), isEmpty);
      _expectCompleted(controller.stop(), time);
    });
  });

  test('goodbye removes only the exact endpoint and clears its selection', () {
    _withDiscovery((time, service, container, controller, now) {
      _expectCompleted(controller.start(), time);
      final original = _remote(now());
      final current = original.copyWith(ip: '192.168.1.42', port: 54000);
      container.read(selectedDeviceProvider.notifier).set(current);
      service.events.add(current);
      service.departureEvents.add(original);
      service.departureEvents.add(current.copyWith(port: 53317));
      _flush(time);
      expect(container.read(discoveryProvider).single, same(current));
      expect(container.read(selectedDeviceProvider), same(current));
      service.departureEvents.add(current);
      _flush(time);
      expect(container.read(discoveryProvider), isEmpty);
      expect(container.read(selectedDeviceProvider), isNull);
      _expectCompleted(controller.stop(), time);
      expect(service.departureEvents.hasListener, isFalse);
    });
  });

  test('repeated starts preserve receiver advertisements', () {
    _withDiscovery((time, service, container, controller, now) {
      _expectCompleted(controller.start(advertise: true), time);
      for (var i = 0; i < 8; i++) {
        _expectCompleted(controller.start(), time);
      }
      final refresh = controller.refresh();
      _flush(time);
      expect(service.starts, 1);
      expect(service.advertisements, [true]);
      _expectCompleted(controller.stop(), time);
      _expectCompleted(refresh, time);
    });
  });

  test('first announcement during binding is not lost', () {
    _withDiscovery((time, service, container, controller, now) {
      service.onStart = () => service.events.add(_remote(now()));
      _expectCompleted(controller.start(), time);
      expect(container.read(discoveryProvider), hasLength(1));
      _expectCompleted(controller.stop(), time);
    });
  });

  test(
    'renewed endpoint updates selection without mutating captured targets',
    () {
      _withDiscovery((time, service, container, controller, now) {
        _expectCompleted(controller.start(), time);
        final original = _remote(now());
        container.read(selectedDeviceProvider.notifier).set(original);
        // SendController captures this immutable object before queuing work.
        final inFlightTarget = container.read(selectedDeviceProvider)!;
        final updated = DeviceInfo(
          id: original.id,
          name: 'Renamed peer',
          platform: 'Android',
          ip: '192.168.1.42',
          port: 54000,
          lastSeen: now(),
        );
        service.events.add(updated);
        _flush(time);
        expect(container.read(selectedDeviceProvider), same(updated));
        expect(container.read(discoveryProvider).single, same(updated));
        expect(inFlightTarget.ip, original.ip);
        expect(inFlightTarget.port, original.port);
        expect(inFlightTarget.name, original.name);
        expect(inFlightTarget.platform, original.platform);
        _expectCompleted(controller.stop(), time);
      });
    },
  );

  test('heartbeat alone does not replace the selected destination', () {
    _withDiscovery((time, service, container, controller, now) {
      _expectCompleted(controller.start(), time);
      final selected = _remote(now());
      container.read(selectedDeviceProvider.notifier).set(selected);
      var selectionChanges = 0;
      final listener = container.listen(selectedDeviceProvider, (_, _) {
        selectionChanges++;
      });
      time.elapse(const Duration(seconds: 3));
      service.events.add(selected.copyWith(lastSeen: now()));
      _flush(time);
      expect(container.read(selectedDeviceProvider), same(selected));
      expect(selectionChanges, 0);
      listener.close();
      _expectCompleted(controller.stop(), time);
    });
  });

  test('QR selection survives missing and unrelated announcements', () {
    _withDiscovery((time, service, container, controller, now) {
      _expectCompleted(controller.start(), time);
      final qrTarget = _remote(now(), id: 'qr-target');
      container.read(selectedDeviceProvider.notifier).set(qrTarget);
      service.events.add(_remote(now()));
      _flush(time);
      expect(container.read(selectedDeviceProvider), same(qrTarget));
      time.elapse(const Duration(seconds: 21));
      expect(container.read(discoveryProvider), isEmpty);
      expect(container.read(selectedDeviceProvider), same(qrTarget));
      _expectCompleted(controller.stop(), time);
    });
  });

  test('two LAN announcements keep the preferred endpoint and selection', () {
    _withDiscovery((time, service, container, controller, now) {
      _expectCompleted(controller.start(), time);
      final preferred = _remote(now()).copyWith(ip: '192.168.50.9');
      final alternate = preferred.copyWith(ip: '10.40.0.9');
      container.read(selectedDeviceProvider.notifier).set(preferred);
      service.events.add(preferred);
      for (var index = 0; index < 3; index++) {
        time.elapse(const Duration(seconds: 1));
        service.events.add(alternate.copyWith(lastSeen: now()));
        _flush(time);
        expect(container.read(discoveryProvider).single.ip, preferred.ip);
        expect(container.read(selectedDeviceProvider), same(preferred));
      }
      _expectCompleted(controller.stop(), time);
    }, network: _multiLanNetwork());
  });

  test('a matching secondary LAN wins over an unrelated newer endpoint', () {
    _withDiscovery((time, service, container, controller, now) {
      _expectCompleted(controller.start(), time);
      final reachable = _remote(now()).copyWith(ip: '10.40.0.9');
      service.events.add(reachable);
      time.elapse(const Duration(seconds: 1));
      service.events.add(reachable.copyWith(ip: '172.16.0.9', lastSeen: now()));
      _flush(time);
      expect(container.read(discoveryProvider).single, same(reachable));
      _expectCompleted(controller.stop(), time);
    }, network: _multiLanNetwork());
  });

  test('a departing preferred endpoint falls back to its other live LAN', () {
    _withDiscovery((time, service, container, controller, now) {
      _expectCompleted(controller.start(), time);
      final preferred = _remote(now()).copyWith(ip: '192.168.50.9');
      final alternate = preferred.copyWith(ip: '10.40.0.9');
      service.events.add(alternate);
      service.events.add(preferred);
      container.read(selectedDeviceProvider.notifier).set(preferred);
      service.departureEvents.add(preferred.copyWith(port: 54000));
      _flush(time);
      expect(container.read(discoveryProvider).single, same(preferred));
      service.departureEvents.add(preferred);
      _flush(time);
      expect(container.read(discoveryProvider).single, same(alternate));
      expect(container.read(selectedDeviceProvider), same(alternate));
      _expectCompleted(controller.stop(), time);
    }, network: _multiLanNetwork());
  });

  test('an expired preferred endpoint falls back without losing selection', () {
    _withDiscovery((time, service, container, controller, now) {
      _expectCompleted(controller.start(), time);
      final preferred = _remote(now()).copyWith(ip: '192.168.50.9');
      service.events.add(preferred);
      container.read(selectedDeviceProvider.notifier).set(preferred);
      time.elapse(const Duration(seconds: 10));
      final alternate = preferred.copyWith(ip: '10.40.0.9', lastSeen: now());
      service.events.add(alternate);
      _flush(time);
      expect(container.read(discoveryProvider).single, same(preferred));
      time.elapse(const Duration(seconds: 10));
      _flush(time);
      expect(container.read(discoveryProvider).single, same(alternate));
      expect(container.read(selectedDeviceProvider), same(alternate));
      _expectCompleted(controller.stop(), time);
    }, network: _multiLanNetwork());
  });

  test('a newer address in the same LAN replaces the DHCP endpoint', () {
    _withDiscovery((time, service, container, controller, now) {
      _expectCompleted(controller.start(), time);
      final oldAddress = _remote(now()).copyWith(ip: '192.168.50.9');
      service.events.add(oldAddress);
      container.read(selectedDeviceProvider.notifier).set(oldAddress);
      time.elapse(const Duration(seconds: 2));
      final renewed = oldAddress.copyWith(ip: '192.168.50.19', lastSeen: now());
      service.events.add(renewed);
      // A late announcement with an older timestamp cannot undo the renewal.
      service.events.add(oldAddress);
      service.departureEvents.add(oldAddress);
      _flush(time);
      expect(container.read(discoveryProvider).single, same(renewed));
      expect(container.read(selectedDeviceProvider), same(renewed));
      expect(oldAddress.ip, '192.168.50.9');
      _expectCompleted(controller.stop(), time);
    }, network: _multiLanNetwork());
  });

  test('changed secondary interface facts renew discovery memberships', () {
    var network = _multiLanNetwork();
    _withDiscovery((time, service, container, controller, now) {
      _expectCompleted(controller.start(advertise: true), time);
      expect(service.starts, 1);
      final revisions = [
        _multiLanNetwork(secondaryIp: '10.41.0.2'),
        _multiLanNetwork(secondaryIp: '10.41.0.2', secondaryPrefix: 25),
        _multiLanNetwork(
          secondaryIp: '10.41.0.2',
          secondaryPrefix: 25,
          secondaryMetric: 40,
        ),
        _multiLanNetwork(
          secondaryIp: '10.41.0.2',
          secondaryPrefix: 25,
          secondaryMetric: 40,
          secondaryIndex: 12,
        ),
      ];
      for (var index = 0; index < revisions.length; index++) {
        network = revisions[index];
        final refresh = controller.refresh();
        _flush(time);
        expect(network.ip, '192.168.50.2');
        expect(service.starts, index + 2);
        expect(service.advertisements.last, isTrue);
        time.elapse(DiscoveryController.searchWindow);
        _expectCompleted(refresh, time);
      }
      _expectCompleted(controller.stop(), time);
    }, readNetwork: () => network);
  });

  test('equivalent interface metadata preserves socket and known peers', () {
    var network = _multiLanNetwork();
    _withDiscovery((time, service, container, controller, now) {
      _expectCompleted(controller.start(), time);
      final preferred = _remote(now()).copyWith(ip: '192.168.50.9');
      service.events.add(preferred);
      network = _multiLanNetwork();
      final refresh = controller.refresh();
      _flush(time);
      expect(service.starts, 1);
      expect(service.queries, 1);
      expect(container.read(discoveryProvider).single, same(preferred));
      time.elapse(DiscoveryController.searchWindow);
      _expectCompleted(refresh, time);
      _expectCompleted(controller.stop(), time);
    }, readNetwork: () => network);
  });

  test('discovery candidate storage stays bounded on a noisy network', () {
    _withDiscovery((time, service, container, controller, now) {
      _expectCompleted(controller.start(), time);
      for (var index = 0; index < 520; index++) {
        service.events.add(_remote(now(), id: 'peer-$index'));
      }
      _flush(time);
      expect(container.read(discoveryProvider), hasLength(512));
      expect(
        container
            .read(discoveryProvider)
            .any((device) => device.id == 'peer-0'),
        isFalse,
      );
      expect(
        container
            .read(discoveryProvider)
            .any((device) => device.id == 'peer-519'),
        isTrue,
      );
      _expectCompleted(controller.stop(), time);
    });
  });

  test('binding failures expose error state and can be retried', () {
    _withDiscovery((time, service, container, controller, now) {
      service.startError = StateError('Port unavailable');
      _expectCompleted(controller.start(), time);
      expect(
        container.read(discoveryStatusProvider).phase,
        DiscoveryPhase.error,
      );
      expect(container.read(discoveryStatusProvider).error, isA<StateError>());
      expect(service.events.hasListener, isFalse);
      service.startError = null;
      final retry = controller.refresh();
      _flush(time);
      expect(container.read(discoveryStatusProvider).isSearching, isTrue);
      time.elapse(DiscoveryController.searchWindow);
      _expectCompleted(retry, time);
      expect(
        container.read(discoveryStatusProvider).phase,
        DiscoveryPhase.listening,
      );
      _expectCompleted(controller.stop(), time);
    });
  });

  test('missing local IP reports error without opening a socket', () {
    _withDiscovery((time, service, container, controller, now) {
      _expectCompleted(controller.start(), time);
      expect(
        container.read(discoveryStatusProvider).phase,
        DiscoveryPhase.error,
      );
      expect(service.starts, 0);
      expect(service.events.hasListener, isFalse);
    }, network: const NetworkSnapshot());
  });
}
