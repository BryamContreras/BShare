import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/android_app_file.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/domain/entities/app_settings.dart';
import 'package:bshare/src/domain/entities/send_progress.dart';
import 'package:bshare/src/domain/entities/selected_transfer_file.dart';
import 'package:bshare/src/domain/entities/transfer_control.dart';
import 'package:bshare/src/domain/entities/transfer_progress_status.dart';
import 'package:bshare/src/domain/entities/transfer_record.dart';
import 'package:bshare/src/infrastructure/services/android_background_execution_service.dart';
import 'package:bshare/src/infrastructure/services/network_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

class SendController {
  SendController(this._ref);

  static const _maximumConcurrentTransfers = 3;

  final Ref _ref;
  final List<_QueuedSend> _queue = [];
  final Map<String, _QueuedSend> _remoteControls = {};
  final Map<String, SelectedTransferFile> _pendingTemporaryCleanup = {};
  HttpServer? _controlServer;
  var _active = 0;
  var _pumping = false;
  var _starting = false;
  var _sequence = 0;
  var _backgroundExecutionClaimed = false;

  Future<void> pickFiles({
    FileType type = FileType.any,
    List<String>? extensions,
    bool append = true,
  }) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
      type: type,
      allowedExtensions: extensions,
    );
    if (result != null) {
      final files = result.files
          .where((file) => file.path != null)
          .map(
            (file) => SelectedTransferFile(
              path: file.path!,
              name: file.name,
              size: file.size,
            ),
          )
          .toList();
      if (append) {
        _ref.read(pickedFilesProvider.notifier).append(files);
      } else {
        _ref.read(pickedFilesProvider.notifier).set(files);
      }
    }
  }

  Future<void> pickAppPackage() async {
    final extensions = Platform.isIOS ? ['ipa'] : ['apk', 'apks', 'xapk'];
    await pickFiles(type: FileType.custom, extensions: extensions);
  }

  void addAndroidApps(List<AndroidAppFile> apps) {
    final files = apps
        .map(
          (app) => SelectedTransferFile(
            path: app.sourcePath,
            name: '${app.name}.apk',
            size: app.size,
          ),
        )
        .toList();
    _ref.read(pickedFilesProvider.notifier).append(files);
  }

  void addSelectedFiles(List<SelectedTransferFile> files) {
    if (files.isEmpty) return;
    _ref.read(pickedFilesProvider.notifier).append(files);
  }

  Future<void> addFolderPath(String folder) async {
    final root = Directory(folder);
    if (!await root.exists()) return;
    _ref.read(pickedFilesProvider.notifier).append(await _filesInFolder(root));
  }

  Future<void> pickMedia() async {
    await pickFiles(type: FileType.media);
  }

  Future<void> pickFolder() async {
    final folder = await FilePicker.platform.getDirectoryPath();
    if (folder == null) return;
    final root = Directory(folder);
    _ref.read(pickedFilesProvider.notifier).append(await _filesInFolder(root));
  }

  Future<List<SelectedTransferFile>> _filesInFolder(Directory root) async {
    final selected = <SelectedTransferFile>[];
    final folderName = p.basename(root.path);
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final stat = await entity.stat();
      selected.add(
        SelectedTransferFile(
          path: entity.path,
          name: p.basename(entity.path),
          size: stat.size,
          relativePath: p.join(
            folderName,
            p.relative(entity.path, from: root.path),
          ),
        ),
      );
    }
    return selected;
  }

  void clearFiles() {
    final files = _ref.read(pickedFilesProvider);
    _ref.read(pickedFilesProvider.notifier).clear();
    unawaited(_cleanupTemporaryFiles(files));
  }

  void removeFile(String path) {
    final files = _ref
        .read(pickedFilesProvider)
        .where((file) => file.path == path)
        .toList();
    _ref.read(pickedFilesProvider.notifier).remove(path);
    unawaited(_cleanupTemporaryFiles(files));
  }

  Future<void> dispose({
    bool updateState = true,
    bool cleanupSelectedFiles = false,
    List<SelectedTransferFile> selectedFiles = const [],
  }) async {
    final selectedPaths = selectedFiles.map((file) => file.path).toSet();
    final transferFiles = _remoteControls.values
        .map((item) => item.file)
        .toList();
    final pendingFiles = _pendingTemporaryCleanup.values.toList();
    for (final item in _remoteControls.values) {
      item.control.cancel();
    }
    _queue.clear();
    _remoteControls.clear();
    _pendingTemporaryCleanup.clear();
    await _cleanupTemporaryFiles([
      ...pendingFiles,
      ...transferFiles.where(
        (file) => cleanupSelectedFiles || !selectedPaths.contains(file.path),
      ),
      if (cleanupSelectedFiles) ...selectedFiles,
    ]);
    await _releaseBackgroundExecution();
    if (updateState) {
      _ref.read(transferControlProvider.notifier).clear();
    }
    await _closeControlServer();
  }

  Future<void> send() async {
    final target = _ref.read(selectedDeviceProvider);
    final files = _ref.read(pickedFilesProvider);
    if (target == null || files.isEmpty || _starting) return;
    if (files.any((file) => _hasTransferForPath(file.path))) return;
    _starting = true;
    try {
      if (!await _prepareTargetRoute(target, files)) return;
      await _acquireBackgroundExecution();
      final settings = await _ref.read(settingsProvider.future);
      final client = _ref.read(fileTransferClientProvider);
      final controlPort = await _ensureControlServer();
      final network = await NetworkService().snapshot(
        includeLocalInterfaces: true,
      );
      final controls = {for (final file in files) file.path: TransferControl()};

      if (_active == 0 && _queue.isEmpty) {
        _ref.read(sendProgressProvider.notifier).clear();
      }
      _ref.read(transferControlProvider.notifier).set({
        ..._ref.read(transferControlProvider),
        ...controls,
      });

      final transferIds = {
        for (final file in files) file.path: _nextTransferId(settings, file),
      };
      await client.announceQueue(
        target: target,
        files: files,
        transferIds: transferIds,
        senderId: settings.deviceId,
        senderName: settings.deviceName,
        controlHost: network.ip,
        controlPort: controlPort,
      );

      for (final file in files) {
        final item = _QueuedSend(
          target: target,
          file: file,
          transferId: transferIds[file.path]!,
          senderId: settings.deviceId,
          senderName: settings.deviceName,
          control: controls[file.path]!,
          controlHost: network.ip,
          controlPort: controlPort,
        );
        _queue.add(item);
        _remoteControls[item.transferId] = item;
        _ref
            .read(sendProgressProvider.notifier)
            .upsert(
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

      _pump();
    } finally {
      _starting = false;
    }
  }

  Future<bool> _prepareTargetRoute(
    DeviceInfo target,
    List<SelectedTransferFile> files,
  ) async {
    final progress = _ref.read(sendProgressProvider.notifier);
    for (var attempt = 0; attempt < 4; attempt++) {
      await _ref
          .read(directNetworkServiceProvider)
          .bindToWifiForHost(host: target.ip, port: target.port);
      _ref.invalidate(networkProvider);
      if (await _canReachTarget(target)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 450));
    }

    if (_active == 0 && _queue.isEmpty) {
      progress.clear();
    }
    for (final file in files) {
      progress.upsert(
        SendProgress(
          id: file.path,
          fileName: file.name,
          sentBytes: 0,
          totalBytes: file.size,
          bytesPerSecond: 0,
          status: TransferProgressStatus.failed,
          message: 'Receiver unreachable',
        ),
      );
    }
    return false;
  }

  Future<bool> _canReachTarget(DeviceInfo target) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client
          .getUrl(target.baseUri.replace(path: '/api/ping'))
          .timeout(const Duration(seconds: 2));
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      await response.drain<void>();
      return response.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  void _pump() {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_active < _maximumConcurrentTransfers && _queue.isNotEmpty) {
        final item = _queue.removeAt(0);
        _active++;
        unawaited(_sendQueued(item));
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _sendQueued(_QueuedSend item) async {
    final client = _ref.read(fileTransferClientProvider);
    try {
      await for (final progress in client.sendFile(
        target: item.target,
        file: item.file,
        transferId: item.transferId,
        senderId: item.senderId,
        senderName: item.senderName,
        control: item.control,
        controlHost: item.controlHost,
        controlPort: item.controlPort,
      )) {
        _ref.read(sendProgressProvider.notifier).upsert(progress);
        if (progress.isDone) {
          await _addHistory(item.target, progress);
        }
      }
    } finally {
      _remoteControls.remove(item.transferId);
      _active--;
      final controls = {..._ref.read(transferControlProvider)}
        ..remove(item.file.path);
      _ref.read(transferControlProvider.notifier).set(controls);
      _flushPendingTemporaryCleanup(item.file.path);
      _pump();
      _maybeCloseControlServer();
    }
  }

  Future<void> _addHistory(DeviceInfo target, SendProgress progress) async {
    await _ref
        .read(historyProvider.notifier)
        .add(
          transferRecord(
            direction: TransferDirection.sent,
            fileName: progress.fileName,
            size: progress.totalBytes,
            remoteDevice: target.name,
            status: progress.status == TransferProgressStatus.completed
                ? TransferStatus.completed
                : TransferStatus.failed,
            error: progress.status == TransferProgressStatus.completed
                ? null
                : progress.message ?? progress.status.name,
          ),
        );
  }

  String _nextTransferId(AppSettings settings, SelectedTransferFile file) {
    _sequence++;
    return '${settings.deviceId}:${DateTime.now().microsecondsSinceEpoch}:$_sequence:${file.path.hashCode}:${file.size}';
  }

  void pause(String id) {
    final item = _itemForLocalId(id);
    _ref.read(transferControlProvider.notifier).pause(id);
    _ref
        .read(sendProgressProvider.notifier)
        .updateStatus(id, TransferProgressStatus.paused);
    if (item != null) {
      unawaited(_sendRemoteCommand(item.target, item.transferId, 'pause'));
    }
  }

  void resume(String id) {
    final item = _itemForLocalId(id);
    _ref.read(transferControlProvider.notifier).resume(id);
    _ref
        .read(sendProgressProvider.notifier)
        .updateStatus(id, TransferProgressStatus.sending);
    if (item != null) {
      unawaited(_sendRemoteCommand(item.target, item.transferId, 'resume'));
    }
  }

  void cancel(String id) {
    final item = _itemForLocalId(id);
    _ref.read(transferControlProvider.notifier).cancel(id);
    final queued = _queue.where((queued) => queued.file.path == id).toList();
    _queue.removeWhere((queued) => queued.file.path == id);
    for (final item in queued) {
      _remoteControls.remove(item.transferId);
      _flushPendingTemporaryCleanup(item.file.path);
    }
    _ref
        .read(sendProgressProvider.notifier)
        .updateStatus(id, TransferProgressStatus.cancelled);
    _ref.read(transferControlProvider.notifier).remove(id);
    if (item != null) {
      unawaited(_sendRemoteCommand(item.target, item.transferId, 'cancel'));
    }
    _maybeCloseControlServer();
  }

  _QueuedSend? _itemForLocalId(String id) {
    for (final item in _remoteControls.values) {
      if (item.file.path == id) return item;
    }
    return null;
  }

  Future<int?> _ensureControlServer() async {
    final current = _controlServer;
    if (current != null) return current.port;
    try {
      final server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        0,
        shared: true,
      );
      _controlServer = server;
      unawaited(_serveControl(server));
      return server.port;
    } catch (_) {
      return null;
    }
  }

  Future<void> _serveControl(HttpServer server) async {
    await for (final request in server) {
      if (request.method != 'POST' ||
          request.uri.path != '/api/transfers/control') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        continue;
      }

      try {
        final body = await utf8.decoder.bind(request).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        final id = json['id']?.toString();
        final action = json['action']?.toString();
        if (id == null || action == null) {
          request.response.statusCode = HttpStatus.badRequest;
          _writeJson(request.response, {'ok': false});
          continue;
        }
        _handleRemoteCommand(id, action);
        _writeJson(request.response, {'ok': true});
      } catch (_) {
        request.response.statusCode = HttpStatus.badRequest;
        _writeJson(request.response, {'ok': false});
      }
    }
  }

  void _handleRemoteCommand(String transferId, String action) {
    final item = _remoteControls[transferId];
    if (item == null) return;
    switch (action) {
      case 'pause':
        item.control.pause();
        _ref.read(transferControlProvider.notifier).pause(item.file.path);
        _ref
            .read(sendProgressProvider.notifier)
            .updateStatus(item.file.path, TransferProgressStatus.paused);
        break;
      case 'resume':
        item.control.resume();
        _ref.read(transferControlProvider.notifier).resume(item.file.path);
        _ref
            .read(sendProgressProvider.notifier)
            .updateStatus(item.file.path, TransferProgressStatus.sending);
        break;
      case 'cancel':
        item.control.cancel();
        final queued = _queue
            .where((queued) => queued.transferId == transferId)
            .toList();
        _queue.removeWhere((queued) => queued.transferId == transferId);
        _ref.read(transferControlProvider.notifier).cancel(item.file.path);
        _ref
            .read(sendProgressProvider.notifier)
            .updateStatus(item.file.path, TransferProgressStatus.cancelled);
        _ref.read(transferControlProvider.notifier).remove(item.file.path);
        if (queued.isNotEmpty) {
          _remoteControls.remove(transferId);
          for (final queuedItem in queued) {
            _flushPendingTemporaryCleanup(queuedItem.file.path);
          }
        }
        _maybeCloseControlServer();
        break;
    }
  }

  void _maybeCloseControlServer() {
    if (_active == 0 && _queue.isEmpty && _remoteControls.isEmpty) {
      unawaited(_closeControlServer());
      unawaited(_releaseBackgroundExecution());
    }
  }

  Future<void> _acquireBackgroundExecution() async {
    if (_backgroundExecutionClaimed) return;
    _backgroundExecutionClaimed = await _ref
        .read(androidBackgroundExecutionProvider)
        .acquire(BackgroundExecutionOwner.fileSending);
  }

  Future<void> _releaseBackgroundExecution() async {
    if (!_backgroundExecutionClaimed) return;
    _backgroundExecutionClaimed = false;
    await _ref
        .read(androidBackgroundExecutionProvider)
        .release(BackgroundExecutionOwner.fileSending);
  }

  Future<void> _closeControlServer() async {
    final server = _controlServer;
    _controlServer = null;
    await server?.close(force: true);
  }

  Future<void> _cleanupTemporaryFiles(List<SelectedTransferFile> files) async {
    final uniqueFiles = <String, SelectedTransferFile>{
      for (final file in files) file.path: file,
    };
    await Future.wait(uniqueFiles.values.map(_cleanupTemporaryFile));
  }

  Future<void> _cleanupTemporaryFile(SelectedTransferFile file) async {
    if (!file.deleteAfterSend) return;
    if (_hasTransferForPath(file.path)) {
      _pendingTemporaryCleanup[file.path] = file;
      return;
    }
    _pendingTemporaryCleanup.remove(file.path);
    await _deleteTemporaryFile(file);
  }

  void _flushPendingTemporaryCleanup(String path) {
    if (_hasTransferForPath(path)) return;
    final file = _pendingTemporaryCleanup.remove(path);
    if (file != null) unawaited(_deleteTemporaryFile(file));
  }

  bool _hasTransferForPath(String path) {
    return _queue.any((item) => item.file.path == path) ||
        _remoteControls.values.any((item) => item.file.path == path);
  }

  Future<void> _deleteTemporaryFile(SelectedTransferFile file) async {
    try {
      final temporary = File(file.path);
      if (await temporary.exists()) {
        await temporary.delete();
      }
    } catch (_) {
      // Best effort: stale shared-inbox files are also removed by Android cache cleanup.
    }
  }

  Future<void> _sendRemoteCommand(
    DeviceInfo target,
    String transferId,
    String action,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final request = await client.postUrl(
        target.baseUri.replace(path: '/api/transfers/control'),
      );
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'id': transferId, 'action': action}));
      final response = await request.close();
      await response.drain<void>();
    } catch (_) {
      // The data stream itself remains the source of truth if control sync fails.
    } finally {
      client.close(force: true);
    }
  }

  void _writeJson(HttpResponse response, Map<String, Object?> body) {
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    unawaited(response.close());
  }
}

class _QueuedSend {
  const _QueuedSend({
    required this.target,
    required this.file,
    required this.transferId,
    required this.senderId,
    required this.senderName,
    required this.control,
    this.controlHost,
    this.controlPort,
  });

  final DeviceInfo target;
  final SelectedTransferFile file;
  final String transferId;
  final String senderId;
  final String senderName;
  final TransferControl control;
  final String? controlHost;
  final int? controlPort;
}
