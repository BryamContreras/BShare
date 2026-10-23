import 'dart:io';

import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/lan_discovery_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
