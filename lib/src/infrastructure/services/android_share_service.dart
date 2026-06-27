import 'dart:async';
import 'dart:io';

import 'package:bshare/src/domain/entities/selected_transfer_file.dart';
import 'package:flutter/services.dart';

class AndroidShareService {
  AndroidShareService() {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static const _channel = MethodChannel('bshare/share');
  final _sharedFiles = StreamController<List<SelectedTransferFile>>.broadcast();

  Stream<List<SelectedTransferFile>> get sharedFiles => _sharedFiles.stream;

  Future<List<SelectedTransferFile>> takeInitialSharedFiles() async {
    if (!Platform.isAndroid) return const [];
    final raw = await _channel.invokeListMethod<Object?>(
      'getInitialSharedFiles',
    );
    return _filesFromRaw(raw);
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method != 'onSharedFiles') return null;
    final files = _filesFromRaw(call.arguments);
    if (files.isNotEmpty) _sharedFiles.add(files);
    return null;
  }

  List<SelectedTransferFile> _filesFromRaw(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) => item.cast<String, Object?>())
        .map(_fileFromMap)
        .whereType<SelectedTransferFile>()
        .toList();
  }

  SelectedTransferFile? _fileFromMap(Map<String, Object?> map) {
    final path = map['path']?.toString();
    final name = map['name']?.toString();
    final size = (map['size'] as num?)?.toInt();
    if (path == null || path.isEmpty || name == null || name.isEmpty) {
      return null;
    }
    return SelectedTransferFile(
      path: path,
      name: name,
      size: size ?? 0,
      deleteAfterSend: true,
    );
  }

  Future<void> dispose() async {
    if (Platform.isAndroid) {
      _channel.setMethodCallHandler(null);
    }
    await _sharedFiles.close();
  }
}
