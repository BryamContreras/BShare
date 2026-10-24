import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/lan_discovery_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final self = DeviceInfo(
    id: 'local',
    name: 'Local',
    platform: 'test',
    ip: '127.0.0.1',
    port: 53317,
    lastSeen: DateTime.now(),
  );

  Future<RawDatagramSocket> probe() async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(socket.close);
    return socket;
  }

  void send(RawDatagramSocket socket, Map<String, dynamic> packet) {
    socket.send(
      utf8.encode(jsonEncode(packet)),
      InternetAddress.loopbackIPv4,
      LanDiscoveryService.multicastPort,
    );
  }

  test('concurrent starts and stop release all discovery sockets', () async {
    final service = LanDiscoveryService(const AppLogger());
    addTearDown(service.dispose);
    final self = DeviceInfo(
      id: 'local',
      name: 'Local',
      platform: 'test',
      ip: '127.0.0.1',
      port: 53317,
      lastSeen: DateTime.now(),
    );
    await Future.wait(
      List.generate(12, (_) => service.start(self, advertise: false)),
    );
    await service.stop();
    final exclusiveSocket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      LanDiscoveryService.multicastPort,
      reuseAddress: false,
      reusePort: false,
    );
    exclusiveSocket.close();
    await service.dispose();
    await expectLater(service.start(self, advertise: false), throwsStateError);
  });

  test(
    'LAN packet source replaces stale or other-adapter advertised IP',
    () async {
      final service = LanDiscoveryService(const AppLogger());
      addTearDown(service.dispose);
      await service.start(self, advertise: false);
      final socket = await probe();
      final received = service.devices.first.timeout(
        const Duration(seconds: 2),
      );
      send(socket, {
        ...self.toJson(),
        'id': 'remote',
        'ip': '10.10.99.1',
        'service': LanDiscoveryService.serviceType,
      });
      final device = await received;
      expect(device.ip, '127.0.0.1');
      expect(device.port, self.port);
    },
  );

  test(
    'query receives a unicast announcement without multicast reception',
    () async {
      final service = LanDiscoveryService(const AppLogger());
      addTearDown(service.dispose);
      await service.start(self, advertise: true);
      final socket = await probe();
      final response = Completer<Map<String, dynamic>>();
      final subscription = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram != null && !response.isCompleted) {
          response.complete(
            jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>,
          );
        }
      });
      addTearDown(subscription.cancel);
      send(socket, {
        'id': 'querying-viewer',
        'service': LanDiscoveryService.queryServiceType,
      });
      final result = await response.future.timeout(const Duration(seconds: 2));
      expect(result['id'], self.id);
      expect(result['service'], LanDiscoveryService.serviceType);
      expect(result['port'], self.port);
    },
  );

  test('query can request a persistent reply port', () async {
    final service = LanDiscoveryService(const AppLogger());
    addTearDown(service.dispose);
    await service.start(self, advertise: true);
    final querySender = await probe();
    final replyListener = await probe();
    final response = Completer<Map<String, dynamic>>();
    final subscription = replyListener.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = replyListener.receive();
      if (datagram != null && !response.isCompleted) {
        response.complete(
          jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>,
        );
      }
    });
    addTearDown(subscription.cancel);
    send(querySender, {
      'id': 'querying-viewer',
      'service': LanDiscoveryService.queryServiceType,
      'replyPort': replyListener.port,
    });
    expect(
      (await response.future.timeout(const Duration(seconds: 2)))['id'],
      self.id,
    );
  });

  test('outbound queries request replies on the discovery listener', () async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: true,
    );
    final loopback = interfaces.firstWhere(
      (interface) => interface.addresses.any((address) => address.isLoopback),
    );
    final observer = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      LanDiscoveryService.multicastPort,
      reuseAddress: true,
      reusePort: true,
    );
    addTearDown(observer.close);
    observer.joinMulticast(LanDiscoveryService.multicastAddress, loopback);
    final queried = Completer<Map<String, dynamic>>();
    final subscription = observer.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? packet;
      while ((packet = observer.receive()) != null) {
        final message =
            jsonDecode(utf8.decode(packet!.data)) as Map<String, dynamic>;
        if (message['id'] == self.id &&
            message['service'] == LanDiscoveryService.queryServiceType &&
            !queried.isCompleted) {
          expect(packet.port, isNot(LanDiscoveryService.multicastPort));
          queried.complete(message);
        }
      }
    });
    addTearDown(subscription.cancel);
    final service = LanDiscoveryService(const AppLogger());
    addTearDown(service.dispose);
    await service.start(self, advertise: false);
    final query = await queried.future.timeout(const Duration(seconds: 2));
    expect(query['replyPort'], LanDiscoveryService.multicastPort);
    // Stop the observer so it cannot compete with the service for the unicast
    // packet on the shared port.
    observer.close();
    await subscription.cancel();
    final sender = await probe();
    final device = service.devices.first.timeout(const Duration(seconds: 2));
    sender.send(
      utf8.encode(
        jsonEncode({
          ...self.toJson(),
          'id': 'query-response',
          'service': LanDiscoveryService.serviceType,
        }),
      ),
      InternetAddress.loopbackIPv4,
      query['replyPort'] as int,
    );
    expect((await device).id, 'query-response');
  });

  test(
    'duplicate transport packets emit once and malformed packet does not stop discovery',
    () async {
      final service = LanDiscoveryService(const AppLogger());
      addTearDown(service.dispose);
      await service.start(self, advertise: false);
      final socket = await probe();
      final devices = <DeviceInfo>[];
      final received = Completer<void>();
      final subscription = service.devices.listen((device) {
        devices.add(device);
        if (!received.isCompleted) received.complete();
      });
      addTearDown(subscription.cancel);
      final packet = {
        ...self.toJson(),
        'id': 'remote',
        'service': LanDiscoveryService.serviceType,
      };
      send(socket, {...packet, 'port': 70000});
      send(socket, packet);
      send(socket, packet);
      await received.future.timeout(const Duration(seconds: 2));
      // The read handler drains all datagrams in one event.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(devices, hasLength(1));
      expect(devices.single.port, self.port);
    },
  );

  test(
    'Android multicast lock is paired across restart, stop and dispose',
    () async {
      const channel = MethodChannel('bshare/discovery');
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => calls.add(call.method),
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final service = LanDiscoveryService(const AppLogger(), isAndroid: true);
      addTearDown(service.dispose);
      await service.start(self, advertise: true);
      await service.start(self, advertise: false);
      await service.stop();
      await service.dispose();
      expect(calls, [
        'acquireMulticast',
        'releaseMulticast',
        'acquireMulticast',
        'releaseMulticast',
      ]);
    },
  );

  test('failed UDP bind releases the Android multicast lock', () async {
    const channel = MethodChannel('bshare/discovery');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => calls.add(call.method),
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final occupied = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      LanDiscoveryService.multicastPort,
      reuseAddress: false,
      reusePort: false,
    );
    addTearDown(occupied.close);
    final service = LanDiscoveryService(const AppLogger(), isAndroid: true);
    addTearDown(service.dispose);
    await expectLater(
      service.start(self, advertise: true),
      throwsA(isA<SocketException>()),
    );
    await service.dispose();
    expect(calls, ['acquireMulticast', 'releaseMulticast']);
  });

  test(
    'unavailable Android multicast lock keeps fallback discovery usable',
    () async {
      const channel = MethodChannel('bshare/discovery');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'multicast_unavailable');
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final service = LanDiscoveryService(const AppLogger(), isAndroid: true);
      addTearDown(service.dispose);
      await service.start(self, advertise: false);
      final socket = await probe();
      final received = service.devices.first.timeout(
        const Duration(seconds: 2),
      );
      send(socket, {
        ...self.toJson(),
        'id': 'remote',
        'service': LanDiscoveryService.serviceType,
      });
      expect((await received).id, 'remote');
    },
  );

  test(
    'late goodbye cannot remove a new session at the same endpoint',
    () async {
      final service = LanDiscoveryService(const AppLogger());
      addTearDown(service.dispose);
      await service.start(self, advertise: false);
      final socket = await probe();
      final packet = {
        ...self.toJson(),
        'id': 'remote',
        'service': LanDiscoveryService.serviceType,
      };
      final first = service.devices.first.timeout(const Duration(seconds: 2));
      send(socket, {...packet, 'session': 'previous-listener'});
      await first;
      final second = service.devices.first.timeout(const Duration(seconds: 2));
      send(socket, {...packet, 'session': 'new-listener'});
      await second;
      final departures = <DeviceInfo>[];
      final removed = Completer<void>();
      final subscription = service.departures.listen((device) {
        departures.add(device);
        if (!removed.isCompleted) removed.complete();
      });
      addTearDown(subscription.cancel);
      send(socket, {
        ...packet,
        'service': LanDiscoveryService.goodbyeServiceType,
        'session': 'previous-listener',
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(departures, isEmpty);
      send(socket, {
        ...packet,
        'service': LanDiscoveryService.goodbyeServiceType,
        'session': 'new-listener',
      });
      await removed.future.timeout(const Duration(seconds: 2));
      expect(departures.single.id, 'remote');
      expect(departures.single.ip, '127.0.0.1');
    },
  );

  test('stopping an advertiser sends its session goodbye over UDP', () async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: true,
    );
    final loopback = interfaces.firstWhere(
      (interface) => interface.addresses.any((address) => address.isLoopback),
    );
    final observer = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      LanDiscoveryService.multicastPort,
      reuseAddress: true,
      reusePort: true,
    );
    addTearDown(observer.close);
    observer.joinMulticast(LanDiscoveryService.multicastAddress, loopback);
    final announced = Completer<String>();
    final departed = Completer<String>();
    final senderPorts = <int>{};
    final subscription = observer.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? packet;
      while ((packet = observer.receive()) != null) {
        final message =
            jsonDecode(utf8.decode(packet!.data)) as Map<String, dynamic>;
        if (message['id'] != self.id) continue;
        senderPorts.add(packet.port);
        if (message['service'] == LanDiscoveryService.serviceType &&
            !announced.isCompleted) {
          announced.complete(message['session'] as String);
        }
        if (message['service'] == LanDiscoveryService.goodbyeServiceType &&
            !departed.isCompleted) {
          departed.complete(message['session'] as String);
        }
      }
    });
    addTearDown(subscription.cancel);
    final service = LanDiscoveryService(const AppLogger());
    addTearDown(service.dispose);
    await service.start(self, advertise: true);
    final session = await announced.future.timeout(const Duration(seconds: 2));
    await service.stop();
    expect(await departed.future.timeout(const Duration(seconds: 2)), session);
    expect(senderPorts, isNotEmpty);
    for (final port in senderPorts) {
      final released = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: false,
        reusePort: false,
      );
      released.close();
    }
  });
}
