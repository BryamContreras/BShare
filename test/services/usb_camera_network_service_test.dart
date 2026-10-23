import 'dart:io';

import 'package:bshare/src/infrastructure/services/process_runner.dart';
import 'package:bshare/src/infrastructure/services/usb_camera_network_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Runner extends ProcessRunner {
  _Runner(this.output, {this.exitCode = 0});

  final String output;
  final int exitCode;
  final calls = <String>[];

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    Map<String, String>? environment,
  }) async {
    calls.add(executable);
    return ProcessResult(1, exitCode, output, '');
  }
}

void main() {
  test('IPv4 membership uses all prefix bits including partial octets', () {
    const address = UsbCameraAddress(
      ip: '172.21.48.1',
      prefixLength: 20,
      interfaceName: 'rndis0',
    );
    expect(address.containsRemote('172.21.48.2'), isTrue);
    expect(address.containsRemote('172.21.63.254'), isTrue);
    expect(address.containsRemote(' 172.21.51.8 '), isTrue);
    expect(address.containsRemote('172.21.47.254'), isFalse);
    expect(address.containsRemote('172.21.64.1'), isFalse);
    expect(address.containsRemote('192.168.1.2'), isFalse);
    expect(address.containsRemote(address.ip), isFalse);

    const narrow = UsbCameraAddress(
      ip: '192.168.42.130',
      prefixLength: 25,
      interfaceName: 'usb0',
    );
    expect(narrow.containsRemote('192.168.42.129'), isTrue);
    expect(narrow.containsRemote('192.168.42.127'), isFalse);
    expect(narrow.containsRemote('192.168.42.2'), isFalse);
  });

  test(
    'invalid address families, self, multicast, loopback and prefixes are rejected',
    () {
      const address = UsbCameraAddress(
        ip: '192.168.42.1',
        prefixLength: 24,
        interfaceName: 'rndis0',
      );
      for (final remote in [
        '192.168.42.1',
        'not-an-ip',
        '',
        '::1',
        '::ffff:192.168.42.2',
        '0.0.0.0',
        '127.0.0.2',
        '224.0.0.1',
      ]) {
        expect(address.containsRemote(remote), isFalse, reason: remote);
      }
      for (final prefix in [-1, 0, 33]) {
        expect(
          UsbCameraAddress(
            ip: address.ip,
            prefixLength: prefix,
            interfaceName: 'rndis0',
          ).containsRemote('192.168.42.2'),
          isFalse,
        );
      }
    },
  );

  test('/31 handles the peer and /32 never permits a different address', () {
    const address = UsbCameraAddress(
      ip: '192.168.42.0',
      prefixLength: 31,
      interfaceName: 'rndis0',
    );
    expect(address.containsRemote('192.168.42.1'), isTrue);
    expect(address.containsRemote('192.168.42.2'), isFalse);
    expect(
      const UsbCameraAddress(
        ip: '192.168.42.1',
        prefixLength: 32,
        interfaceName: 'rndis0',
      ).containsRemote('192.168.42.2'),
      isFalse,
    );
  });

  test(
    'snapshot ignores malformed entries and de-duplicates real interface addresses',
    () async {
      final service = UsbCameraNetworkService(
        readAddresses: () async => [
          null,
          'invalid',
          {},
          {'ip': 7, 'prefixLength': 24, 'interfaceName': 'rndis0'},
          {
            'ip': '192.168.42.1',
            'prefixLength': '24',
            'interfaceName': 'rndis0',
          },
          {'ip': '192.168.42.1', 'prefixLength': 0, 'interfaceName': 'rndis0'},
          {'ip': '192.168.42.1', 'prefixLength': 33, 'interfaceName': 'rndis0'},
          {'ip': '192.168.42.1', 'prefixLength': 24, 'interfaceName': ''},
          {'ip': '::1', 'prefixLength': 24, 'interfaceName': 'rndis0'},
          {'ip': '127.0.0.1', 'prefixLength': 8, 'interfaceName': 'rndis0'},
          {'ip': '0.0.0.0', 'prefixLength': 24, 'interfaceName': 'rndis0'},
          {'ip': '224.0.0.1', 'prefixLength': 24, 'interfaceName': 'rndis0'},
          {'ip': '192.168.42.1', 'prefixLength': 24, 'interfaceName': 'rndis0'},
          {'ip': '192.168.42.1', 'prefixLength': 24, 'interfaceName': 'usb0'},
          {'ip': '192.168.88.1', 'prefixLength': 28, 'interfaceName': 'usb1'},
        ],
      );
      final snapshot = await service.snapshot();
      expect(snapshot.localIps, ['192.168.42.1', '192.168.88.1']);
      expect(snapshot.remoteSubnets, ['192.168.42.1/24', '192.168.88.1/28']);
      expect(snapshot.containsRemote('192.168.42.2'), isTrue);
      expect(snapshot.containsRemote('192.168.88.2'), isTrue);
      expect(snapshot.containsRemote('172.21.53.37'), isFalse);
      expect(() => snapshot.addresses.clear(), throwsUnsupportedError);
    },
  );

  test(
    'an absent USB interface stays absent and enumeration errors propagate',
    () async {
      final empty = await UsbCameraNetworkService(
        readAddresses: () async => [],
      ).snapshot();
      expect(empty.localIps, isEmpty);
      expect(empty.containsRemote('172.21.53.37'), isFalse);
      await expectLater(
        UsbCameraNetworkService(
          readAddresses: () async => throw StateError('permission denied'),
        ).snapshot(),
        throwsStateError,
      );
    },
  );

  test(
    'Linux enumeration never falls back to Wi-Fi or loopback from ip output',
    () async {
      if (!Platform.isLinux) return;
      final runner = _Runner('''[
      {"ifname":"lo","addr_info":[{"family":"inet","local":"127.0.0.1","prefixlen":8}]},
      {"ifname":"wlan0","addr_info":[{"family":"inet","local":"172.21.53.37","prefixlen":24}]},
      {"ifname":"../wlan0","addr_info":[{"family":"inet","local":"172.21.53.37","prefixlen":24}]}
    ]''');
      final snapshot = await UsbCameraNetworkService(runner: runner).snapshot();
      expect(snapshot.addresses, isEmpty);
      expect(runner.calls, ['ip']);
    },
  );

  test(
    'Linux malformed command output or command failure is surfaced',
    () async {
      if (!Platform.isLinux) return;
      await expectLater(
        UsbCameraNetworkService(runner: _Runner('{invalid')).snapshot(),
        throwsFormatException,
      );
      await expectLater(
        UsbCameraNetworkService(runner: _Runner('', exitCode: 1)).snapshot(),
        throwsStateError,
      );
    },
  );
}
