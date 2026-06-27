import 'package:bshare/src/domain/entities/transfer_progress_status.dart';

class SendProgress {
  const SendProgress({
    required this.id,
    required this.fileName,
    required this.sentBytes,
    required this.totalBytes,
    required this.bytesPerSecond,
    required this.status,
    this.message,
  });

  final String id;
  final String fileName;
  final int sentBytes;
  final int totalBytes;
  final double bytesPerSecond;
  final TransferProgressStatus status;
  final String? message;

  double get fraction => totalBytes == 0 ? 0 : sentBytes / totalBytes;

  bool get isDone => status.isTerminal;

  SendProgress copyWith({
    int? sentBytes,
    double? bytesPerSecond,
    TransferProgressStatus? status,
    String? message,
    bool clearMessage = false,
  }) {
    return SendProgress(
      id: id,
      fileName: fileName,
      sentBytes: sentBytes ?? this.sentBytes,
      totalBytes: totalBytes,
      bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
      status: status ?? this.status,
      message: clearMessage ? null : message ?? this.message,
    );
  }
}
