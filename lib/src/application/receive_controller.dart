import 'dart:async';
import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/domain/entities/direct_share_invite.dart';
import 'package:bshare/src/domain/entities/receive_progress.dart';
import 'package:bshare/src/domain/entities/transfer_control.dart';
import 'package:bshare/src/domain/entities/transfer_progress_status.dart';
import 'package:bshare/src/domain/entities/transfer_record.dart';
import 'package:bshare/src/infrastructure/services/android_background_execution_service.dart';
import 'package:bshare/src/infrastructure/services/android_storage_access_service.dart';
import 'package:bshare/src/infrastructure/services/network_service.dart';
import 'package:bshare/src/infrastructure/services/platform_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

class ReceiveState {
  const ReceiveState({
    required this.visible,
    this.port,
    this.error,
    this.directInvite,
    this.acceptingFiles = false,
  });

  final bool visible;
  final bool acceptingFiles;
  final int? port;
  final String? error;
  final DirectShareInvite? directInvite;

  ReceiveState copyWith({
    bool? visible,
    bool? acceptingFiles,
    int? port,
    String? error,
    DirectShareInvite? directInvite,
  }) => ReceiveState(
    visible: visible ?? this.visible,
    acceptingFiles: acceptingFiles ?? this.acceptingFiles,
    port: port ?? this.port,
    error: error,
    directInvite: directInvite ?? this.directInvite,
  );
}

class ReceiveController extends AsyncNotifier<ReceiveState> {
  Future<void> _operation = Future<void>.value();
  final Set<Dio> _controlRequests = {};
  bool _keepReceiverForFiles = false;
  bool _screenShareRequested = false;
  int _fileAccessGeneration = 0;

  Future<T> _serialize<T>(Future<T> Function() action) {
    final operation = _operation.then((_) => action());
    _operation = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return operation;
  }

  @override
  Future<ReceiveState> build() async => const ReceiveState(visible: false);

  Future<void> start() => _serialize(() => _start(forFiles: true));

  Future<void> startForScreenShare() => startForVideoShare();

  Future<void> startForVideoShare({
    String? ipOverride,
    bool advertise = true,
  }) => _serialize(() async {
    final previouslyRequested = _screenShareRequested;
    _screenShareRequested = true;
    await _start(ipOverride: ipOverride, advertise: advertise);
    if (state.asData?.value.visible != true) {
      _screenShareRequested = previouslyRequested;
    }
  });

  Future<bool> stopIfScreenShareOnly() => _serialize(() async {
    _screenShareRequested = false;
    if (_keepReceiverForFiles || state.asData?.value.visible != true) {
      return false;
    }
    return _stop(force: false);
  });

