import 'dart:convert';

import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/domain/entities/direct_share_invite.dart';
import 'package:flutter_test/flutter_test.dart';

final _invite = DirectShareInvite(
  credentials: const DirectNetworkCredentials(
    ssid: 'BShare-ABC123',
    password: 'aBcd2345!678',
  ),
  device: DeviceInfo(
    id: 'receiver-id',
    name: 'Receiver',
    platform: 'linux',
    ip: '192.168.49.1',
    port: 53317,
    lastSeen: DateTime.utc(2026, 10, 21),
  ),
);

void main() {
  test('QR invitations preserve credentials and receiver information', () {
    final restored = DirectShareInvite.decode(_invite.encode());
    expect(restored.encode(), _invite.encode());
  });

  test('legacy version-one invitations and IPv6 addresses remain valid', () {
    final json = jsonDecode(_invite.encode()) as Map<String, dynamic>;
    json.remove('version');
    (json['device'] as Map<String, dynamic>)['ip'] = 'fd00::1234';
    expect(DirectShareInvite.decode(jsonEncode(json)).device.ip, 'fd00::1234');
  });

  test('open networks do not require a Wi-Fi password', () {
    final json = jsonDecode(_invite.encode()) as Map<String, dynamic>;
    json['network'] = {
      'ssid': 'BShare-open',
      'password': '',
      'securityType': 'OPEN',
    };
    expect(DirectShareInvite.decode(jsonEncode(json)).credentials.password, '');
  });

  test(
    'non-BShare and malformed QR data consistently report FormatException',
    () {
      for (final value in ['https://example.com', 'null', '[]', '42', '{}']) {
        expect(() => DirectShareInvite.decode(value), throwsFormatException);
      }
    },
  );

  test('rejects invalid version, network credentials and receiver address', () {
    final mutations = <void Function(Map<String, dynamic>)>[
      (json) => json['version'] = 2,
      (json) => json['version'] = 1.0,
      (json) => json['network'] = null,
      (json) => json['device'] = [],
      (json) => json['network']['ssid'] = '',
      (json) => json['network']['ssid'] = 'á' * 17,
      (json) => json['network']['password'] = 'short',
      (json) => json['network']['securityType'] = 'unknown',
      (json) => json['device']['id'] = '',
      (json) => json['device']['ip'] = 'http://192.168.49.1',
      (json) => json['device']['ip'] = '999.999.999.999',
      (json) => json['device']['port'] = 0,
      (json) => json['device']['port'] = 65536,
      (json) => json['device']['port'] = 53317.5,
      (json) => json['device']['lastSeen'] = 123,
    ];
    for (var index = 0; index < mutations.length; index++) {
      final json = jsonDecode(_invite.encode()) as Map<String, dynamic>;
      mutations[index](json);
      expect(
        () => DirectShareInvite.decode(jsonEncode(json)),
        throwsFormatException,
        reason: 'invalid QR field mutation $index',
      );
    }
  });
}
