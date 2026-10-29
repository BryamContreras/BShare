import 'dart:io';

/// An interface and the facts supplied by its operating system.
class LanInterface {
  const LanInterface({
    required this.name,
    required this.index,
    required this.addresses,
    this.prefixLengths = const {},
    this.kind = 'other',
    this.isUp = true,
    this.isLan,
    this.hasDefaultRoute = false,
    this.metric = 2147483647,
    this.isHosted = false,
  });

  final String name;
  final int index;
  final List<InternetAddress> addresses;
  final Map<String, int> prefixLengths;
  final String kind;
  final bool isUp;

  /// Null means that only Dart enumeration was available, without link data.
  final bool? isLan;
  final bool hasDefaultRoute;
  final int metric;
  final bool isHosted;

  LanInterface withAddresses(List<InternetAddress> values) => LanInterface(
    name: name,
    index: index,
    addresses: List.unmodifiable(values),
    prefixLengths: Map.unmodifiable(prefixLengths),
    kind: kind,
    isUp: isUp,
    isLan: isLan,
    hasDefaultRoute: hasDefaultRoute,
    metric: metric,
    isHosted: isHosted,
  );

  static LanInterface? fromPlatform(Object? value) {
    if (value is! Map || value['index'] is! int || value['name'] is! String) {
      return null;
    }
    final addresses = <InternetAddress>[];
    final prefixes = <String, int>{};
    final rawAddresses = value['addresses'];
    if (rawAddresses is List) {
      for (final item in rawAddresses) {
        if (item is! Map || item['ip'] is! String) continue;
        final ip = InternetAddress.tryParse(item['ip'] as String);
        if (ip == null || !isUsableLanAddress(ip)) continue;
        addresses.add(ip);
        final prefix = item['prefixLength'];
        if (prefix is int && prefix >= 1 && prefix <= 32) {
          prefixes[ip.address] = prefix;
        }
      }
    }
    return LanInterface(
      name: value['name'] as String,
      index: value['index'] as int,
      addresses: List.unmodifiable(addresses),
      prefixLengths: Map.unmodifiable(prefixes),
      kind: value['kind'] is String ? value['kind'] as String : 'other',
      isUp: value['isUp'] == true,
      isLan: value['isLan'] == true,
      hasDefaultRoute: value['hasDefaultRoute'] == true,
      metric: value['metric'] is int ? value['metric'] as int : 2147483647,
      isHosted: value['isHosted'] == true,
    );
  }
}

/// LAN addresses can be public or link-local; RFC1918 is not a requirement.
bool isUsableLanAddress(InternetAddress address) {
  if (address.type != InternetAddressType.IPv4) return false;
  final first = address.rawAddress.first;
  return first != 0 && first != 127 && first < 224;
}

bool sameIpv4Subnet(InternetAddress local, InternetAddress remote, int prefix) {
  if (local.type != InternetAddressType.IPv4 ||
      remote.type != InternetAddressType.IPv4 ||
      prefix < 1 ||
      prefix > 32) {
    return false;
  }
  final left = local.rawAddress;
  final right = remote.rawAddress;
  for (var byte = 0; byte < 4; byte++) {
    final bits = (prefix - byte * 8).clamp(0, 8);
    final mask = (0xff << (8 - bits)) & 0xff;
    if ((left[byte] & mask) != (right[byte] & mask)) return false;
  }
  return true;
}
