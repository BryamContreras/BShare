import 'dart:convert';
import 'dart:io';

import 'package:bshare/src/infrastructure/services/lan_interface.dart';
import 'package:bshare/src/infrastructure/services/process_runner.dart';

class LinuxLinkInfo {
  const LinuxLinkInfo({
    this.isPhysical = false,
    this.isWifi = false,
    this.lowerInterfaces = const [],
  });
  final bool isPhysical;
  final bool isWifi;
  final List<String> lowerInterfaces;
}

/// Reads link facts without changing routes, network profiles or interfaces.
class LanInterfaceReader {
  const LanInterfaceReader({
    this.runner = const ProcessRunner(),
    this.readLinuxLinkInfo,
  });
  final ProcessRunner runner;
  final Future<LinuxLinkInfo> Function(String name)? readLinuxLinkInfo;

  Future<List<LanInterface>?> linuxInterfaces() async {
    try {
      final results = await Future.wait([
        runner.run('ip', [
          '-j',
          '-4',
          'address',
          'show',
        ], timeout: const Duration(seconds: 3)),
        runner.run('ip', [
          '-j',
          '-d',
          'link',
          'show',
        ], timeout: const Duration(seconds: 3)),
        runner.run('ip', [
          '-j',
          '-4',
          'route',
          'show',
          'table',
          'main',
        ], timeout: const Duration(seconds: 3)),
      ]);
      if (results.any((result) => result.exitCode != 0)) return null;
      final addressRows = jsonDecode(results[0].stdout as String);
      final linkRows = jsonDecode(results[1].stdout as String);
      final routeRows = jsonDecode(results[2].stdout as String);
      if (addressRows is! List || linkRows is! List || routeRows is! List) {
        return null;
      }
      final links = <String, Map>{};
      final byIndex = <int, String>{};
      for (final row in linkRows) {
        if (row is! Map || row['ifname'] is! String) continue;
        final name = row['ifname'] as String;
        links[name] = row;
        if (row['ifindex'] is int) byIndex[row['ifindex'] as int] = name;
      }
      final facts = <String, LinuxLinkInfo>{};
      for (final name in links.keys) {
        facts[name] =
            await (readLinuxLinkInfo?.call(name) ?? _linuxFacts(name));
      }
      String linkKind(Map row) {
        final info = row['linkinfo'];
        return info is Map && info['info_kind'] is String
            ? info['info_kind'] as String
            : '';
      }

      bool linkIsActive(Map row) {
        final flags = row['flags'];
        if (flags is! List ||
            !flags.contains('UP') ||
            flags.contains('LOOPBACK')) {
          return false;
        }
        final state = row['operstate'];
        if (state != null && state != 'UP' && state != 'UNKNOWN') return false;
        return state == 'UP' || flags.contains('LOWER_UP');
      }

      bool hasPhysicalLink(String name, Set<String> visited) {
        if (!visited.add(name)) return false;
        final row = links[name];
        final info = facts[name];
        if (row == null || info == null || !linkIsActive(row)) return false;
        final kind = linkKind(row);
        if (const {
          'veth',
          'tun',
          'wireguard',
          'vxlan',
          'geneve',
          'dummy',
          'ifb',
        }.contains(kind)) {
          return false;
        }
        if (info.isPhysical || info.isWifi) return true;
        if (!const {'bridge', 'bond', 'vlan', 'team'}.contains(kind)) {
          return false;
        }
        final children = <String>{...info.lowerInterfaces};
        final parentIndex = row['link_index'];
        if (parentIndex is int && byIndex[parentIndex] != null) {
          children.add(byIndex[parentIndex]!);
        }
        for (final entry in links.entries) {
          if (entry.value['master'] == name ||
              entry.value['master'] == row['ifindex']) {
            children.add(entry.key);
          }
        }
        return children.any((child) => hasPhysicalLink(child, visited));
      }

      final hosted = await _linuxAccessPoints();
      final output = <LanInterface>[];
      for (final row in addressRows) {
        if (row is! Map || row['ifname'] is! String || row['ifindex'] is! int) {
          continue;
        }
        final name = row['ifname'] as String;
        final link = links[name] ?? row;
        final up = linkIsActive(link);
        final info = facts[name] ?? const LinuxLinkInfo();
        final kind = linkKind(link);
        final lan = up && hasPhysicalLink(name, <String>{});
        final addresses = <InternetAddress>[];
        final prefixes = <String, int>{};
        final raw = row['addr_info'];
        if (raw is List) {
          for (final item in raw) {
            if (item is! Map ||
                item['family'] != 'inet' ||
                item['local'] is! String) {
              continue;
            }
            final ip = InternetAddress.tryParse(item['local'] as String);
            if (ip == null || !isUsableLanAddress(ip)) continue;
            addresses.add(ip);
            final prefix = item['prefixlen'];
            if (prefix is int && prefix >= 1 && prefix <= 32) {
              prefixes[ip.address] = prefix;
            }
          }
        }
        var defaultRoute = false;
        var metric = 2147483647;
        for (final route in routeRows) {
          if (route is! Map ||
              route['dev'] != name ||
              (route['dst'] != 'default' && route['dst'] != '0.0.0.0/0')) {
            continue;
          }
          defaultRoute = true;
          final routeMetric = route['metric'] is int
              ? route['metric'] as int
              : 0;
          if (routeMetric < metric) metric = routeMetric;
        }
        output.add(
          LanInterface(
            name: name,
            index: row['ifindex'] as int,
            addresses: addresses,
            prefixLengths: prefixes,
            kind: info.isWifi
                ? 'wifi'
                : kind == 'bridge'
                ? 'bridge'
                : 'ethernet',
            isUp: up,
            isLan: lan,
            hasDefaultRoute: defaultRoute,
            metric: metric,
            isHosted: hosted.contains(name),
          ),
        );
      }
      return output;
    } catch (_) {
      return null;
    }
  }

