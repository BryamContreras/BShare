import 'dart:io';

import 'package:bshare/src/infrastructure/services/lan_interface.dart';
import 'package:bshare/src/infrastructure/services/lan_interface_reader.dart';
import 'package:bshare/src/infrastructure/services/process_runner.dart';
import 'package:flutter/services.dart';
import 'package:network_info_plus/network_info_plus.dart';

export 'lan_interface.dart';
export 'lan_interface_reader.dart' show LinuxLinkInfo;

class NetworkSnapshot {
  const NetworkSnapshot({this.ip, this.wifiName, this.interfaces = const []});
  final String? ip;
  final String? wifiName;
  final List<LanInterface> interfaces;
  bool get isConnected => ip != null && ip!.isNotEmpty;
}

class NetworkService {
  NetworkService({
    String? operatingSystem,
    this._readWifiIp,
    this._readWifiName,
    Future<bool> Function()? hasWifiNetwork,
    this._listInterfaces,
    this._readRoutedInterfaceIndexes,
    this._readPeerLocalAddress,
    ProcessRunner processRunner = const ProcessRunner(),
    Future<LinuxLinkInfo> Function(String name)? readLinuxLinkInfo,
  }) : _operatingSystem = operatingSystem ?? Platform.operatingSystem,
       _readHasWifiNetwork = hasWifiNetwork,
       _reader = LanInterfaceReader(
         runner: processRunner,
         readLinuxLinkInfo: readLinuxLinkInfo,
       );

  static const _directChannel = MethodChannel('bshare/direct_network');
  static const _networkChannel = MethodChannel('bshare/network');
  final _info = NetworkInfo();
  final String _operatingSystem;
  final Future<String?> Function()? _readWifiIp;
  final Future<String?> Function()? _readWifiName;
  final Future<bool> Function()? _readHasWifiNetwork;
  final Future<List<LanInterface>> Function()? _listInterfaces;
  final Future<List<int>> Function()? _readRoutedInterfaceIndexes;
  final Future<String?> Function(String host, int port)? _readPeerLocalAddress;
  final LanInterfaceReader _reader;

  bool get _isAndroid => _operatingSystem == 'android';
  bool get _isWindows => _operatingSystem == 'windows';

  Future<NetworkSnapshot> snapshot({
    bool includeLocalInterfaces = false,
  }) async {
    final interfaces = await lanInterfaces();
    interfaces.sort(
      (a, b) => _compare(a, b, preferHosted: includeLocalInterfaces),
    );
    if (interfaces.isEmpty) return const NetworkSnapshot();
    final selected = interfaces.first;
    final ip = selected.addresses.first.address;
    String? wifiName;
    if (selected.kind == 'wifi') {
      wifiName = (await _safeWifiName())?.replaceAll('"', '');
      if (wifiName == '<unknown ssid>') wifiName = null;
    }
    return NetworkSnapshot(
      ip: ip,
      wifiName: wifiName,
      interfaces: List.unmodifiable(interfaces),
    );
  }

