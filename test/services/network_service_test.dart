import 'dart:convert';
import 'dart:io';

import 'package:bshare/src/infrastructure/services/network_service.dart';
import 'package:bshare/src/infrastructure/services/process_runner.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

LanInterface _interface(
  String name,
  String? address, {
  int index = 1,
  String kind = 'ethernet',
  bool? isLan = true,
  bool isUp = true,
  bool hasDefaultRoute = false,
  int metric = 100,
  int? prefix = 24,
  bool isHosted = false,
}) => LanInterface(
  name: name,
  index: index,
  addresses: [if (address != null) InternetAddress(address)],
  prefixLengths: {if (address != null && prefix != null) address: prefix},
  kind: kind,
  isLan: isLan,
  isUp: isUp,
  hasDefaultRoute: hasDefaultRoute,
  metric: metric,
  isHosted: isHosted,
);

class _Runner extends ProcessRunner {
  _Runner(this.responses);
  final Map<String, Object> responses;
  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    Map<String, String>? environment,
  }) async {
    final response = responses['$executable ${arguments.join(' ')}'];
    if (response is String) return ProcessResult(1, 0, response, '');
    if (response is List || response is Map) {
      return ProcessResult(1, 0, jsonEncode(response), '');
    }
    return ProcessResult(1, 1, '', 'Unavailable');
  }
}

class _ConnectedSocket extends Fake implements Socket {
  bool destroyed = false;

  @override
  InternetAddress get address => InternetAddress('192.168.3.10');

  @override
  void destroy() => destroyed = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  NetworkService service({
    required String os,
    required List<LanInterface> interfaces,
    String? wifiIp,
    bool wifiAvailable = true,
    Future<String?> Function(String, int)? peerAddress,
  }) => NetworkService(
    operatingSystem: os,
    readWifiIp: () async => wifiIp,
    readWifiName: () async => '"Test Wi-Fi"',
    hasWifiNetwork: () async => wifiAvailable,
    listInterfaces: () async => interfaces,
    readPeerLocalAddress: peerAddress,
  );

  for (final os in ['windows', 'linux', 'macos', 'android']) {
    test('$os accepts renamed Ethernet with Wi-Fi unavailable', () async {
      final snapshot = await service(
        os: os,
        wifiAvailable: false,
        interfaces: [_interface('Conexión de oficina', '192.168.10.14')],
      ).snapshot();
      expect(snapshot.ip, '192.168.10.14');
      expect(snapshot.isConnected, isTrue);
      expect(snapshot.wifiName, isNull);
    });
  }

  for (final address in ['169.254.23.5', '198.51.100.5', '100.64.1.5']) {
    test('LAN without gateway can use $address', () async {
      final snapshot = await service(
        os: 'linux',
        interfaces: [_interface('arbitrary', address)],
      ).snapshot();
      expect(snapshot.ip, address);
    });
  }

  for (final address in [
    '0.0.0.0',
    '127.0.0.1',
    '224.0.0.251',
    '255.255.255.255',
    '::1',
  ]) {
    test('invalid LAN source $address is rejected', () async {
      final snapshot = await service(
        os: 'windows',
        interfaces: [_interface('Link', address)],
      ).snapshot();
      expect(snapshot.isConnected, isFalse);
    });
  }

  test(
    'OS preference selects Ethernet even when Wi-Fi plugin has an IP',
    () async {
      final snapshot = await service(
        os: 'windows',
        wifiIp: '192.168.2.2',
        interfaces: [
          _interface(
            'Wireless renamed',
            '192.168.2.2',
            kind: 'wifi',
            hasDefaultRoute: true,
            metric: 50,
          ),
          _interface(
            'Ethernet renamed',
            '192.168.3.2',
            index: 2,
            hasDefaultRoute: true,
            metric: 10,
          ),
        ],
      ).snapshot();
      expect(snapshot.ip, '192.168.3.2');
      expect(snapshot.wifiName, isNull);
    },
  );

  test('OS preference can select Wi-Fi with a lower route metric', () async {
    final snapshot = await service(
      os: 'linux',
      interfaces: [
        _interface('Cable', '192.168.3.2', hasDefaultRoute: true, metric: 50),
        _interface(
          'Radio',
          '192.168.2.2',
          index: 2,
          kind: 'wifi',
          hasDefaultRoute: true,
          metric: 10,
        ),
      ],
    ).snapshot();
    expect(snapshot.ip, '192.168.2.2');
    expect(snapshot.wifiName, 'Test Wi-Fi');
  });

