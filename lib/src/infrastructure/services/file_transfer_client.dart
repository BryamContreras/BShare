import 'dart:async';
import 'dart:io';

import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/domain/entities/send_progress.dart';
import 'package:bshare/src/domain/entities/selected_transfer_file.dart';
import 'package:bshare/src/domain/entities/transfer_control.dart';
import 'package:bshare/src/domain/entities/transfer_progress_status.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/transfer_speed_meter.dart';
import 'package:dio/dio.dart';
import 'package:http_parser/http_parser.dart';
import 'package:path/path.dart' as p;

class FileTransferClient {
  FileTransferClient(this._logger);

  static const _maximumConcurrentTransfers = 3;

  final AppLogger _logger;
  final Set<Dio> _clients = {};
  final Set<TransferControl> _activeControls = {};
  bool _disposed = false;

  Dio _client({Duration receiveTimeout = const Duration(hours: 12)}) {
    final client = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: receiveTimeout,
      ),
    );
    _clients.add(client);
    return client;
  }

  void dispose() {
    _disposed = true;
    for (final control in _activeControls.toList()) {
      control.cancel();
    }
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    _clients.clear();
  }

  Stream<SendProgress> sendFiles({
    required DeviceInfo target,
    required List<SelectedTransferFile> files,
    required String senderId,
    required String senderName,
    required Map<String, TransferControl> controls,
  }) {
    final uniqueFiles = {
      for (final file in files) file.path: file,
    }.values.toList();
    final transferControls = {
      for (final file in uniqueFiles)
        file.path: controls[file.path] ?? TransferControl(),
    };
    late final StreamController<SendProgress> controller;
    controller = StreamController<SendProgress>(
      onListen: () => unawaited(
        _sendFiles(
          controller,
          target,
          uniqueFiles,
          senderId,
          senderName,
          transferControls,
        ),
      ),
      onCancel: () {
        for (final control in transferControls.values) {
          control.cancel();
        }
      },
    );
    return controller.stream;
  }

  Stream<SendProgress> sendFile({
    required DeviceInfo target,
    required SelectedTransferFile file,
    required String transferId,
    required String senderId,
    required String senderName,
    required TransferControl control,
    String? controlHost,
    int? controlPort,
  }) {
    late final StreamController<SendProgress> controller;
    controller = StreamController<SendProgress>(
      onListen: () => unawaited(
        _sendOne(
          controller,
          target,
          file,
          transferId,
          senderId,
          senderName,
          control,
          controlHost,
          controlPort,
        ).whenComplete(() => unawaited(controller.close())),
      ),
      onCancel: control.cancel,
    );
    return controller.stream;
  }

  Future<void> _sendFiles(
    StreamController<SendProgress> controller,
    DeviceInfo target,
    List<SelectedTransferFile> files,
    String senderId,
    String senderName,
    Map<String, TransferControl> controls,
  ) async {
    if (files.isEmpty) {
      await controller.close();
      return;
    }

    if (_disposed) {
      await controller.close();
      return;
    }
    final transferIds = {
      for (var index = 0; index < files.length; index++)
        files[index].path: _transferId(senderId, files[index], index),
    };
    await announceQueue(
      target: target,
      files: files,
      transferIds: transferIds,
      senderId: senderId,
      senderName: senderName,
    );

    for (var index = 0; index < files.length; index++) {
      final file = files[index];
      controller.add(
        SendProgress(
          id: file.path,
          fileName: file.name,
          sentBytes: 0,
          totalBytes: file.size,
          bytesPerSecond: 0,
          status: TransferProgressStatus.queued,
        ),
      );
    }

    var nextIndex = 0;
    Future<void> worker() async {
      while (nextIndex < files.length) {
        final index = nextIndex++;
        final file = files[index];
        await _sendOne(
          controller,
          target,
          file,
          transferIds[file.path]!,
          senderId,
          senderName,
          controls[file.path]!,
          null,
          null,
        );
      }
    }

    try {
      await Future.wait(
        List.generate(_maximumConcurrentTransfers, (_) => worker()),
      );
    } finally {
      await controller.close();
    }
  }

  Future<void> _sendOne(
    StreamController<SendProgress> controller,
    DeviceInfo target,
    SelectedTransferFile selected,
    String transferId,
    String senderId,
    String senderName,
    TransferControl control,
    String? controlHost,
    int? controlPort,
  ) async {
    final path = selected.path;
    final file = File(path);
    var total = selected.size;
    final speedMeter = TransferSpeedMeter()..record(0);
    var lastSent = 0;
    final progressClock = Stopwatch()..start();
    var lastProgressAt = 0;
    final cancelToken = CancelToken();
    if (_disposed || control.isCancelled) {
      controller.add(
        SendProgress(
          id: path,
          fileName: selected.name,
          sentBytes: 0,
          totalBytes: total,
          bytesPerSecond: 0,
          status: TransferProgressStatus.cancelled,
        ),
      );
      return;
    }
    final detachCancellation = control.onCancel(
      () => cancelToken.cancel('Transfer cancelled'),
    );
    _activeControls.add(control);
    Dio? dio;
    try {
      total = await file.length();
      await control.waitIfPaused();
      if (_disposed) throw const TransferCancelledException();
      controller.add(
        SendProgress(
          id: path,
          fileName: selected.name,
          sentBytes: 0,
          totalBytes: total,
          bytesPerSecond: 0,
          status: control.isPaused
              ? TransferProgressStatus.paused
              : TransferProgressStatus.sending,
        ),
      );
      dio = _client();
      final headers = <String, Object>{
        Headers.contentLengthHeader: total,
        'x-bshare-file-name': Uri.encodeComponent(
          selected.relativePath ?? p.basename(path),
        ),
        'x-bshare-file-size': total.toString(),
        'x-bshare-transfer-id': Uri.encodeComponent(transferId),
        'x-bshare-sender-id': senderId,
        'x-bshare-sender-name': Uri.encodeComponent(senderName),
      };
      if (controlHost != null) {
        headers['x-bshare-control-host'] = controlHost;
      }
      if (controlPort != null) {
        headers['x-bshare-control-port'] = controlPort.toString();
      }
      final response = await dio.postUri(
        target.baseUri.replace(path: '/api/transfers'),
        data: _controlledRead(file, control, cancelToken),
        options: Options(
          headers: headers,
          contentType: MediaType('application', 'octet-stream').toString(),
          responseType: ResponseType.json,
        ),
        cancelToken: cancelToken,
        onSendProgress: (sent, _) {
          lastSent = sent;
          final elapsed = progressClock.elapsedMilliseconds;
          if (elapsed - lastProgressAt < 100 && !control.isPaused) return;
          lastProgressAt = elapsed;
          controller.add(
            SendProgress(
              id: path,
              fileName: selected.name,
              sentBytes: sent,
              totalBytes: total,
              bytesPerSecond: speedMeter.record(sent),
              status: control.isPaused
                  ? TransferProgressStatus.paused
                  : TransferProgressStatus.sending,
            ),
          );
        },
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        controller.add(
          SendProgress(
            id: path,
            fileName: selected.name,
            sentBytes: total,
            totalBytes: total,
            bytesPerSecond: speedMeter.record(total),
            status: TransferProgressStatus.completed,
          ),
        );
      } else {
        final httpMessage = 'HTTP ${response.statusCode ?? 'unknown'}';
        controller.add(
          SendProgress(
            id: path,
            fileName: selected.name,
            sentBytes: lastSent,
            totalBytes: total,
            bytesPerSecond: speedMeter.record(lastSent),
            status: control.isCancelled
                ? TransferProgressStatus.cancelled
                : TransferProgressStatus.failed,
            message: control.isCancelled ? null : httpMessage,
          ),
        );
      }
    } catch (error) {
      if (control.isCancelled && !cancelToken.isCancelled) {
        cancelToken.cancel();
      }
      _logger.error('Send failed', error);
      final receiverCancelled = _isReceiverCancelled(error);
      controller.add(
        SendProgress(
          id: path,
          fileName: selected.name,
          sentBytes: lastSent,
          totalBytes: total,
          bytesPerSecond: speedMeter.record(lastSent),
          status:
              control.isCancelled ||
                  error is TransferCancelledException ||
                  receiverCancelled
              ? TransferProgressStatus.cancelled
              : TransferProgressStatus.failed,
          message:
              control.isCancelled ||
                  error is TransferCancelledException ||
                  receiverCancelled
              ? null
              : _failureMessage(error),
        ),
      );
    } finally {
      detachCancellation();
      _activeControls.remove(control);
      dio?.close(force: true);
      _clients.remove(dio);
    }
  }

  bool _isReceiverCancelled(Object error) {
    if (error is! DioException) return false;
    if (error.response?.statusCode == 499) return true;
    final data = error.response?.data?.toString().toLowerCase() ?? '';
    return data.contains('cancelled');
  }

  String _failureMessage(Object error) {
    if (error is DioException) {
      final statusCode = error.response?.statusCode;
      final body = error.response?.data;
      final message = error.message;
      final parts = [
        if (statusCode != null) 'HTTP $statusCode',
        if (body != null && body.toString().trim().isNotEmpty) body.toString(),
        if (message != null && message.trim().isNotEmpty) message,
      ];
      if (parts.isNotEmpty) return parts.join(' - ');
    }
    return error.toString();
  }

  Stream<List<int>> _controlledRead(
    File file,
    TransferControl control,
    CancelToken cancelToken,
  ) async* {
    if (cancelToken.isCancelled) return;
    final handle = await file.open();
    try {
      const chunkSize = 256 * 1024;
      while (!cancelToken.isCancelled) {
        await control.waitIfPaused();
        final chunk = await handle.read(chunkSize);
        if (chunk.isEmpty) break;
        yield chunk;
      }
    } on TransferCancelledException {
      // Dio cancels its body subscription immediately when the token fires.
      // A paused reader can resume after that cancellation; do not forward a
      // late stream error to an already detached HTTP subscription.
      if (!cancelToken.isCancelled) cancelToken.cancel('Transfer cancelled');
    } finally {
      await handle.close();
    }
  }

  Future<void> announceQueue({
    required DeviceInfo target,
    required List<SelectedTransferFile> files,
    required Map<String, String> transferIds,
    required String senderId,
    required String senderName,
    String? controlHost,
    int? controlPort,
  }) async {
    if (_disposed) return;
    final dio = _client(receiveTimeout: const Duration(seconds: 8));
    try {
      final data = <String, Object?>{
        'senderId': senderId,
        'senderName': senderName,
        'files': [
          for (var index = 0; index < files.length; index++)
            {
              'id': transferIds[files[index].path],
              'name': files[index].relativePath ?? files[index].name,
              'size': files[index].size,
            },
        ],
      };
      if (controlHost != null) data['controlHost'] = controlHost;
      if (controlPort != null) data['controlPort'] = controlPort;
      await dio.postUri(
        target.baseUri.replace(path: '/api/transfers/queue'),
        data: data,
        options: Options(responseType: ResponseType.json),
      );
    } catch (error) {
      _logger.warn('Receiver does not support queue preview: $error');
    } finally {
      dio.close(force: true);
      _clients.remove(dio);
    }
  }

  String _transferId(String senderId, SelectedTransferFile file, int index) =>
      '$senderId:$index:${file.name}:${file.size}';
}
