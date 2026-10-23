import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:bshare/src/infrastructure/services/process_runner.dart';

class UsbCameraAddress {
  const UsbCameraAddress({
    required this.ip,
    required this.prefixLength,
    required this.interfaceName,
  });

  final String ip;
  final int prefixLength;
  final String interfaceName;

  bool containsRemote(String value) {
    final local = InternetAddress.tryParse(ip);
    final remote = InternetAddress.tryParse(value.trim());
    if (local == null ||
        remote == null ||
        local.type != InternetAddressType.IPv4 ||
        remote.type != InternetAddressType.IPv4 ||
        prefixLength < 1 ||
        prefixLength > 32 ||
        local.address == remote.address) {
      return false;
    }
    final localBytes = local.rawAddress;
    final remoteBytes = remote.rawAddress;
    for (var index = 0; index < 4; index++) {
      final bits = (prefixLength - index * 8).clamp(0, 8);
      final mask = bits == 0 ? 0 : (0xff << (8 - bits)) & 0xff;
      if ((localBytes[index] & mask) != (remoteBytes[index] & mask)) {
        return false;
      }
    }
    return !remote.isLoopback && !remote.isMulticast && value != '0.0.0.0';
  }
}

class UsbCameraNetworkSnapshot {
  const UsbCameraNetworkSnapshot({this.addresses = const []});

  final List<UsbCameraAddress> addresses;
  List<String> get localIps => addresses.map((address) => address.ip).toList();
  List<String> get remoteSubnets => addresses
      .map((address) => '${address.ip}/${address.prefixLength}')
      .toList();
  bool containsRemote(String ip) =>
      addresses.any((address) => address.containsRemote(ip));
}

/// USB video travels through a tethering network with real interface addresses.
/// Never substitutes Wi-Fi, ADB or loopback addresses when no USB link exists.
class UsbCameraNetworkService {
  UsbCameraNetworkService({
    this._runner = const ProcessRunner(),
    this._readAddresses,
  });

  static const _channel = MethodChannel('bshare/camera');
  final ProcessRunner _runner;
  final Future<List<Object?>> Function()? _readAddresses;

