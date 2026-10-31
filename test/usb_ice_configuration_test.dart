import 'package:bshare/src/infrastructure/services/usb_ice_configuration.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _configuration({
  String url = 'turn:127.0.0.1:43123?transport=tcp',
  Object username = 'test_user_12345678',
  Object credential = 'test_password_12345678',
}) => {
  'iceTransportPolicy': 'relay',
  'iceServers': [
    {
      'urls': [url],
      'username': username,
      'credential': credential,
    },
  ],
};

void main() {
  test(
    'USB ICE uses one authenticated loopback TURN/TCP server and fixed policy',
    () {
      final supplied = _configuration()
        ..['sdpSemantics'] = 'plan-b'
        ..['bundlePolicy'] = 'balanced'
        ..['untrustedOption'] = true;
      final validated = UsbIceConfiguration.validate(supplied);
      expect(validated, {
        ..._configuration(),
        'sdpSemantics': 'unified-plan',
        'bundlePolicy': 'max-bundle',
        'rtcpMuxPolicy': 'require',
      });
      expect(supplied['sdpSemantics'], 'plan-b');
      expect(validated, isNot(same(supplied)));
    },
  );

  test(
    'USB ICE rejects network redirects, alternate transports and invalid credentials',
    () {
      final invalid = <Object?>[
        null,
        _configuration()..['iceTransportPolicy'] = 'all',
        _configuration()..remove('iceTransportPolicy'),
        _configuration()..['iceServers'] = [],
        _configuration()
          ..['iceServers'] = [
            (_configuration()['iceServers'] as List).single,
            (_configuration()['iceServers'] as List).single,
          ],
        for (final url in [
          'stun:127.0.0.1:43123',
          'turn:192.168.1.20:43123?transport=tcp',
          'turn:localhost:43123?transport=tcp',
          'turn:[::1]:43123?transport=tcp',
          'turn:127.0.0.1:43123?transport=udp',
          'turn:127.0.0.1:0?transport=tcp',
          'turn:127.0.0.1:65536?transport=tcp',
          'turn:127.0.0.1:43123?transport=tcp&other=true',
        ])
          _configuration(url: url),
        _configuration(username: 'short'),
        _configuration(username: 'x' * 129),
        _configuration(credential: 'has spaces 1234567890'),
        _configuration(credential: 1234567890123456),
      ];
      for (var index = 0; index < invalid.length; index++) {
        expect(
          () => UsbIceConfiguration.validate(invalid[index]),
          throwsFormatException,
          reason: 'Unsafe USB ICE configuration at index $index',
        );
      }
    },
  );

  test(
    'USB SDP retains loopback relay candidates and removes LAN fallback paths',
    () {
      const relay =
          'a=candidate:relay 1 udp 1677734911 127.0.0.1 44000 typ relay raddr 127.0.0.1 rport 43000';
      final filtered = UsbIceConfiguration.relaySdp(
        [
          'v=0',
          'm=video 9 UDP/TLS/RTP/SAVPF 96',
          'c=IN IP4 192.168.1.20',
          'a=mid:0',
          'a=candidate:lan 1 udp 2122260223 192.168.1.20 55000 typ host',
          'a=candidate:local 1 udp 2122260223 127.0.0.1 55001 typ host',
          'a=candidate:srflx 1 udp 1686052607 203.0.113.20 55002 typ srflx',
          'a=candidate:other-relay 1 udp 1677734911 192.168.1.21 55003 typ relay',
          'a=candidate:ipv6 1 udp 1677734911 ::1 55004 typ relay',
          'a=remote-candidates:1 192.168.1.20 55000',
          relay,
          'a=end-of-candidates',
          '',
        ].join('\n'),
      );
      final lines = filtered.split('\r\n');
      expect(lines.where((line) => line.startsWith('a=candidate:')), [relay]);
      expect(
        lines,
        containsAll(['c=IN IP4 127.0.0.1', 'a=mid:0', 'a=end-of-candidates']),
      );
      expect(filtered, isNot(contains('192.168.')));
      expect(filtered, isNot(contains('203.0.113.')));
      expect(filtered, isNot(contains('a=remote-candidates:')));
    },
  );

  test(
    'USB SDP with no usable loopback relay fails instead of falling back',
    () {
      for (final sdp in [
        'v=0\r\nc=IN IP6 ::\r\n',
        'a=candidate:lan 1 udp 1 192.168.1.20 44000 typ relay\r\n',
        'a=candidate:local 1 udp 1 127.0.0.1 44000 typ host\r\n',
        'a=candidate:malformed 1 udp\r\n',
      ]) {
        expect(() => UsbIceConfiguration.relaySdp(sdp), throwsStateError);
      }
    },
  );
}