  Future<void> _start({
    bool forFiles = false,
    String? ipOverride,
    bool advertise = true,
  }) async {
    final previous = state.asData?.value ?? const ReceiveState(visible: false);
    final wasVisible = previous.visible;
    if (wasVisible && !forFiles) return;
    final previouslyKeptForFiles = _keepReceiverForFiles;
    if (!wasVisible) state = const AsyncLoading();
    DirectNetworkCredentials? directCredentials;
    var initializingReceiver = false;
    var acquiredFileExecution = false;
    try {
      final settings = await ref.read(settingsProvider.future);
      if (forFiles) {
        await ref
            .read(androidStorageAccessProvider)
            .ensureAccess(settings.downloadDirectory);
        await ensureDirectory(settings.downloadDirectory);
      }
      final server = ref.read(fileServerProvider);
      if (wasVisible) {
        // A video-only listener is promoted in place, after permission succeeds.
        if (!previouslyKeptForFiles) {
          await ref
              .read(androidBackgroundExecutionProvider)
              .acquire(BackgroundExecutionOwner.fileReceiving);
          acquiredFileExecution = true;
        }
        server.updateReceiverSettings(
          downloadDirectory: settings.downloadDirectory,
          autoAccept: settings.autoAccept,
        );
        ++_fileAccessGeneration;
        _keepReceiverForFiles = true;
        server.fileAccessHandler = _canReceiveFiles;
        server.fileReceptionEnabled = true;
        state = AsyncData(previous.copyWith(acceptingFiles: true));
        return;
      }
      initializingReceiver = true;
      var receiverIp =
          ipOverride ?? (await ref.read(networkProvider.future)).ip;
      if (receiverIp == null &&
          (Platform.isAndroid || Platform.isWindows || Platform.isLinux)) {
        directCredentials = await ref
            .read(directNetworkServiceProvider)
            .startLocalOnlyHotspot();
        ref.invalidate(networkProvider);
        receiverIp = await _waitForLocalIp();
      }
      if (receiverIp == null) {
        throw StateError('No local network is available');
      }
      ++_fileAccessGeneration;
      _keepReceiverForFiles = forFiles;
      server.fileReceptionEnabled = forFiles;
      server.fileAccessHandler = _canReceiveFiles;
      server.onIdle = () {
        if (ref.mounted && !_keepReceiverForFiles && !_screenShareRequested) {
          unawaited(stopIfScreenShareOnly());
        }
      };
      server.transferCommandHandler = _handleRemoteCommand;
      final port = await server.start(
        preferredPort: settings.preferredPort,
        // Video signaling never needs or creates the user's download folder.
        downloadDirectory: forFiles
            ? settings.downloadDirectory
            : Directory.systemTemp.path,
        autoAccept: settings.autoAccept,
        onIncoming: (transfer) => ref
            .read(incomingTransfersProvider.notifier)
            .requestDecision(transfer),
        onSaved: ({required transfer, required savedPath}) async {
          await ref
              .read(historyProvider.notifier)
              .add(
                transferRecord(
                  direction: TransferDirection.received,
                  fileName: transfer.fileName,
                  size: transfer.size,
                  remoteDevice: transfer.senderName,
                  status: TransferStatus.completed,
                ),
              );
        },
        onProgress:
            ({
              required transfer,
              required receivedBytes,
              required totalBytes,
              required bytesPerSecond,
              required status,
              message,
              savedPath,
            }) {
              ref
                  .read(receiveProgressProvider.notifier)
                  .upsert(
                    ReceiveProgress(
                      id: transfer.id,
                      fileName: transfer.fileName,
                      receivedBytes: receivedBytes,
                      totalBytes: totalBytes,
                      bytesPerSecond: bytesPerSecond,
                      status: status,
                      message: message,
                      savedPath: savedPath,
                      controlHost: transfer.controlHost,
                      controlPort: transfer.controlPort,
                    ),
                  );
              if (status.isTerminal) {
                ref
                    .read(receiveTransferControlProvider.notifier)
                    .remove(transfer.id);
              }
            },
        onQueue:
            ({
              required senderId,
              required senderName,
              required transfers,
              controlHost,
              controlPort,
            }) {
              final controls = {...ref.read(receiveTransferControlProvider)};
              final existingIds = ref
                  .read(receiveProgressProvider)
                  .map((item) => item.id)
                  .toSet();
              for (final transfer in transfers) {
                if (!existingIds.add(transfer.id)) continue;
                controls.putIfAbsent(transfer.id, TransferControl.new);
                ref
                    .read(receiveProgressProvider.notifier)
                    .upsert(
                      ReceiveProgress(
                        id: transfer.id,
                        fileName: transfer.fileName,
                        receivedBytes: 0,
                        totalBytes: transfer.size,
                        bytesPerSecond: 0,
                        status: TransferProgressStatus.queued,
                        controlHost: transfer.controlHost ?? controlHost,
                        controlPort: transfer.controlPort ?? controlPort,
                      ),
                    );
              }
              ref.read(receiveTransferControlProvider.notifier).set(controls);
            },
        resolveControl: (id) {
          final controls = {...ref.read(receiveTransferControlProvider)};
          final control = controls.putIfAbsent(id, TransferControl.new);
          ref.read(receiveTransferControlProvider.notifier).set(controls);
          return control;
        },
      );
      if (forFiles) {
        await ref
            .read(androidBackgroundExecutionProvider)
            .acquire(BackgroundExecutionOwner.fileReceiving);
        acquiredFileExecution = true;
      }
      if (directCredentials == null && advertise) {
        await ref
            .read(discoveryProvider.notifier)
            .start(advertise: true, ipOverride: receiverIp);
      } else {
        await ref.read(discoveryProvider.notifier).stop();
      }
      final self = DeviceInfo(
        id: settings.deviceId,
        name: settings.deviceName,
        platform: currentPlatformName(),
        ip: receiverIp,
        port: port,
        lastSeen: DateTime.now(),
      );
      final invite = directCredentials == null
          ? null
          : DirectShareInvite(credentials: directCredentials, device: self);
      state = AsyncData(
        ReceiveState(
          visible: true,
          acceptingFiles: forFiles,
          port: port,
          directInvite: invite,
        ),
      );
    } catch (error) {
      _keepReceiverForFiles = previouslyKeptForFiles;
      final permissionDenied = error is AndroidStorageAccessDenied;
      final errorKey = permissionDenied
          ? 'storagePermissionRequired'
          : error is FileSystemException
          ? 'storageAccessFailed'
          : 'receiverStartFailed';
      if (wasVisible) {
        if (permissionDenied) {
          ref.read(fileServerProvider).fileReceptionEnabled = false;
          ++_fileAccessGeneration;
        }
        if (acquiredFileExecution) {
          await ref
              .read(androidBackgroundExecutionProvider)
              .release(BackgroundExecutionOwner.fileReceiving);
        }
        state = AsyncData(
          previous.copyWith(
            acceptingFiles: permissionDenied ? false : previous.acceptingFiles,
            error: errorKey,
          ),
        );
        return;
      }
      if (initializingReceiver) {
        final server = ref.read(fileServerProvider);
        server.fileReceptionEnabled = false;
        server.fileAccessHandler = null;
        await ref.read(discoveryProvider.notifier).stop();
        await server.stop();
        if (directCredentials != null) {
          await ref.read(directNetworkServiceProvider).stopLocalOnlyHotspot();
        }
        await ref
            .read(androidBackgroundExecutionProvider)
            .release(BackgroundExecutionOwner.fileReceiving);
      }
      state = AsyncData(ReceiveState(visible: false, error: errorKey));
    }
  }

