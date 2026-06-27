import 'dart:convert';

class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.name,
    required this.platform,
    required this.ip,
    required this.port,
    required this.lastSeen,
  });

  final String id;
  final String name;
  final String platform;
  final String ip;
  final int port;
  final DateTime lastSeen;

  Uri get baseUri => Uri(scheme: 'http', host: ip, port: port);

  DeviceInfo copyWith({
    DateTime? lastSeen,
    String? ip,
    int? port,
    String? name,
  }) {
    return DeviceInfo(
      id: id,
      name: name ?? this.name,
      platform: platform,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'platform': platform,
    'ip': ip,
    'port': port,
    'lastSeen': lastSeen.toIso8601String(),
  };

  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
    id: json['id'] as String,
    name: json['name'] as String,
    platform: json['platform'] as String,
    ip: json['ip'] as String,
    port: (json['port'] as num).toInt(),
    lastSeen:
        DateTime.tryParse(json['lastSeen'] as String? ?? '') ?? DateTime.now(),
  );

  String encode() => jsonEncode(toJson());

  factory DeviceInfo.decode(String value) =>
      DeviceInfo.fromJson(jsonDecode(value) as Map<String, dynamic>);
}