  Future<LinuxLinkInfo> _linuxFacts(String name) async {
    if (name.isEmpty ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains('\x00')) {
      return const LinuxLinkInfo();
    }
    final base = '/sys/class/net/$name';
    final lower = <String>[];
    try {
      await for (final entry in Directory(base).list()) {
        final leaf = entry.path.split('/').last;
        if (leaf.startsWith('lower_')) lower.add(leaf.substring(6));
      }
    } on FileSystemException {
      return const LinuxLinkInfo();
    }
    return LinuxLinkInfo(
      isPhysical: await Directory('$base/device').exists(),
      isWifi:
          await Directory('$base/phy80211').exists() ||
          await Directory('$base/wireless').exists(),
      lowerInterfaces: lower,
    );
  }

  Future<Set<String>> _linuxAccessPoints() async {
    try {
      final result = await runner.run('iw', [
        'dev',
      ], timeout: const Duration(seconds: 2));
      if (result.exitCode != 0) return {};
      final names = <String>{};
      String? current;
      for (final line in (result.stdout as String).split('\n')) {
        final text = line.trim();
        if (text.startsWith('Interface ')) current = text.substring(10).trim();
        if (current != null && text == 'type AP') names.add(current);
      }
      return names;
    } catch (_) {
      return {};
    }
  }

  Future<List<LanInterface>?> macInterfaces() async {
    try {
      final ports = await runner.run('/usr/sbin/networksetup', [
        '-listallhardwareports',
      ], timeout: const Duration(seconds: 3));
      final config = await runner.run('/sbin/ifconfig', [
        '-a',
      ], timeout: const Duration(seconds: 3));
      if (ports.exitCode != 0 || config.exitCode != 0) return null;
      final kinds = <String, String>{};
      for (final block in (ports.stdout as String).split(RegExp(r'\n\s*\n'))) {
        final name = RegExp(r'Device:\s*([^\s]+)').firstMatch(block)?.group(1);
        if (name == null) continue;
        final wifi = RegExp(
          r'Hardware Port:.*(Wi-?Fi|AirPort)',
          caseSensitive: false,
        ).hasMatch(block);
        kinds[name] = wifi ? 'wifi' : 'ethernet';
      }
      String? defaultName;
      try {
        final route = await runner.run('/sbin/route', [
          '-n',
          'get',
          'default',
        ], timeout: const Duration(seconds: 2));
        if (route.exitCode == 0) {
          defaultName = RegExp(
            r'interface:\s*(\S+)',
          ).firstMatch(route.stdout as String)?.group(1);
        }
      } catch (_) {}
      final output = <LanInterface>[];
      var index = 0;
      final blocks = (config.stdout as String).split(RegExp(r'\n(?=\S)'));
      for (final block in blocks) {
        final name = RegExp(r'^([^\s:]+):').firstMatch(block)?.group(1);
        if (name == null || !kinds.containsKey(name)) continue;
        final flags =
            RegExp(
              r'flags=\d+<([^>]+)>',
            ).firstMatch(block)?.group(1)?.split(',') ??
            [];
        final inactive = RegExp(
          r'^\s*status:\s*inactive\s*$',
          multiLine: true,
        ).hasMatch(block);
        final addresses = <InternetAddress>[];
        final prefixes = <String, int>{};
        for (final match in RegExp(
          r'inet\s+(\d+\.\d+\.\d+\.\d+)\s+netmask\s+0x([a-fA-F0-9]+)',
        ).allMatches(block)) {
          final ip = InternetAddress.tryParse(match.group(1)!);
          if (ip == null || !isUsableLanAddress(ip)) continue;
          addresses.add(ip);
          final bits = int.parse(
            match.group(2)!,
            radix: 16,
          ).toRadixString(2).padLeft(32, '0');
          if (RegExp(r'^1+0*$').hasMatch(bits)) {
            prefixes[ip.address] = bits.replaceAll('0', '').length;
          }
        }
        // NetworkInterface supplies the real index later; these facts match by name.
        output.add(
          LanInterface(
            name: name,
            index: --index,
            addresses: addresses,
            prefixLengths: prefixes,
            kind: kinds[name]!,
            isUp:
                flags.contains('UP') && flags.contains('RUNNING') && !inactive,
            isLan:
                !flags.contains('LOOPBACK') && !flags.contains('POINTOPOINT'),
            hasDefaultRoute: name == defaultName,
            metric: name == defaultName ? 0 : 2147483647,
          ),
        );
      }
      return output;
    } catch (_) {
      return null;
    }
  }
}
