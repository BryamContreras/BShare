import 'dart:async';
import 'dart:io';

import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/domain/entities/send_progress.dart';
import 'package:bshare/src/domain/entities/selected_transfer_file.dart';
import 'package:bshare/src/domain/entities/transfer_control.dart';
import 'package:bshare/src/domain/entities/transfer_progress_status.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:dio/dio.dart';
import 'package:http_parser/http_parser.dart';
import 'package:path/path.dart' as p;

class FileTransferClient {
  FileTransferClient(this._logger);

  final AppLogger _logger;

  Dio _client({Duration receiveTimeout = const Duration(hours: 12)}) {
    return Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: receiveTimeout,
      ),
    );
  }

  void dispose() {}

  Stream<SendProgress> sendFiles({
    required DeviceInfo target,
    required List<SelectedTransferFile> files,
    required String senderId,
    required String senderName,
    required Map<String, TransferControl> controls,
  }) {
    final controller = StreamController<SendProgress>();
    unawaited(
      _sendFiles(controller, target, files, senderId, senderName, controls),
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
    final controller = StreamController<SendProgress>();
    unawaited(
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
      ).whenComplete(controller.close),
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
    var active = 0;
    final done = Completer<void>();

    void pump() {
      while (active < 3 && nextIndex < files.length) {
        final index = nextIndex++;
        final file = files[index];
        active++;
        unawaited(
          _sendOne(
            controller,
            target,
            file,
            transferIds[file.path]!,
            senderId,
            senderName,
            controls[file.path]!,
            null,
            null,
          ).whenComplete(() {
            active--;
            if (nextIndex >= files.length && active == 0) {
              done.complete();
            } else {
              pump();
            }
          }),
        );
      }
    }

    pump();
    await done.future;
    await controller.close();
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
    final total = await file.length();
    final started = DateTime.now();
    var lastSent = 0;
    final cancelToken = CancelToken();
    if (control.isCancelled) {
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
    final dio = _client();
    try {
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
          final elapsed =
              DateTime.now().difference(started).inMilliseconds / 1000;
          controller.add(
            SendProgress(
              id: path,
              fileName: selected.name,
              sentBytes: sent,
              totalBytes: total,
              bytesPerSecond: elapsed <= 0 ? 0 : sent / elapsed,
              status: control.isPaused
                  ? TransferProgressStatus.paused
                  : TransferProgressStatus.sending,
            ),
          );
        },
      );

      final elapsed = DateTime.now().difference(started).inMilliseconds / 1000;
      if (response.statusCode == 200 || response.statusCode == 201) {
        controller.add(
          SendProgress(
            id: path,
            fileName: selected.name,
            sentBytes: total,
            totalBytes: total,
            bytesPerSecond: elapsed == 0 ? 0 : total / elapsed,
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
            bytesPerSecond: elapsed == 0 ? 0 : lastSent / elapsed,
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
      final elapsed = DateTime.now().difference(started).inMilliseconds / 1000;
      final receiverCancelled = _isReceiverCancelled(error);
      controller.add(
        SendProgress(
          id: path,
          fileName: selected.name,
          sentBytes: lastSent,
          totalBytes: total,
          bytesPerSecond: elapsed == 0 ? 0 : lastSent / elapsed,
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
      dio.close(force: true);
    }
  }

  bool _isReceiverCancelled(Object error) {
    if (error is! DioException) return false;
    if (error.response?.statusCode == 499) return true;
    final data = error.response?.data?.toString().toLowerCase() ?? '';
    final message = error.message?.toLowerCase() ?? '';
    return data.contains('cancelled') ||
        message.contains('cancelled') ||
        message.contains('connection reset') ||
        message.contains('broken pipe') ||
        message.contains('connection closed');
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
        if (control.isPaused) {
          await control.waitIfPaused();
          continue;
        }
        if (control.isCancelled) break;
        final chunk = await handle.read(chunkSize);
        if (chunk.isEmpty) break;
        yield chunk;
      }
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
    }
  }

  String _transferId(String senderId, SelectedTransferFile file, int index) =>
      '$senderId:$index:${file.name}:${file.size}';
}
