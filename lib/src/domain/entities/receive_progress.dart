import 'package:bshare/src/domain/entities/transfer_progress_status.dart';

class ReceiveProgress {
  const ReceiveProgress({
    required this.id,
    required this.fileName,
    required this.receivedBytes,
    required this.totalBytes,
    required this.bytesPerSecond,
    required this.status,
    this.message,
    this.savedPath,
    this.controlHost,
    this.controlPort,
  });

  final String id;
  final String fileName;
  final int receivedBytes;
  final int totalBytes;
  final double bytesPerSecond;
  final TransferProgressStatus status;
  final String? message;
  final String? savedPath;
  final String? controlHost;
  final int? controlPort;

  double get fraction => totalBytes <= 0 ? 0 : receivedBytes / totalBytes;

  ReceiveProgress copyWith({
    int? receivedBytes,
    double? bytesPerSecond,
    TransferProgressStatus? status,
    String? message,
    bool clearMessage = false,
    String? savedPath,
    String? controlHost,
    int? controlPort,
  }) {
    return ReceiveProgress(
      id: id,
      fileName: fileName,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes,
      bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
      status: status ?? this.status,
      message: clearMessage ? null : message ?? this.message,
      savedPath: savedPath ?? this.savedPath,
      controlHost: controlHost ?? this.controlHost,
      controlPort: controlPort ?? this.controlPort,
    );
  }
}