  /// All active LAN interfaces, ordered by the OS route preference.
  Future<List<LanInterface>> lanInterfaces() async {
    final injected = _listInterfaces;
    List<LanInterface>? interfaces;
    var metadataAvailable = false;
    if (injected != null) {
      interfaces = await injected();
      metadataAvailable = interfaces.any((link) => link.isLan != null);
    } else {
      if (_isWindows || _isAndroid) {
        try {
          final raw = await _networkChannel.invokeListMethod<Object?>(
            'getLanInterfaces',
          );
          if (raw != null) {
            metadataAvailable = true;
            interfaces = [
              for (final item in raw) ?LanInterface.fromPlatform(item),
            ];
          }
        } catch (_) {
          // Older platform runners can still use Dart/Wi-Fi enumeration.
        }
      } else if (_operatingSystem == 'linux') {
        interfaces = await _reader.linuxInterfaces();
        metadataAvailable = interfaces != null;
      } else if (_operatingSystem == 'macos') {
        interfaces = await _reader.macInterfaces();
        metadataAvailable = interfaces != null;
        if (interfaces != null) {
          final dartInterfaces = await _dartInterfaces();
          interfaces = [
            for (final link in interfaces)
              LanInterface(
                name: link.name,
                index:
                    dartInterfaces
                        .where((item) => item.name == link.name)
                        .firstOrNull
                        ?.index ??
                    link.index,
                addresses: link.addresses,
                prefixLengths: link.prefixLengths,
                kind: link.kind,
                isUp: link.isUp,
                isLan: link.isLan,
                hasDefaultRoute: link.hasDefaultRoute,
                metric: link.metric,
              ),
          ];
        }
      }
      interfaces ??= await _dartInterfaces();
    }
    // Vendors can omit a connected local-only Wi-Fi link from LinkProperties.
    if (_isAndroid && interfaces.isEmpty && await _hasWifiNetwork()) {
      interfaces = injected != null ? interfaces : await _dartInterfaces();
      metadataAvailable = false;
    }
    final unknown =
        !metadataAvailable || interfaces.any((link) => link.isLan == null);
    final wifiAvailable = unknown && _isAndroid
        ? await _hasWifiNetwork()
        : true;
    final wifiIp = unknown && wifiAvailable ? await _safeWifiIp() : null;
    final routed = unknown && _isWindows
        ? await _routedIndexes()
        : const <int>{};
    final output = <LanInterface>[];
    for (final link in interfaces) {
      if (!link.isUp || link.isLan == false) continue;
      if (link.isLan == null) {
        // Names are only a conservative fallback when OS metadata is absent.
        final name = link.name.toLowerCase();
        if (_isAndroid && !wifiAvailable && !link.isHosted) continue;
        final routedBridge =
            _isWindows &&
            (name.startsWith('vethernet') || name.contains('hyper-v')) &&
            routed.contains(link.index);
        if (_fallbackVirtual(name) && !routedBridge) continue;
        if (_isAndroid &&
            !link.isHosted &&
            !link.addresses.any((address) => address.address == wifiIp) &&
            !_fallbackWifi(name)) {
          continue;
        }
      }
      final addresses = link.addresses.where(isUsableLanAddress).toList();
      if (addresses.isEmpty) continue;
      output.add(link.withAddresses(addresses));
    }
    // The Wi-Fi API can still identify a local-only link on older Android builds.
    if (output.isEmpty && unknown && wifiIp != null) {
      final address = InternetAddress.tryParse(wifiIp);
      if (address != null && isUsableLanAddress(address)) {
        output.add(
          LanInterface(
            name: '',
            index: 0,
            addresses: [address],
            kind: 'wifi',
            isLan: true,
          ),
        );
      }
    }
    output.sort(_compare);
    return output;
  }

  /// Confirms a bound LAN source for this peer instead of preferring Wi-Fi.
  Future<String?> localAddressForPeer(String host, int port) async {
    final remote = InternetAddress.tryParse(host);
    if (remote == null ||
        !isUsableLanAddress(remote) ||
        port < 1 ||
        port > 65535) {
      return null;
    }
    final interfaces = await lanInterfaces();
    if (interfaces.isEmpty) return null;
    try {
      final local =
          await (_readPeerLocalAddress?.call(host, port) ??
              _connectLocalAddress(host, port, remote, interfaces));
      if (local != null) {
        return interfaces.any(
              (link) => link.addresses.any((ip) => ip.address == local),
            )
            ? local
            : null;
      }
    } catch (_) {
      // A temporarily stopped receiver can still have an unambiguous on-link route.
    }
    final candidates = <({String ip, int prefix, LanInterface link})>[];
    for (final link in interfaces) {
      for (final local in link.addresses) {
        final prefix = link.prefixLengths[local.address];
        if (prefix != null && sameIpv4Subnet(local, remote, prefix)) {
          candidates.add((ip: local.address, prefix: prefix, link: link));
        }
      }
    }
    candidates.sort((a, b) {
      final prefix = b.prefix.compareTo(a.prefix);
      return prefix != 0 ? prefix : _compare(a.link, b.link);
    });
    return candidates.firstOrNull?.ip;
  }