  Future<bool> _canReceiveFiles(String path) async {
    if (!ref.mounted || !_keepReceiverForFiles) return false;
    final generation = _fileAccessGeneration;
    var allowed = false;
    try {
      allowed = await ref.read(androidStorageAccessProvider).hasAccess(path);
    } catch (error) {
      if (ref.mounted) {
        ref.read(loggerProvider).warn('Could not check storage access: $error');
      }
    }
    if (!ref.mounted || generation != _fileAccessGeneration) return false;
    if (!allowed) {
      // A request retains its destination even if Settings changes meanwhile.
      // Reject an old destination without disabling the valid current one.
      final currentDirectory = ref
          .read(settingsProvider)
          .value
          ?.downloadDirectory;
      if (currentDirectory == null ||
          p.normalize(p.absolute(path)) !=
              p.normalize(p.absolute(currentDirectory))) {
        return false;
      }
      ref.read(fileServerProvider).fileReceptionEnabled = false;
      _rejectQueuedFilesForStorageAccess();
      final current = state.asData?.value;
      if (current?.visible == true) {
        state = AsyncData(
          current!.copyWith(
            acceptingFiles: false,
            error: 'storagePermissionRequired',
          ),
        );
      }
    }
    return allowed;
  }

  void _rejectQueuedFilesForStorageAccess() {
    final progress = {
      for (final item in ref.read(receiveProgressProvider)) item.id: item,
    };
    final waitingIds = {
      for (final item in progress.values)
        if (item.status == TransferProgressStatus.queued) item.id,
    };
    final incoming = ref.read(incomingTransfersProvider).toList();
    for (final transfer in incoming) {
      final status = progress[transfer.id]?.status;
      if (!transfer.decision.isCompleted &&
          status != TransferProgressStatus.receiving &&
          status != TransferProgressStatus.sending) {
        waitingIds.add(transfer.id);
        ref.read(incomingTransfersProvider.notifier).decide(transfer.id, false);
      }
    }
    for (final id in waitingIds) {
      ref.read(receiveTransferControlProvider.notifier).cancel(id);
      ref.read(receiveTransferControlProvider.notifier).remove(id);
      final status = progress[id]?.status;
      if (status != null &&
          !status.isTerminal &&
          status != TransferProgressStatus.receiving &&
          status != TransferProgressStatus.sending) {
        ref
            .read(receiveProgressProvider.notifier)
            .updateStatus(id, TransferProgressStatus.cancelled);
      }
    }
  }

  Future<bool> stop({bool force = false}) =>
      _serialize(() => _stop(force: force));

