import 'dart:convert';

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
    final json = jsonDecode(value) as Map<String, dynamic>;
    if (json['type'] != type) {
      throw const FormatException('Not a BShare direct invite');
    }
    return DirectShareInvite(
      version: (json['version'] as num?)?.toInt() ?? 1,
      credentials: DirectNetworkCredentials.fromJson(
        json['network'] as Map<String, dynamic>,
      ),
      device: DeviceInfo.fromJson(json['device'] as Map<String, dynamic>),
    );
  }
}