  Future<UsbCameraNetworkSnapshot> snapshot() async {
    final raw = await (_readAddresses?.call() ?? _platformAddresses());
    final seen = <String>{};
    final addresses = <UsbCameraAddress>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final ip = item['ip'];
      final prefix = item['prefixLength'];
      final interface = item['interfaceName'];
      if (ip is! String ||
          prefix is! int ||
          prefix < 1 ||
          prefix > 32 ||
          interface is! String ||
          interface.isEmpty) {
        continue;
      }
      final address = InternetAddress.tryParse(ip);
      if (address == null ||
          address.type != InternetAddressType.IPv4 ||
          address.isLoopback ||
          address.isMulticast ||
          ip == '0.0.0.0' ||
          !seen.add(ip)) {
        continue;
      }
      addresses.add(
        UsbCameraAddress(
          ip: ip,
          prefixLength: prefix,
          interfaceName: interface,
        ),
      );
    }
    return UsbCameraNetworkSnapshot(addresses: List.unmodifiable(addresses));
  }

  Future<List<Object?>> _platformAddresses() async {
    if (Platform.isAndroid) {
      return await _channel.invokeListMethod<Object?>('listUsbAddresses') ?? [];
    }
    if (Platform.isLinux) return _linuxAddresses();
    if (Platform.isWindows) return _windowsAddresses();
    if (Platform.isMacOS) return _macAddresses();
    // iOS currently has no reliable public API to identify a tethering
    // downstream interface. Do not pretend a Wi-Fi interface is a USB cable.
    return [];
  }

  Future<List<Object?>> _linuxAddresses() async {
    final result = await _runner.run('ip', [
      '-j',
      '-4',
      'address',
      'show',
    ], timeout: const Duration(seconds: 5));
    if (result.exitCode != 0) {
      throw StateError('USB interface enumeration failed');
    }
    final decoded = jsonDecode(result.stdout as String);
    final output = <Object?>[];
    if (decoded is! List) return output;
    for (final item in decoded) {
      if (item is! Map ||
          item['ifname'] is! String ||
          item['addr_info'] is! List) {
        continue;
      }
      final name = item['ifname'] as String;
      if (!RegExp(r'^[a-zA-Z0-9_.:-]+$').hasMatch(name)) continue;
      try {
        final devicePath = await Directory(
          '/sys/class/net/$name/device',
        ).resolveSymbolicLinks();
        if (!devicePath
            .split('/')
            .any((part) => RegExp(r'^usb\d+$').hasMatch(part))) {
          continue;
        }
        // USB Wi-Fi adapters are still Wi-Fi, not a wired USB camera link.
        if (await Directory('/sys/class/net/$name/wireless').exists() ||
            await Directory('/sys/class/net/$name/phy80211').exists()) {
          continue;
        }
      } on FileSystemException {
        continue;
      }
      for (final info in item['addr_info'] as List) {
        if (info is Map && info['family'] == 'inet') {
          output.add({
            'ip': info['local'],
            'prefixLength': info['prefixlen'],
            'interfaceName': name,
          });
        }
      }
    }
    return output;
  }

  Future<List<Object?>> _windowsAddresses() async {
    const script =
        r"$usb = Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.PNPDeviceID -like 'USB\*' -and $_.NetEnabled -and $_.AdapterTypeID -eq 0 }; @(foreach ($adapter in $usb) { Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { @{ ip = $_.IPAddress; prefixLength = [int]$_.PrefixLength; interfaceName = $adapter.NetConnectionID } } }) | ConvertTo-Json -Compress";
    final result = await _runner.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      script,
    ], timeout: const Duration(seconds: 10));
    if (result.exitCode != 0) {
      throw StateError('USB interface enumeration failed');
    }
    final text = (result.stdout as String).trim();
    if (text.isEmpty) return [];
    final decoded = jsonDecode(text);
    return decoded is List ? decoded.cast<Object?>() : [decoded];
  }

  Future<List<Object?>> _macAddresses() async {
    final ports = await _runner.run('/usr/sbin/networksetup', [
      '-listallhardwareports',
    ], timeout: const Duration(seconds: 5));
    if (ports.exitCode != 0) {
      throw StateError('USB interface enumeration failed');
    }
    final output = <Object?>[];
    for (final block in (ports.stdout as String).split(RegExp(r'\n\s*\n'))) {
      if (!RegExp(
            r'Hardware Port:.*USB',
            caseSensitive: false,
          ).hasMatch(block) ||
          RegExp(r'Wi-?Fi|Wireless', caseSensitive: false).hasMatch(block)) {
        continue;
      }
      final name = RegExp(
        r'Device:\s*([a-zA-Z0-9]+)',
      ).firstMatch(block)?.group(1);
      if (name == null) continue;
      final result = await _runner.run('/sbin/ifconfig', [
        name,
      ], timeout: const Duration(seconds: 5));
      if (result.exitCode != 0) continue;
      for (final match in RegExp(
        r'inet\s+(\d+\.\d+\.\d+\.\d+)\s+netmask\s+0x([a-fA-F0-9]+)',
      ).allMatches(result.stdout as String)) {
        final mask = int.parse(
          match.group(2)!,
          radix: 16,
        ).toRadixString(2).padLeft(32, '0');
        if (!RegExp(r'^1+0*$').hasMatch(mask)) continue;
        output.add({
          'ip': match.group(1),
          'prefixLength': mask.replaceAll('0', '').length,
          'interfaceName': name,
        });
      }
    }
    return output;
  }

  Future<void> openUsbSettings() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('openUsbTetheringSettings');
    }
  }
}