  test(
    'active hosted link has priority only when explicitly requested',
    () async {
      final network = service(
        os: 'windows',
        interfaces: [
          _interface('Uplink', '192.168.3.2', hasDefaultRoute: true),
          _interface(
            'Hosted',
            '192.168.66.1',
            index: 2,
            kind: 'wifi',
            isHosted: true,
          ),
        ],
      );
      expect((await network.snapshot()).ip, '192.168.3.2');
      expect(
        (await network.snapshot(includeLocalInterfaces: true)).ip,
        '192.168.66.1',
      );
    },
  );

  test(
    'OS metadata overrides misleading names and excludes internal networks',
    () async {
      final links = await service(
        os: 'windows',
        interfaces: [
          _interface(
            'Ethernet',
            '172.28.1.1',
            isLan: false,
            hasDefaultRoute: true,
            metric: 0,
          ),
          _interface('Wi-Fi', '10.8.0.1', isLan: false, kind: 'other'),
          _interface('Unplugged', '192.168.4.1', isUp: false),
          _interface(
            'docker named by user',
            '192.168.3.2',
            index: 9,
            kind: 'bridge',
          ),
        ],
      ).lanInterfaces();
      expect(links.map((link) => link.index), [9]);
    },
  );

  test('empty older Android enumeration keeps confirmed Wi-Fi IP', () async {
    final snapshot = await service(
      os: 'android',
      interfaces: [],
      wifiIp: '192.168.1.20',
    ).snapshot();
    expect(snapshot.ip, '192.168.1.20');
  });

  test(
    'Android fallback never promotes cellular or a stale Wi-Fi IP',
    () async {
      final snapshot = await service(
        os: 'android',
        wifiAvailable: false,
        wifiIp: '192.168.1.20',
        interfaces: [_interface('rmnet_data0', '10.1.2.3', isLan: null)],
      ).snapshot();
      expect(snapshot.isConnected, isFalse);
    },
  );

  test('older Android Wi-Fi fallback excludes cellular interfaces', () async {
    final snapshot = await service(
      os: 'android',
      interfaces: [
        _interface('rmnet_data0', '10.1.2.3', isLan: null),
        _interface('wlan0', '192.168.1.20', isLan: null),
      ],
    ).snapshot();
    expect(snapshot.ip, '192.168.1.20');
  });

  for (final os in ['windows', 'android']) {
    test(
      '$os parses native metadata without relying on adapter labels',
      () async {
        const channel = MethodChannel('bshare/network');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final methods = <String>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          methods.add(call.method);
          return [
            {
              'index': 41,
              'name': 'Normal name',
              'isUp': true,
              'isLan': false,
              'addresses': [
                {'ip': '172.28.96.1', 'prefixLength': 20},
              ],
            },
            {
              'index': 11,
              'name': 'Anything',
              'isUp': true,
              'isLan': true,
              'kind': os == 'android' ? 'ethernet' : 'bridge',
              'hasDefaultRoute': true,
              'metric': 10,
              'addresses': [
                {'ip': '192.168.3.7', 'prefixLength': 24},
              ],
            },
          ];
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final network = NetworkService(
          operatingSystem: os,
          hasWifiNetwork: () async => false,
        );
        final links = await network.lanInterfaces();
        expect(links, hasLength(1));
        expect(links.single.index, 11);
        expect(links.single.prefixLengths, {'192.168.3.7': 24});
        expect(methods, ['getLanInterfaces']);
      },
    );
  }

  test(
    'peer route uses the actual socket source rather than the primary IP',
    () async {
      final calls = <String>[];
      final network = service(
        os: 'windows',
        interfaces: [
          _interface(
            'Default radio',
            '192.168.2.2',
            kind: 'wifi',
            hasDefaultRoute: true,
          ),
          _interface('Cable', '192.168.3.2', index: 2),
        ],
        peerAddress: (host, port) async {
          calls.add('$host:$port');
          return '192.168.3.2';
        },
      );
      expect(
        await network.localAddressForPeer('192.168.3.10', 53317),
        '192.168.3.2',
      );
      expect(calls, ['192.168.3.10:53317']);
    },
  );

  test(
    'a source belonging to an excluded virtual interface is not advertised',
    () async {
      final network = service(
        os: 'windows',
        interfaces: [
          _interface('LAN', '192.168.3.2'),
          _interface('VPN', '10.8.0.2', isLan: false),
        ],
        peerAddress: (_, _) async => '10.8.0.2',
      );
      expect(await network.localAddressForPeer('192.168.3.10', 53317), isNull);
    },
  );