  Future<bool> _stop({required bool force}) async {
    if (!force && _hasPendingOrActiveTransfers()) return false;

    for (final control in ref.read(receiveTransferControlProvider).values) {
      control.cancel();
    }
    for (final progress in ref.read(receiveProgressProvider)) {
      if (!progress.status.isTerminal) {
        ref
            .read(receiveProgressProvider.notifier)
            .updateStatus(progress.id, TransferProgressStatus.cancelled);
      }
    }
    for (final request in _controlRequests.toList()) {
      request.close(force: true);
    }
    ref.read(incomingTransfersProvider.notifier).rejectAll();
    final server = ref.read(fileServerProvider);
    ++_fileAccessGeneration;
    server.fileReceptionEnabled = false;
    server.fileAccessHandler = null;
    server.onIdle = null;
    await server.stop();
    await ref.read(discoveryProvider.notifier).stop();
    await ref.read(directNetworkServiceProvider).stopLocalOnlyHotspot();
    await ref
        .read(androidBackgroundExecutionProvider)
        .release(BackgroundExecutionOwner.fileReceiving);
    ref.read(receiveTransferControlProvider.notifier).clear();
    _keepReceiverForFiles = false;
    _screenShareRequested = false;
    state = const AsyncData(ReceiveState(visible: false));
    return true;
  }

  bool _hasPendingOrActiveTransfers() {
    return ref.read(incomingTransfersProvider).isNotEmpty ||
        ref
            .read(receiveProgressProvider)
            .any((item) => !item.status.isTerminal);
  }

  Future<String?> _waitForLocalIp() async {
    final needsLongerWait = Platform.isWindows || Platform.isLinux;
    final attempts = needsLongerWait ? 40 : 16;
    final delay = needsLongerWait
        ? const Duration(milliseconds: 500)
        : const Duration(milliseconds: 350);
    for (var attempt = 0; attempt < attempts; attempt++) {
      final snapshot = await NetworkService().snapshot(
        includeLocalInterfaces: true,
      );
      if (snapshot.ip != null) return snapshot.ip;
      await Future<void>.delayed(delay);
    }
    return null;
  }

  String platformName() => currentPlatformName();

  void pause(String id) {
    ref.read(receiveTransferControlProvider.notifier).pause(id);
    ref
        .read(receiveProgressProvider.notifier)
        .updateStatus(id, TransferProgressStatus.paused);
    unawaited(_sendRemoteControl(id, 'pause'));
  }

  void resume(String id) {
    ref.read(receiveTransferControlProvider.notifier).resume(id);
    ref
        .read(receiveProgressProvider.notifier)
        .updateStatus(id, TransferProgressStatus.receiving);
    unawaited(_sendRemoteControl(id, 'resume'));
  }

  void cancel(String id) {
    ref.read(receiveTransferControlProvider.notifier).cancel(id);
    ref
        .read(receiveProgressProvider.notifier)
        .updateStatus(id, TransferProgressStatus.cancelled);
    ref.read(receiveTransferControlProvider.notifier).remove(id);
    unawaited(_sendRemoteControl(id, 'cancel'));
  }

  Future<void> _handleRemoteCommand(String id, String action) async {
    switch (action) {
      case 'pause':
        ref.read(receiveTransferControlProvider.notifier).pause(id);
        ref
            .read(receiveProgressProvider.notifier)
            .updateStatus(id, TransferProgressStatus.paused);
        break;
      case 'resume':
        ref.read(receiveTransferControlProvider.notifier).resume(id);
        ref
            .read(receiveProgressProvider.notifier)
            .updateStatus(id, TransferProgressStatus.receiving);
        break;
      case 'cancel':
        ref.read(receiveTransferControlProvider.notifier).cancel(id);
        ref
            .read(receiveProgressProvider.notifier)
            .updateStatus(id, TransferProgressStatus.cancelled);
        ref.read(receiveTransferControlProvider.notifier).remove(id);
        break;
    }
  }

  Future<void> _sendRemoteControl(String id, String action) async {
    ReceiveProgress? progress;
    for (final item in ref.read(receiveProgressProvider)) {
      if (item.id == id) {
        progress = item;
        break;
      }
    }
    final host = progress?.controlHost;
    final port = progress?.controlPort;
    if (host == null || port == null) return;
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 3),
        sendTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 3),
      ),
    );
    _controlRequests.add(dio);
    try {
      await dio.postUri(
        Uri(
          scheme: 'http',
          host: host,
          port: port,
          path: '/api/transfers/control',
        ),
        data: {'id': id, 'action': action},
      );
    } catch (_) {
    } finally {
      dio.close(force: true);
      _controlRequests.remove(dio);
    }
  }
}
