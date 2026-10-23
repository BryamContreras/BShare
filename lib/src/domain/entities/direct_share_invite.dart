import 'dart:convert';
import 'dart:io';

import 'package:bshare/src/domain/entities/device_info.dart';

class DirectNetworkCredentials {
  const DirectNetworkCredentials({
    required this.ssid,
    required this.password,
    this.securityType = 'WPA2',
  });

  final String ssid;
  final String password;
  final String securityType;

  Map<String, dynamic> toJson() => {
    'ssid': ssid,
    'password': password,
    'securityType': securityType,
  };

  factory DirectNetworkCredentials.fromJson(Map<String, dynamic> json) =>
      DirectNetworkCredentials(
        ssid: json['ssid']?.toString() ?? '',
        password: json['password']?.toString() ?? '',
        securityType: json['securityType']?.toString() ?? 'WPA2',
      );
}

class DirectShareInvite {
  const DirectShareInvite({
    required this.credentials,
    required this.device,
    this.version = 1,
  });

  static const type = 'bshare.direct';

  final DirectNetworkCredentials credentials;
  final DeviceInfo device;
  final int version;

  String encode() => jsonEncode({
    'type': type,
    'version': version,
    'network': credentials.toJson(),
    'device': device.toJson(),
  });

  factory DirectShareInvite.decode(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('A BShare invite must be an object');
    }
    final json = decoded;
    if (json['type'] != type) {
      throw const FormatException('Not a BShare direct invite');
    }
    final version = json['version'] ?? 1;
    if (version != 1 || version is! int) {
      throw const FormatException('Unsupported BShare invite version');
    }
    final network = json['network'];
    final device = json['device'];
    if (network is! Map<String, dynamic> || device is! Map<String, dynamic>) {
      throw const FormatException('Missing BShare network or device');
    }
    final ssid = network['ssid'];
    final password = network['password'];
    final security = network['securityType'] ?? 'WPA2';
    if (ssid is! String ||
        ssid.isEmpty ||
        utf8.encode(ssid).length > 32 ||
        password is! String ||
        !const ['WPA2', 'WPA3', 'OPEN'].contains(security) ||
        (security != 'OPEN' && (password.length < 8 || password.length > 63))) {
      throw const FormatException('Invalid BShare Wi-Fi credentials');
    }
    final ip = device['ip'];
    final port = device['port'];
    if (device['id'] is! String ||
        (device['id'] as String).isEmpty ||
        device['name'] is! String ||
        device['platform'] is! String ||
        ip is! String ||
        InternetAddress.tryParse(ip) == null ||
        port is! int ||
        port < 1 ||
        port > 65535 ||
        (device['lastSeen'] != null && device['lastSeen'] is! String)) {
      throw const FormatException('Invalid BShare receiver address');
    }
    return DirectShareInvite(
      version: version,
      credentials: DirectNetworkCredentials.fromJson(network),
      device: DeviceInfo.fromJson(device),
    );
  }
}