  test(
    'peer lookup binds a LAN source and does not mistake the peer for it',
    () async {
      final socket = _ConnectedSocket();
      final sources = <String>[];
      final network = service(
        os: 'windows',
        interfaces: [
          _interface(
            'Preferred Wi-Fi',
            '192.168.2.2',
            kind: 'wifi',
            hasDefaultRoute: true,
          ),
          _interface('Ethernet', '192.168.3.2', index: 2),
        ],
      );
      final selected = await IOOverrides.runZoned(
        () => network.localAddressForPeer('192.168.3.10', 53317),
        socketConnect:
            (
              host,
              port, {
              sourceAddress,
              int sourcePort = 0,
              Duration? timeout,
            }) async {
              expect(host, '192.168.3.10');
              sources.add((sourceAddress as InternetAddress).address);
              return socket;
            },
      );
      expect(selected, '192.168.3.2');
      expect(sources, ['192.168.3.2']);
      expect(socket.address.address, '192.168.3.10');
      expect(socket.destroyed, isTrue);
    },
  );

  test(
    'an unreachable bound LAN falls back to another eligible source',
    () async {
      final socket = _ConnectedSocket();
      final sources = <String>[];
      final network = service(
        os: 'linux',
        interfaces: [
          _interface('First', '192.168.3.2', metric: 10),
          _interface('Second', '192.168.3.3', index: 2, metric: 20),
          _interface('VPN', '10.8.0.2', index: 3, isLan: false),
        ],
      );
      final selected = await IOOverrides.runZoned(
        () => network.localAddressForPeer('192.168.3.10', 53317),
        socketConnect:
            (
              host,
              port, {
              sourceAddress,
              int sourcePort = 0,
              Duration? timeout,
            }) async {
              final source = (sourceAddress as InternetAddress).address;
              sources.add(source);
              if (source == '192.168.3.2') {
                throw const SocketException('No route');
              }
              return socket;
            },
      );
      expect(selected, '192.168.3.3');
      expect(sources, ['192.168.3.2', '192.168.3.3']);
      expect(socket.destroyed, isTrue);
    },
  );

  test(
    'failed TCP route lookup falls back to the longest eligible prefix',
    () async {
      final network = service(
        os: 'linux',
        interfaces: [
          _interface('Broad', '10.4.1.2', prefix: 16, hasDefaultRoute: true),
          _interface('Closest', '10.4.2.2', index: 2, prefix: 24),
          _interface(
            'Internal',
            '10.4.2.3',
            index: 3,
            prefix: 32,
            isLan: false,
          ),
        ],
        peerAddress: (_, _) async =>
            throw const SocketException('Receiver stopped'),
      );
      expect(await network.localAddressForPeer('10.4.2.10', 53317), '10.4.2.2');
      expect(await network.localAddressForPeer('192.168.50.10', 53317), isNull);
    },
  );

  test(
    'Linux uses physical topology and keeps a bridge with a hardware uplink',
    () async {
      final names = [
        'Port A',
        'Office bridge',
        'Guest veth',
        'Internal bridge',
      ];
      final links = [
        for (var i = 0; i < names.length; i++)
          {
            'ifindex': i + 1,
            'ifname': names[i],
            'flags': ['UP', 'LOWER_UP'],
            'operstate': 'UP',
            if (i > 0) 'linkinfo': {'info_kind': i == 2 ? 'veth' : 'bridge'},
          },
      ];
      final addresses = [
        for (var i = 1; i < names.length; i++)
          {
            'ifindex': i + 1,
            'ifname': names[i],
            'addr_info': [
              {
                'family': 'inet',
                'local': '192.168.${i + 1}.2',
                'prefixlen': 24,
              },
            ],
          },
      ];
      final network = NetworkService(
        operatingSystem: 'linux',
        processRunner: _Runner({
          'ip -j -4 address show': addresses,
          'ip -j -d link show': links,
          'ip -j -4 route show table main': [],
        }),
        readLinuxLinkInfo: (name) async => LinuxLinkInfo(
          isPhysical: name == names[0],
          lowerInterfaces: name == names[1]
              ? [names[0]]
              : name == names[3]
              ? [names[2]]
              : [],
        ),
      );
      final interfaces = await network.lanInterfaces();
      expect(interfaces.map((link) => link.name), ['Office bridge']);
      expect(interfaces.single.hasDefaultRoute, isFalse);
      expect(interfaces.single.prefixLengths, {'192.168.2.2': 24});
    },
  );

