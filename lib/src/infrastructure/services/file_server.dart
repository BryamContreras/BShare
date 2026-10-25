import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bshare/src/domain/entities/incoming_transfer.dart';
import 'package:bshare/src/domain/entities/transfer_control.dart';
import 'package:bshare/src/domain/entities/transfer_progress_status.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/transfer_speed_meter.dart';
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
  Future<void>? _serveTask;
  bool _stopping = false;
  Future<void> _lifecycle = Future<void>.value();
  final Set<Future<void>> _requests = {};
  final Map<String, TransferControl> _activeTransfers = {};
  final Set<String> _reservedPaths = {};
  String _downloadDirectory = '';
  bool _autoAccept = true;

  /// A camera/screen signaling listener does not implicitly accept files.
  bool fileReceptionEnabled = true;

  /// Checks current access without opening a permission dialog for a remote
  /// request. It is rechecked after a local acceptance decision before writing.
  Future<bool> Function(String path)? fileAccessHandler;

  /// Applies to subsequent requests; requests already in progress retain their
  /// original destination and acceptance decision.
  void updateReceiverSettings({
    required String downloadDirectory,
    required bool autoAccept,
  }) {
    _downloadDirectory = downloadDirectory;
    _autoAccept = autoAccept;
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final operation = _lifecycle.then((_) => action());
    _lifecycle = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return operation;
  }

  ScreenOfferHandler? screenOfferHandler;
  ScreenMetadataHandler? screenMetadataHandler;
  Future<void> Function(String viewerId)? screenViewerStopHandler;
  ScreenOfferHandler? cameraOfferHandler;
  ScreenMetadataHandler? cameraMetadataHandler;
  Future<void> Function(String viewerId)? cameraViewerStopHandler;
  List<String>? cameraAllowedRemoteSubnets;
  TransferCommandHandler? transferCommandHandler;
  void Function()? onIdle;

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
  }) => _serialize(() async {
    if (_server != null) return _server!.port;
    final server = await _bindAvailableServer(preferredPort);
    _server = server;
    updateReceiverSettings(
      downloadDirectory: downloadDirectory,
      autoAccept: autoAccept,
    );
    _logger.info('HTTP receiver listening on ${server.port}');
    _serveTask = _serve(
      server,
      onIncoming,
      onSaved,
      onProgress,
      onQueue,
      resolveControl,
    );
    return server.port;
  });

  Future<HttpServer> _bindAvailableServer(int preferredPort) async {
    final ports = _candidatePorts(preferredPort);
    SocketException? lastSocketError;
    Object? lastError;

    for (final port in ports) {
      try {
        return await HttpServer.bind(
          InternetAddress.anyIPv4,
          port,
          // Different app instances must not accept each other's signaling.
          // If occupied, bind the next port and advertise that actual port.
          shared: false,
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
    HttpServer server,
    IncomingTransferHandler onIncoming,
    TransferSavedHandler onSaved,
    ReceiveProgressHandler onProgress,
    ReceiveQueueHandler onQueue,
    ReceiveControlResolver resolveControl,
  ) async {
    try {
      await for (final request in server) {
        late final Future<void> task;
        task =
            _handleRequest(
              request,
              _downloadDirectory,
              _autoAccept,
              onIncoming,
              onSaved,
              onProgress,
              onQueue,
              resolveControl,
            ).whenComplete(() {
              _requests.remove(task);
              if (_requests.isEmpty && !_stopping) onIdle?.call();
            });
        _requests.add(task);
      }
    } catch (error) {
      _logger.warn('Receiver stopped accepting requests: $error');
    }
  }

  Future<void> _handleRequest(
    HttpRequest request,
    String downloadDirectory,
    bool autoAccept,
    IncomingTransferHandler onIncoming,
    TransferSavedHandler onSaved,
    ReceiveProgressHandler onProgress,
    ReceiveQueueHandler onQueue,
    ReceiveControlResolver resolveControl,
  ) async {
    try {
      if (_stopping) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await _json(request.response, {
          'ok': false,
          'error': 'receiver-stopping',
        });
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/api/ping') {
        await _json(request.response, {'ok': true});
      } else if (request.method == 'POST' &&
          request.uri.path == '/api/screen/stop-viewer') {
        await _handleViewerStop(request, screenViewerStopHandler);
      } else if (request.method == 'POST' &&
          request.uri.path == '/api/camera/stop-viewer') {
        if (await _allowCameraInterface(request)) {
          await _handleViewerStop(request, cameraViewerStopHandler);
        }
      } else if (request.method == 'POST' &&
          request.uri.path == '/api/screen/offer') {
        await _handleVideoOffer(request, screenOfferHandler, 'screen');
      } else if (request.method == 'GET' &&
          request.uri.path == '/api/screen/metadata') {
        await _handleVideoMetadata(request, screenMetadataHandler, 'screen');
      } else if (request.method == 'POST' &&
          request.uri.path == '/api/camera/offer') {
        if (await _allowCameraInterface(request)) {
          await _handleVideoOffer(request, cameraOfferHandler, 'camera');
        }
      } else if (request.method == 'GET' &&
          request.uri.path == '/api/camera/metadata') {
        if (await _allowCameraInterface(request)) {
          await _handleVideoMetadata(request, cameraMetadataHandler, 'camera');
        }
      } else if (request.method == 'POST' &&
          request.uri.path == '/api/transfers/queue') {
        if (await _allowFileTransfer(request, downloadDirectory)) {
          await _handleTransferQueue(request, onQueue);
        }
      } else if (request.method == 'POST' &&
          request.uri.path == '/api/transfers/control') {
        await _handleTransferControl(request);
      } else if (request.method == 'POST' &&
          request.uri.path == '/api/transfers') {
        await _handleTransfer(
          request,
          downloadDirectory,
          autoAccept,
          onIncoming,
          onSaved,
          onProgress,
          resolveControl,
        );
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
    } catch (error) {
      _logger.warn('Request failed: $error');
      try {
        request.response.statusCode = HttpStatus.badRequest;
        await _json(request.response, {'ok': false, 'error': error.toString()});
      } catch (_) {}
    } finally {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<bool> _allowFileTransfer(
    HttpRequest request,
    String downloadDirectory,
  ) async {
    var allowed = fileReceptionEnabled;
    if (allowed && fileAccessHandler != null) {
      try {
        allowed = await fileAccessHandler!(downloadDirectory);
      } catch (error) {
        _logger.warn('Could not check receiver storage access: $error');
        allowed = false;
      }
    }
    // A local Stop or permission rejection may arrive while the check awaits.
    if (allowed && fileReceptionEnabled && !_stopping) return true;
    request.response.statusCode = HttpStatus.forbidden;
    await _json(request.response, {
      'ok': false,
      'error': fileReceptionEnabled
          ? 'storage-permission-required'
          : 'file-reception-disabled',
    });
    return false;
  }

  Future<bool> _allowCameraInterface(HttpRequest request) async {
    final allowed = cameraAllowedRemoteSubnets;
    final remote = request.connectionInfo?.remoteAddress;
    if (allowed == null ||
        (remote != null &&
            allowed.any((subnet) => _matchesSubnet(remote, subnet)))) {
      return true;
    }
    request.response.statusCode = HttpStatus.forbidden;
    await _json(request.response, {
      'ok': false,
      'error': 'camera-usb-interface-required',
    });
    return false;
  }

  bool _matchesSubnet(InternetAddress remote, String subnet) {
    final parts = subnet.split('/');
    final network = InternetAddress.tryParse(parts.first);
    if (network == null || remote.type != network.type) return false;
    final prefix = parts.length == 2 ? int.tryParse(parts[1]) : null;
    final bytes = remote.rawAddress;
    if (prefix == null || prefix < 0 || prefix > bytes.length * 8) return false;
    final networkBytes = network.rawAddress;
    for (var index = 0; index < bytes.length; index++) {
      final bits = (prefix - index * 8).clamp(0, 8);
      if (bits == 0) return true;
      final mask = (0xff << (8 - bits)) & 0xff;
      if ((bytes[index] & mask) != (networkBytes[index] & mask)) return false;
    }
    return true;
  }

  Future<void> _handleViewerStop(
    HttpRequest request,
    Future<void> Function(String)? handler,
  ) async {
    final body = jsonDecode(await utf8.decoder.bind(request).join());
    final id = body is Map ? body['viewerId'] : null;
    if (id is! String || !RegExp(r'^[a-zA-Z0-9-]{16,64}$').hasMatch(id)) {
      request.response.statusCode = HttpStatus.badRequest;
      await _json(request.response, {
        'ok': false,
        'error': 'invalid-viewer-id',
      });
      return;
    }
    await handler?.call(id);
    await _json(request.response, {'ok': true});
  }

  Future<void> _handleVideoOffer(
    HttpRequest request,
    ScreenOfferHandler? handler,
    String source,
  ) async {
    if (handler == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await _json(request.response, {
        'ok': false,
        'error': '$source-share-not-active',
      });
      return;
    }
    try {
      final body = await utf8.decoder.bind(request).join();
      final answer = await handler(jsonDecode(body) as Map<String, dynamic>);
      await _json(request.response, {'ok': true, 'answer': answer});
    } catch (error) {
      _logger.error('$source signaling failed', error);
      request.response.statusCode = HttpStatus.internalServerError;
      await _json(request.response, {'ok': false, 'error': error.toString()});
    }
  }

  Future<void> _handleVideoMetadata(
    HttpRequest request,
    ScreenMetadataHandler? handler,
    String source,
  ) async {
    if (handler == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await _json(request.response, {
        'ok': false,
        'error': '$source-share-not-active',
      });
      return;
    }
    try {
      await _json(request.response, {'ok': true, 'metadata': handler()});
    } catch (error) {
      _logger.error('$source metadata failed', error);
      request.response.statusCode = HttpStatus.internalServerError;
      await _json(request.response, {'ok': false, 'error': error.toString()});
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
      await _json(request.response, {'ok': true});
    } catch (error) {
      _logger.error('Receive queue update failed', error);
      request.response.statusCode = HttpStatus.badRequest;
      await _json(request.response, {'ok': false, 'error': error.toString()});
    }
  }

  Future<void> _handleTransferControl(HttpRequest request) async {
    final handler = transferCommandHandler;
    if (handler == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await _json(request.response, {
        'ok': false,
        'error': 'control-not-active',
      });
      return;
    }
    try {
      final body = await utf8.decoder.bind(request).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final id = json['id']?.toString();
      final action = json['action']?.toString();
      if (id == null || action == null) {
        request.response.statusCode = HttpStatus.badRequest;
        await _json(request.response, {
          'ok': false,
          'error': 'invalid-control',
        });
        return;
      }
      await handler(id, action);
      await _json(request.response, {'ok': true});
    } catch (error) {
      _logger.error('Transfer control failed', error);
      request.response.statusCode = HttpStatus.internalServerError;
      await _json(request.response, {'ok': false, 'error': error.toString()});
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
    if (!fileReceptionEnabled) {
      await _allowFileTransfer(request, downloadDirectory);
      return;
    }
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
    if (!await _allowFileTransfer(request, downloadDirectory)) {
      // This ID can already be queued on the receiver. A rejected upload must
      // finish that item even when the permission check precedes acceptance.
      if (!_activeTransfers.containsKey(id)) {
        onProgress(
          transfer: transfer,
          receivedBytes: 0,
          totalBytes: transfer.size,
          bytesPerSecond: 0,
          status: TransferProgressStatus.failed,
          message: 'Storage access is no longer available',
        );
      }
      return;
    }
    if (_activeTransfers.containsKey(id)) {
      request.response.statusCode = HttpStatus.conflict;
      await _json(request.response, {
        'ok': false,
        'error': 'transfer-already-active',
      });
      return;
    }
    final control = resolveControl(transfer.id);
    _activeTransfers[id] = control;
    try {
      if (control.isCancelled) {
        request.response.statusCode = 499;
        await _json(request.response, {'ok': false, 'status': 'cancelled'});
        onProgress(
          transfer: transfer,
          receivedBytes: 0,
          totalBytes: transfer.size,
          bytesPerSecond: 0,
          status: TransferProgressStatus.cancelled,
        );
        return;
      }

      final cancelled = Completer<bool>();
      final detachCancellation = control.onCancel(() {
        if (!cancelled.isCompleted) cancelled.complete(false);
        if (!transfer.decision.isCompleted) transfer.decision.complete(false);
      });
      bool accepted;
      try {
        accepted =
            autoAccept ||
            await Future.any([
              onIncoming(transfer).timeout(
                const Duration(minutes: 5),
                onTimeout: () {
                  if (!transfer.decision.isCompleted) {
                    transfer.decision.complete(false);
                  }
                  return false;
                },
              ),
              cancelled.future,
            ]);
      } finally {
        detachCancellation();
      }
      if (!accepted || control.isCancelled) {
        request.response.statusCode = control.isCancelled
            ? 499
            : HttpStatus.forbidden;
        await _json(request.response, {
          'ok': false,
          'status': control.isCancelled ? 'cancelled' : 'rejected',
        });
        onProgress(
          transfer: transfer,
          receivedBytes: 0,
          totalBytes: transfer.size,
          bytesPerSecond: 0,
          status: control.isCancelled
              ? TransferProgressStatus.cancelled
              : TransferProgressStatus.failed,
          message: control.isCancelled ? null : 'Transfer rejected',
        );
        return;
      }

      if (!await _allowFileTransfer(request, downloadDirectory)) {
        onProgress(
          transfer: transfer,
          receivedBytes: 0,
          totalBytes: transfer.size,
          bytesPerSecond: 0,
          status: TransferProgressStatus.failed,
          message: 'Storage access is no longer available',
        );
        return;
      }

      String? targetPath;
      IOSink? sink;
      var received = 0;
      final speedMeter = TransferSpeedMeter()..record(0);

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
        final progressClock = Stopwatch()..start();
        var lastProgressAt = 0;
        Stream<List<int>> receiveChunks() async* {
          final chunks = StreamIterator(request);
          final cancelled = Completer<bool>();
          final detachCancellation = control.onCancel(() {
            if (!cancelled.isCompleted) cancelled.complete(false);
          });
          try {
            while (await Future.any([chunks.moveNext(), cancelled.future])) {
              await control.waitIfPaused();
              final chunk = chunks.current;
              received += chunk.length;
              if (transfer.size >= 0 && received > transfer.size) {
                throw const FormatException('Transfer exceeds advertised size');
              }
              yield chunk;
              final elapsed = progressClock.elapsedMilliseconds;
              if (elapsed - lastProgressAt >= 100) {
                lastProgressAt = elapsed;
                onProgress(
                  transfer: transfer,
                  receivedBytes: received,
                  totalBytes: transfer.size,
                  bytesPerSecond: speedMeter.record(received),
                  status: TransferProgressStatus.receiving,
                );
              }
            }
            await control.waitIfPaused();
          } finally {
            detachCancellation();
            await chunks.cancel();
          }
        }

        await sink!.addStream(receiveChunks());
        await sink!.flush();
        await sink!.close();
        sink = null;

        if (transfer.size >= 0 && received != transfer.size) {
          await cleanupPartialFile();
          _logger.warn(
            'Transfer incomplete: received $received of ${transfer.size} bytes',
          );
          request.response.statusCode = HttpStatus.badRequest;
          await _json(request.response, {
            'ok': false,
            'error': 'incomplete transfer',
          });
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
        onProgress(
          transfer: transfer,
          receivedBytes: received,
          totalBytes: transfer.size,
          bytesPerSecond: speedMeter.record(received),
          status: TransferProgressStatus.completed,
          savedPath: targetPath,
        );
        await _json(request.response, {'ok': true, 'path': targetPath});
      } on TransferCancelledException {
        await cleanupPartialFile();
        request.response.statusCode = 499;
        await _json(request.response, {'ok': false, 'status': 'cancelled'});
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
        await _json(request.response, {'ok': false, 'error': error.toString()});
      } finally {
        if (targetPath != null) _reservedPaths.remove(targetPath);
      }
    } finally {
      _activeTransfers.remove(id);
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
    final relativeDir = p.dirname(fileName);
    final ext = p.extension(fileName);
    final base = p.basenameWithoutExtension(fileName);
    var candidate = p.join(dir, fileName);
    var index = 1;
    while (true) {
      if (!await File(candidate).exists() && _reservedPaths.add(candidate)) {
        return candidate;
      }
      candidate = p.join(
        dir,
        relativeDir == '.' ? '' : relativeDir,
        '$base ($index)$ext',
      );
      index++;
    }
  }

  Future<void> _json(HttpResponse response, Map<String, Object?> body) async {
    if (response.statusCode >= HttpStatus.badRequest) {
      response.persistentConnection = false;
    }
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  Future<void> stop() => _serialize(() async {
    _stopping = true;
    try {
      final server = _server;
      _server = null;
      screenOfferHandler = null;
      screenMetadataHandler = null;
      screenViewerStopHandler = null;
      cameraOfferHandler = null;
      cameraMetadataHandler = null;
      cameraViewerStopHandler = null;
      cameraAllowedRemoteSubnets = null;
      transferCommandHandler = null;
      onIdle = null;
      for (final control in _activeTransfers.values.toList()) {
        control.cancel();
      }
      await server?.close(force: true);
      final serving = _serveTask;
      _serveTask = null;
      await serving;
      await Future.wait(_requests.toList());
    } finally {
      _stopping = false;
    }
  });
}
