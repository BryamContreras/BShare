import 'dart:async';

class IncomingTransfer {
  IncomingTransfer({
    required this.id,
    required this.senderName,
    required this.senderId,
    required this.fileName,
    required this.size,
    required this.createdAt,
    required this.decision,
    this.controlHost,
    this.controlPort,
  });

  final String id;
  final String senderName;
  final String senderId;
  final String fileName;
  final int size;
  final DateTime createdAt;
  final Completer<bool> decision;
  final String? controlHost;
  final int? controlPort;
}