  Future<String?> _connectLocalAddress(
    String host,
    int port,
    InternetAddress remote,
    List<LanInterface> interfaces,
  ) async {
    final candidates =
        <({InternetAddress address, int prefix, LanInterface link})>[
          for (final link in interfaces)
            for (final address in link.addresses)
              (
                address: address,
                prefix: switch (link.prefixLengths[address.address]) {
                  final int prefix
                      when sameIpv4Subnet(address, remote, prefix) =>
                    prefix,
                  _ => 0,
                },
                link: link,
              ),
        ]..sort((a, b) {
          final prefix = b.prefix.compareTo(a.prefix);
          return prefix != 0 ? prefix : _compare(a.link, b.link);
        });
    final budget = Stopwatch()..start();
    for (final candidate in candidates) {
      final remaining = 4000 - budget.elapsedMilliseconds;
      if (remaining <= 0) break;
      Socket? socket;
      try {
        // Socket.address is the address used to connect, not getsockname().
        // Binding explicitly proves which eligible source reached this peer.
        socket = await Socket.connect(
          host,
          port,
          sourceAddress: candidate.address,
          timeout: Duration(milliseconds: remaining.clamp(1, 2000)),
        );
        return candidate.address.address;
      } catch (_) {
        // Try another physical LAN; one down route must not select a VPN.
      } finally {
        socket?.destroy();
      }
    }
    return null;
  }

  static int _compare(
    LanInterface a,
    LanInterface b, {
    bool preferHosted = false,
  }) {
    if (preferHosted && a.isHosted != b.isHosted) return a.isHosted ? -1 : 1;
    if (a.hasDefaultRoute != b.hasDefaultRoute) {
      return a.hasDefaultRoute ? -1 : 1;
    }
    final metric = a.metric.compareTo(b.metric);
    return metric != 0 ? metric : a.index.compareTo(b.index);
  }

  Future<List<LanInterface>> _dartInterfaces() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: true,
        type: InternetAddressType.IPv4,
      );
      return [
        for (final link in interfaces)
          LanInterface(
            name: link.name,
            index: link.index,
            addresses: List<InternetAddress>.of(link.addresses),
          ),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<bool> _hasWifiNetwork() async {
    try {
      if (_readHasWifiNetwork != null) return await _readHasWifiNetwork();
      if (!_isAndroid) return true;
      return await _directChannel.invokeMethod<bool>('hasWifiNetwork') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _safeWifiIp() async {
    try {
      final value = await (_readWifiIp?.call() ?? _info.getWifiIP());
      final ip = value == null ? null : InternetAddress.tryParse(value);
      return ip != null && isUsableLanAddress(ip) ? ip.address : null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _safeWifiName() async {
    try {
      return await (_readWifiName?.call() ?? _info.getWifiName());
    } catch (_) {
      return null;
    }
  }

  Future<Set<int>> _routedIndexes() async {
    try {
      final indexes =
          await (_readRoutedInterfaceIndexes?.call() ??
              _networkChannel.invokeListMethod<int>(
                'getRoutedInterfaceIndexes',
              ));
      return indexes?.toSet() ?? {};
    } catch (_) {
      return {};
    }
  }

  bool _fallbackWifi(String name) =>
      name.contains('wlan') ||
      name.contains('wifi') ||
      name.contains('wi-fi') ||
      name.startsWith('wl') ||
      RegExp(r'^ap\d*$').hasMatch(name) ||
      name.contains('p2p');

  bool _fallbackVirtual(String name) =>
      const [
        'docker',
        'veth',
        'br-',
        'virbr',
        'vmnet',
        'tailscale',
        'tun',
        'tap',
        'wg',
        'zt',
        'rmnet',
        'pdp_ip',
      ].any(name.startsWith) ||
      name.contains('vmware') ||
      name.contains('virtualbox') ||
      name.contains('hyper-v');
}
