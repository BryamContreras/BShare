import 'dart:io';

import 'package:bshare/src/infrastructure/services/network_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Interface implements NetworkInterface {
  _Interface(this.name, String address)
    : addresses = [InternetAddress(address)];
  @override
  final String name;
  @override
  final List<InternetAddress> addresses;
  @override
  int get index => 1;
}

void main() {
  NetworkService service({
    required String os,
    String? wifiIp,
    bool wifiAvailable = true,
    required List<NetworkInterface> interfaces,
  }) => NetworkService(
    operatingSystem: os,
    readWifiIp: () async => wifiIp,
    readWifiName: () async => null,
    hasWifiNetwork: () async => wifiAvailable,
    listInterfaces: () async => interfaces,
  );

  for (final os in ['windows', 'linux', 'macos']) {
    test('$os discovers wired LAN when Wi-Fi plugin has no address', () async {
      final network = await service(
        os: os,
        interfaces: [
          _Interface('vEthernet (WSL)', '172.20.0.1'),
          _Interface('docker0', '172.17.0.1'),
          _Interface('Ethernet', '192.168.1.12'),
        ],
      ).snapshot();
      expect(network.ip, '192.168.1.12');
      expect(network.isConnected, isTrue);
    });
  }

  test('Windows Ethernet can use a localized or renamed adapter', () async {
    final network = await service(
      os: 'windows',
      interfaces: [_Interface('Conexión de oficina', '192.168.10.14')],
    ).snapshot();
    expect(network.ip, '192.168.10.14');
  });

  for (final invalid in [
    '0.0.0.0',
    'not-an-ip',
    '127.0.0.1',
    '224.0.0.251',
    '::1',
  ]) {
    test('invalid Wi-Fi address $invalid falls back to physical LAN', () async {
      final network = await service(
        os: 'windows',
        wifiIp: invalid,
        interfaces: [_Interface('Ethernet', '192.168.1.12')],
      ).snapshot();
      expect(network.ip, '192.168.1.12');
    });
  }

  test(
    'Android reads Wi-Fi interface when vendor Wi-Fi IP API is empty',
    () async {
      final network = await service(
        os: 'android',
        interfaces: [
          _Interface('rmnet_data0', '10.0.0.1'),
          _Interface('wlan0', '192.168.1.15'),
        ],
      ).snapshot();
      expect(network.ip, '192.168.1.15');
    },
  );

  test('Android never treats cellular data alone as a Wi-Fi LAN', () async {
    final network = await service(
      os: 'android',
      wifiAvailable: false,
      wifiIp: '192.168.1.15',
      interfaces: [_Interface('rmnet_data0', '10.0.0.1')],
    ).snapshot();
    expect(network.isConnected, isFalse);
  });

  test('preferred Wi-Fi address does not enumerate other adapters', () async {
    final network = await NetworkService(
      operatingSystem: 'windows',
      readWifiIp: () async => '192.168.1.20',
      readWifiName: () async => 'LAN',
      listInterfaces: () => throw StateError('unneeded enumeration'),
    ).snapshot();
    expect(network.ip, '192.168.1.20');
  });
}
