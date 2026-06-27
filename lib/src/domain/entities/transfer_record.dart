import 'dart:convert';

enum TransferDirection { sent, received }

enum TransferStatus {
  pending,
  accepted,
  rejected,
  completed,
  failed,
  interrupted,
}

class TransferRecord {
  const TransferRecord({
    required this.id,
    required this.direction,
    required this.fileName,
    required this.size,
    required this.createdAt,
    required this.remoteDevice,
    required this.status,
    this.error,
  });

  final String id;
  final TransferDirection direction;
  final String fileName;
  final int size;
  final DateTime createdAt;
  final String remoteDevice;
  final TransferStatus status;
  final String? error;

  Map<String, dynamic> toJson() => {
    'id': id,
    'direction': direction.name,
    'fileName': fileName,
    'size': size,
    'createdAt': createdAt.toIso8601String(),
    'remoteDevice': remoteDevice,
    'status': status.name,
    'error': error,
  };

  factory TransferRecord.fromJson(Map<String, dynamic> json) => TransferRecord(
    id: json['id'] as String,
    direction: TransferDirection.values.byName(json['direction'] as String),
    fileName: json['fileName'] as String,
    size: (json['size'] as num).toInt(),
    createdAt: DateTime.parse(json['createdAt'] as String),
    remoteDevice: json['remoteDevice'] as String,
    status: TransferStatus.values.byName(json['status'] as String),
    error: json['error'] as String?,
  );

  String encode() => jsonEncode(toJson());

  factory TransferRecord.decode(String value) =>
      TransferRecord.fromJson(jsonDecode(value) as Map<String, dynamic>);
}
