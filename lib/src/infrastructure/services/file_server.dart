import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bshare/src/domain/entities/incoming_transfer.dart';
import 'package:bshare/src/domain/entities/transfer_control.dart';
import 'package:bshare/src/domain/entities/transfer_progress_status.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

typedef IncomingTransferHandler =
    Future<bool> Function(IncomingTransfer transfer);
typedef TransferSavedHandler =
    Future<void> Function({
      required IncomingTransfer transfer,
      required String savedPath,
    });
typedef ReceiveProgressHandler =
    void Function({
      required IncomingTransfer transfer,
      required int receivedBytes,
      required int totalBytes,
      required double bytesPerSecond,
      required TransferProgressStatus status,
      String? message,
      String? savedPath,
    });
typedef ReceiveQueueHandler =
    void Function({
      required String senderId,
      required String senderName,
      required List<IncomingTransfer> transfers,
      String? controlHost,
      int? controlPort,
    });
typedef ReceiveControlResolver = TransferControl Function(String id);
typedef TransferCommandHandler =
    Future<void> Function(String transferId, String action);
typedef ScreenOfferHandler =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> offer);
typedef ScreenMetadataHandler = Map<String, dynamic> Function();

class FileServer {
  FileServer(this._logger);

  final AppLogger _logger;
  HttpServer? _server;
  ScreenOfferHandler? screenOfferHandler;
  ScreenMetadataHandler? screenMetadataHandler;
  TransferCommandHandler? transferCommandHandler;

  int? get port => _server?.port;
  bool get isRunning => _server != null;

  Future<int> start({
    required int preferredPort,
    required String downloadDirectory,
    required bool autoAccept,
    required IncomingTransferHandler onIncoming,
    required TransferSavedHandler onSaved,
    required ReceiveProgressHandler onProgress,
    required ReceiveQueueHandler onQueue,
    required ReceiveControlResolver resolveControl,
  }) async {
    if (_server != null) return _server!.port;
    _server = await _bindAvailableServer(preferredPort);
    _logger.info('HTTP receiver listening on ${_server!.port}');
    unawaited(
      _serve(
        downloadDirectory,
        autoAccept,
        onIncoming,
        onSaved,
        onProgress,
        onQueue,
        resolveControl,
      ),
    );
    return _server!.port;
  }

  Future<HttpServer> _bindAvailableServer(int preferredPort) async {
    final ports = _candidatePorts(preferredPort);
    SocketException? lastSocketError;
    Object? lastError;

    for (final port in ports) {
      try {
        return await HttpServer.bind(
          InternetAddress.anyIPv4,
          port,
          shared: true,
        );
      } on SocketException catch (error) {
        lastSocketError = error;
        _logger.warn('Port $port unavailable: $error');
      } catch (error) {
        lastError = error;
        _logger.warn('Could not bind port $port: $error');
      }
    }

    throw lastSocketError ??
        StateError('No receiver port could be opened: ${lastError ?? ''}');
  }

  List<int> _candidatePorts(int preferredPort) {
    final candidates = <int>{};
    if (_isValidPort(preferredPort)) {
      candidates.add(preferredPort);
      for (var offset = 1; offset <= 20; offset++) {
        final next = preferredPort + offset;
        if (_isValidPort(next)) candidates.add(next);
      }
    }
    candidates.add(0);
    return candidates.toList(growable: false);
  }

  bool _isValidPort(int port) => port > 0 && port <= 65535;

