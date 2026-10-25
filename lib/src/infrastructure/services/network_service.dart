import 'dart:io';

import 'package:flutter/services.dart';
import 'package:network_info_plus/network_info_plus.dart';

class NetworkSnapshot {
  const NetworkSnapshot({this.ip, this.wifiName});

  final String? ip;
  final String? wifiName;

  bool get isConnected => ip != null && ip!.isNotEmpty;
}

class NetworkService {
  NetworkService({
    String? operatingSystem,
    this._readWifiIp,
    this._readWifiName,
    Future<bool> Function()? hasWifiNetwork,
    this._listInterfaces,
  }) : _operatingSystem = operatingSystem ?? Platform.operatingSystem,
       _readHasWifiNetwork = hasWifiNetwork;

  static const _directChannel = MethodChannel('bshare/direct_network');

  final _info = NetworkInfo();
  final String _operatingSystem;
  final Future<String?> Function()? _readWifiIp;
  final Future<String?> Function()? _readWifiName;
  final Future<bool> Function()? _readHasWifiNetwork;
  final Future<List<NetworkInterface>> Function()? _listInterfaces;

  bool get _isAndroid => _operatingSystem == 'android';
  bool get _isWindows => _operatingSystem == 'windows';
  bool get _isLinux => _operatingSystem == 'linux';

  Future<NetworkSnapshot> snapshot({
    bool includeLocalInterfaces = false,
  }) async {
    final hasWifiNetwork = await _hasWifiNetwork();
    final wifiIp = hasWifiNetwork ? await _safeWifiIp() : null;
    final localIp = includeLocalInterfaces
        ? await _localWifiIp()
        : wifiIp == null && (!_isAndroid || hasWifiNetwork)
        ? _isAndroid
              ? await _localWifiIp()
              : await _localLanIp()
        : null;
    final ip = wifiIp ?? localIp;
    final wifiName = await _safeWifiName();
    final cleanName = wifiName?.replaceAll('"', '');
    return NetworkSnapshot(
      ip: ip,
      wifiName: hasWifiNetwork && cleanName != '<unknown ssid>'
          ? cleanName
          : null,
    );
  }

  Future<bool> _hasWifiNetwork() async {
    final reader = _readHasWifiNetwork;
    if (reader != null) return reader();
    if (!_isAndroid) return true;
    try {
      return await _directChannel.invokeMethod<bool>('hasWifiNetwork') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _safeWifiIp() async {
    try {
      final value = await (_readWifiIp?.call() ?? _info.getWifiIP());
      final address = value == null ? null : InternetAddress.tryParse(value);
      if (address == null ||
          address.type != InternetAddressType.IPv4 ||
          address.isLoopback ||
          address.isMulticast ||
          address.address == '0.0.0.0') {
        return null;
      }
      return address.address;
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

  Future<String?> _localWifiIp() async {
    final interfaces = await _interfaces();
    final candidates = <({String address, int score})>[];
    for (final interface in interfaces) {
      final name = interface.name.toLowerCase();
      for (final address in interface.addresses) {
        if (!_looksLocal(address.address)) continue;
        final score = _localInterfaceScore(name, address.address);
        if (score > 0) {
          candidates.add((address: address.address, score: score));
        }
      }
    }
    candidates.sort((a, b) => b.score.compareTo(a.score));
    return candidates.isEmpty ? null : candidates.first.address;
  }

  int _localInterfaceScore(String name, String address) {
    if (_isWindows && address.startsWith('192.168.137.')) return 100;
    if (_isLinux &&
        _isLinuxWifiInterface(name) &&
        address.startsWith('10.42.')) {
      return 100;
    }
    if (_isWindows &&
        (name.contains('wi-fi direct') ||
            name.contains('wifi direct') ||
            name.contains('microsoft wi-fi') ||
            name.contains('local area connection') ||
            name.contains('area local') ||
            name.contains('conexion de area local'))) {
      return 90;
    }
    if (_isWifiInterface(name)) {
      return 60;
    }
    return 0;
  }

  Future<String?> _localLanIp() async {
    final interfaces = await _interfaces();
    final candidates = <({String address, int score})>[];
    for (final interface in interfaces) {
      final name = interface.name.toLowerCase();
      if (_isVirtualInterface(name)) continue;
      for (final address in interface.addresses) {
        if (!_looksLocal(address.address)) continue;
        final score = _lanInterfaceScore(name, address.address);
        if (score > 0) {
          candidates.add((address: address.address, score: score));
        }
      }
    }
    candidates.sort((a, b) => b.score.compareTo(a.score));
    return candidates.isEmpty ? null : candidates.first.address;
  }

  int _lanInterfaceScore(String name, String address) {
    if (_isLinux &&
        _isLinuxWifiInterface(name) &&
        address.startsWith('10.42.')) {
      return 100;
    }
    if (_isLinuxWifiInterface(name)) return 80;
    if (name == 'eth0' ||
        name.startsWith('ethernet') ||
        (_operatingSystem == 'macos' && RegExp(r'^en\d+$').hasMatch(name)) ||
        name.startsWith('enp') ||
        name.startsWith('ens') ||
        name.startsWith('eno') ||
        name.startsWith('enx')) {
      return 70;
    }
    if (_isWifiInterface(name)) return 60;
    // Windows exposes localized/user-renamed adapter labels. Any remaining
    // physical LAN interface is preferable to incorrectly treating Ethernet
    // as disconnected and trying to create a hotspot.
    return 10;
  }

  bool _isWifiInterface(String name) =>
      name.contains('wlan') ||
      name.contains('wifi') ||
      name.contains('wi-fi') ||
      name.contains('swlan') ||
      RegExp(r'^ap\d*$').hasMatch(name) ||
      name.contains('p2p') ||
      _isLinuxWifiInterface(name);

  bool _isLinuxWifiInterface(String name) =>
      _isLinux && (name.startsWith('wl') || name.startsWith('wifi'));

  bool _isVirtualInterface(String name) =>
      name.startsWith('br-') ||
      name.startsWith('docker') ||
      name.startsWith('veth') ||
      name.startsWith('virbr') ||
      name.startsWith('vmnet') ||
      name.startsWith('vethernet') ||
      name.contains('vmware') ||
      name.contains('virtualbox') ||
      name.contains('hyper-v') ||
      name.startsWith('tailscale') ||
      name.startsWith('tun') ||
      name.startsWith('tap') ||
      name.startsWith('wg') ||
      name.startsWith('zt');

  Future<List<NetworkInterface>> _interfaces() =>
      _listInterfaces?.call() ??
      NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

  bool _looksLocal(String address) =>
      address.startsWith('10.') ||
      address.startsWith('192.168.') ||
      RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(address);
}