  test(
    'Linux supports bonds and VLANs by their lower interface, not their name',
    () async {
      final network = NetworkService(
        operatingSystem: 'linux',
        processRunner: _Runner({
          'ip -j -4 address show': [
            {
              'ifindex': 3,
              'ifname': 'VLAN user label',
              'addr_info': [
                {'family': 'inet', 'local': '198.51.100.4', 'prefixlen': 25},
              ],
            },
          ],
          'ip -j -d link show': [
            {
              'ifindex': 1,
              'ifname': 'Hardware',
              'flags': ['UP', 'LOWER_UP'],
              'operstate': 'UP',
            },
            {
              'ifindex': 2,
              'ifname': 'Bond label',
              'flags': ['UP', 'LOWER_UP'],
              'operstate': 'UP',
              'linkinfo': {'info_kind': 'bond'},
            },
            {
              'ifindex': 3,
              'ifname': 'VLAN user label',
              'flags': ['UP'],
              'operstate': 'UP',
              'link_index': 2,
              'linkinfo': {'info_kind': 'vlan'},
            },
          ],
          'ip -j -4 route show table main': [],
        }),
        readLinuxLinkInfo: (name) async => LinuxLinkInfo(
          isPhysical: name == 'Hardware',
          lowerInterfaces: name == 'Bond label' ? ['Hardware'] : [],
        ),
      );
      expect((await network.snapshot()).ip, '198.51.100.4');
    },
  );

  for (final hardwareState in ['DOWN', 'UNKNOWN']) {
    test(
      'Linux rejects a bridge with a $hardwareState uplink and active veth peers',
      () async {
        final network = NetworkService(
          operatingSystem: 'linux',
          processRunner: _Runner({
            'ip -j -4 address show': [
              {
                'ifindex': 2,
                'ifname': 'Office',
                'addr_info': [
                  {'family': 'inet', 'local': '192.168.3.2', 'prefixlen': 24},
                ],
              },
              {
                'ifindex': 4,
                'ifname': 'docker0',
                'addr_info': [
                  {'family': 'inet', 'local': '172.19.0.1', 'prefixlen': 16},
                ],
              },
            ],
            'ip -j -d link show': [
              {
                'ifindex': 1,
                'ifname': 'Hardware',
                'flags': ['UP'],
                'operstate': hardwareState,
              },
              {
                'ifindex': 2,
                'ifname': 'Office',
                'flags': ['UP', 'LOWER_UP'],
                'operstate': 'UP',
                'linkinfo': {'info_kind': 'bridge'},
              },
              {
                'ifindex': 3,
                'ifname': 'Guest port',
                'flags': ['UP', 'LOWER_UP'],
                'operstate': 'UP',
                'linkinfo': {'info_kind': 'veth'},
              },
              {
                'ifindex': 4,
                'ifname': 'docker0',
                'flags': ['UP', 'LOWER_UP'],
                'operstate': 'UP',
                'linkinfo': {'info_kind': 'bridge'},
              },
            ],
            'ip -j -4 route show table main': [
              {'dst': 'default', 'dev': 'Office'},
            ],
          }),
          readLinuxLinkInfo: (name) async => LinuxLinkInfo(
            isPhysical: name == 'Hardware',
            lowerInterfaces: name == 'Office'
                ? ['Hardware', 'Guest port']
                : name == 'docker0'
                ? ['Guest port']
                : [],
          ),
        );
        expect(await network.lanInterfaces(), isEmpty);
      },
    );
  }

  test(
    'macOS reads active hardware ports and ignores inactive and internal links',
    () async {
      final network = NetworkService(
        operatingSystem: 'macos',
        processRunner: _Runner({
          '/usr/sbin/networksetup -listallhardwareports':
              'Hardware Port: USB Ethernet\nDevice: en9\nEthernet Address: 00:11:22:33:44:55\n\nHardware Port: Ethernet\nDevice: en8\nEthernet Address: 00:11:22:33:44:66\n',
          '/sbin/ifconfig -a':
              'en9: flags=8863<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n\tinet 169.254.12.4 netmask 0xffff0000 broadcast 169.254.255.255\n\tstatus: active\nen8: flags=8863<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n\tinet 192.168.8.1 netmask 0xffffff00\n\tstatus: inactive\nvmnet2: flags=8863<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n\tinet 172.16.4.1 netmask 0xffffff00\n',
          '/sbin/route -n get default': 'interface: en8\n',
        }),
      );
      final links = await network.lanInterfaces();
      expect(links.map((link) => link.name), ['en9']);
      expect(links.single.prefixLengths, {'169.254.12.4': 16});
    },
  );
}