  Future<void> _serve(
    String downloadDirectory,
    bool autoAccept,
    IncomingTransferHandler onIncoming,
    TransferSavedHandler onSaved,
    ReceiveProgressHandler onProgress,
    ReceiveQueueHandler onQueue,
    ReceiveControlResolver resolveControl,
  ) async {
    final server = _server;
    if (server == null) return;
    await for (final request in server) {
      if (request.method == 'GET' && request.uri.path == '/api/ping') {
        _json(request.response, {'ok': true});
        continue;
      }
      if (request.method == 'POST' && request.uri.path == '/api/screen/offer') {
        await _handleScreenOffer(request);
        continue;
      }
      if (request.method == 'GET' &&
          request.uri.path == '/api/screen/metadata') {
        _handleScreenMetadata(request);
        continue;
      }
      if (request.method == 'POST' &&
          request.uri.path == '/api/transfers/queue') {
        await _handleTransferQueue(request, onQueue);
        continue;
      }
      if (request.method == 'POST' &&
          request.uri.path == '/api/transfers/control') {
        await _handleTransferControl(request);
        continue;
      }
      if (request.method != 'POST' || request.uri.path != '/api/transfers') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        continue;
      }
      unawaited(
        _handleTransfer(
          request,
          downloadDirectory,
          autoAccept,
          onIncoming,
          onSaved,
          onProgress,
          resolveControl,
        ),
      );
    }
  }

  Future<void> _handleScreenOffer(HttpRequest request) async {
    final handler = screenOfferHandler;
    if (handler == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      _json(request.response, {
        'ok': false,
        'error': 'screen-share-not-active',
      });
      return;
    }
    try {
      final body = await utf8.decoder.bind(request).join();
      final answer = await handler(jsonDecode(body) as Map<String, dynamic>);
      _json(request.response, {'ok': true, 'answer': answer});
    } catch (error) {
      _logger.error('Screen signaling failed', error);
      request.response.statusCode = HttpStatus.internalServerError;
      _json(request.response, {'ok': false, 'error': error.toString()});
    }
  }

  void _handleScreenMetadata(HttpRequest request) {
    final handler = screenMetadataHandler;
    if (handler == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      _json(request.response, {
        'ok': false,
        'error': 'screen-share-not-active',
      });
      return;
    }
    try {
      _json(request.response, {'ok': true, 'metadata': handler()});
    } catch (error) {
      _logger.error('Screen metadata failed', error);
      request.response.statusCode = HttpStatus.internalServerError;
      _json(request.response, {'ok': false, 'error': error.toString()});
    }
  }

  Future<void> _handleTransferQueue(
    HttpRequest request,
    ReceiveQueueHandler onQueue,
  ) async {
    try {
      final body = await utf8.decoder.bind(request).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final senderId = json['senderId']?.toString() ?? 'unknown';
      final senderName = json['senderName']?.toString() ?? 'Unknown device';
      final controlHost =
          json['controlHost']?.toString() ??
          request.connectionInfo?.remoteAddress.address;
      final controlPort = (json['controlPort'] as num?)?.toInt();
      final files = json['files'] as List<dynamic>? ?? const [];
      final transfers = files
          .whereType<Map<String, dynamic>>()
          .map(
            (file) => IncomingTransfer(
              id: file['id']?.toString() ?? const Uuid().v4(),
              senderName: senderName,
              senderId: senderId,
              fileName: file['name']?.toString() ?? 'incoming-file',
              size: (file['size'] as num?)?.toInt() ?? 0,
              createdAt: DateTime.now(),
              decision: Completer<bool>(),
              controlHost: controlHost,
              controlPort: controlPort,
            ),
          )
          .toList();
      onQueue(
        senderId: senderId,
        senderName: senderName,
        transfers: transfers,
        controlHost: controlHost,
        controlPort: controlPort,
      );
      _json(request.response, {'ok': true});
    } catch (error) {
      _logger.error('Receive queue update failed', error);
      request.response.statusCode = HttpStatus.badRequest;
      _json(request.response, {'ok': false, 'error': error.toString()});
    }
  }

  Future<void> _handleTransferControl(HttpRequest request) async {
    final handler = transferCommandHandler;
    if (handler == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      _json(request.response, {'ok': false, 'error': 'control-not-active'});
      return;
    }
    try {
      final body = await utf8.decoder.bind(request).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final id = json['id']?.toString();
      final action = json['action']?.toString();
      if (id == null || action == null) {
        request.response.statusCode = HttpStatus.badRequest;
        _json(request.response, {'ok': false, 'error': 'invalid-control'});
        return;
      }
      await handler(id, action);
      _json(request.response, {'ok': true});
    } catch (error) {
      _logger.error('Transfer control failed', error);
      request.response.statusCode = HttpStatus.internalServerError;
      _json(request.response, {'ok': false, 'error': error.toString()});
    }
  }

  Future<void> _handleTransfer(
    HttpRequest request,
    String downloadDirectory,
    bool autoAccept,
    IncomingTransferHandler onIncoming,
    TransferSavedHandler onSaved,
    ReceiveProgressHandler onProgress,
    ReceiveControlResolver resolveControl,
  ) async {
    final id = Uri.decodeComponent(
      request.headers.value('x-bshare-transfer-id') ?? const Uuid().v4(),
    );
    final fileName = _safeRelativePath(
      Uri.decodeComponent(
        request.headers.value('x-bshare-file-name') ?? 'incoming-file',
      ),
    );
    final senderName = Uri.decodeComponent(
      request.headers.value('x-bshare-sender-name') ?? 'Unknown device',
    );
    final senderId = request.headers.value('x-bshare-sender-id') ?? 'unknown';
    final controlHost =
        request.headers.value('x-bshare-control-host') ??
        request.connectionInfo?.remoteAddress.address;
    final controlPort = int.tryParse(
      request.headers.value('x-bshare-control-port') ?? '',
    );
    final size =
        int.tryParse(request.headers.value('x-bshare-file-size') ?? '') ??
        request.contentLength;
    final transfer = IncomingTransfer(
      id: id,
      senderName: senderName,
      senderId: senderId,
      fileName: fileName,
      size: size,
      createdAt: DateTime.now(),
      decision: Completer<bool>(),
      controlHost: controlHost,
      controlPort: controlPort,
    );
    final control = resolveControl(transfer.id);

    if (control.isCancelled) {
      request.response.statusCode = 499;
      _json(request.response, {'ok': false, 'status': 'cancelled'});
      onProgress(
        transfer: transfer,
        receivedBytes: 0,
        totalBytes: transfer.size,
        bytesPerSecond: 0,
        status: TransferProgressStatus.cancelled,
      );
      return;
    }

    final accepted =
        autoAccept ||
        await onIncoming(
          transfer,
        ).timeout(const Duration(minutes: 5), onTimeout: () => false);
    if (!accepted) {
      request.response.statusCode = HttpStatus.forbidden;
      _json(request.response, {'ok': false, 'status': 'rejected'});
      return;
    }

    String? targetPath;
    IOSink? sink;
    var received = 0;
    final started = DateTime.now();

    Future<void> cleanupPartialFile() async {
      try {
        await sink?.flush();
        await sink?.close();
      } catch (_) {}
      sink = null;
      if (targetPath != null) {
        try {
          final file = File(targetPath);
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {}
      }
    }

    try {
      final dir = Directory(downloadDirectory);
      if (!await dir.exists()) await dir.create(recursive: true);
      targetPath = await _availablePath(dir.path, transfer.fileName);
      final parent = Directory(p.dirname(targetPath));
      if (!await parent.exists()) await parent.create(recursive: true);
      final file = File(targetPath);
      sink = file.openWrite();
      onProgress(
        transfer: transfer,
        receivedBytes: 0,
        totalBytes: transfer.size,
        bytesPerSecond: 0,
        status: TransferProgressStatus.receiving,
      );
      await for (final chunk in request) {
        await control.waitIfPaused();
        received += chunk.length;
        sink!.add(chunk);
        final elapsed =
            DateTime.now().difference(started).inMilliseconds / 1000;
        onProgress(
          transfer: transfer,
          receivedBytes: received,
          totalBytes: transfer.size,
          bytesPerSecond: elapsed <= 0 ? 0 : received / elapsed,
          status: TransferProgressStatus.receiving,
        );
      }
      await sink!.flush();
      await sink!.close();
      sink = null;

      if (transfer.size > 0 && received < transfer.size) {
        await cleanupPartialFile();
        _logger.warn(
          'Transfer incomplete: received $received of ${transfer.size} bytes',
        );
        request.response.statusCode = HttpStatus.badRequest;
        _json(request.response, {'ok': false, 'error': 'incomplete transfer'});
        onProgress(
          transfer: transfer,
          receivedBytes: received,
          totalBytes: transfer.size,
          bytesPerSecond: 0,
          status: TransferProgressStatus.failed,
          message: 'Incomplete transfer',
        );
        return;
      }

      await onSaved(transfer: transfer, savedPath: targetPath);
      final elapsed = DateTime.now().difference(started).inMilliseconds / 1000;
      onProgress(
        transfer: transfer,
        receivedBytes: received,
        totalBytes: transfer.size,
        bytesPerSecond: elapsed <= 0 ? 0 : received / elapsed,
        status: TransferProgressStatus.completed,
        savedPath: targetPath,
      );
      _json(request.response, {'ok': true, 'path': targetPath});
    } on TransferCancelledException {
      await cleanupPartialFile();
      request.response.statusCode = 499;
      _json(request.response, {'ok': false, 'status': 'cancelled'});
      onProgress(
        transfer: transfer,
        receivedBytes: received,
        totalBytes: transfer.size,
        bytesPerSecond: 0,
        status: TransferProgressStatus.cancelled,
      );
    } catch (error) {
      await cleanupPartialFile();
      _logger.error('Receive failed', error);
      onProgress(
        transfer: transfer,
        receivedBytes: received,
        totalBytes: transfer.size,
        bytesPerSecond: 0,
        status: TransferProgressStatus.failed,
        message: error.toString(),
      );
      request.response.statusCode = HttpStatus.internalServerError;
      _json(request.response, {'ok': false, 'error': error.toString()});
    }
  }

  String _safeRelativePath(String input) {
    final normalized = p.normalize(input).replaceAll('\\', '/');
    final parts = normalized
        .split('/')
        .where((part) => part.isNotEmpty && part != '.' && part != '..')
        .toList();
    if (parts.isEmpty) return 'incoming-file';
    return p.joinAll(parts);
  }

  Future<String> _availablePath(String dir, String fileName) async {
    var candidate = p.join(dir, fileName);
    if (!await File(candidate).exists()) return candidate;
    final relativeDir = p.dirname(fileName);
    final ext = p.extension(fileName);
    final base = p.basenameWithoutExtension(fileName);
    var index = 1;
    while (await File(candidate).exists()) {
      candidate = p.join(
        dir,
        relativeDir == '.' ? '' : relativeDir,
        '$base ($index)$ext',
      );
      index++;
    }
    return candidate;
  }

  void _json(HttpResponse response, Map<String, Object?> body) {
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    unawaited(response.close());
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    screenOfferHandler = null;
    screenMetadataHandler = null;
    transferCommandHandler = null;
    await server?.close(force: true);
  }
}
