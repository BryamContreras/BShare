import 'dart:async';
import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/domain/entities/direct_share_invite.dart';
import 'package:bshare/src/domain/entities/receive_progress.dart';
import 'package:bshare/src/domain/entities/transfer_control.dart';
import 'package:bshare/src/domain/entities/transfer_progress_status.dart';
import 'package:bshare/src/domain/entities/transfer_record.dart';
import 'package:bshare/src/infrastructure/services/network_service.dart';
import 'package:bshare/src/infrastructure/services/platform_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

class ReceiveState {
  const ReceiveState({
    required this.visible,
    this.port,
    this.error,
    this.directInvite,
  });

  final bool visible;
  final int? port;
  final String? error;
  final DirectShareInvite? directInvite;

  ReceiveState copyWith({
    bool? visible,
    int? port,
    String? error,
    DirectShareInvite? directInvite,
  }) => ReceiveState(
    visible: visible ?? this.visible,
    port: port ?? this.port,
    error: error,
    directInvite: directInvite ?? this.directInvite,
  );
}

class ReceiveController extends AsyncNotifier<ReceiveState> {
  @override
  Future<ReceiveState> build() async => const ReceiveState(visible: false);

  Future<void> start() async {
    state = const AsyncLoading();
    DirectNetworkCredentials? directCredentials;
    try {
      final settings = await ref.read(settingsProvider.future);
      if (Platform.isAndroid) {
        await Permission.manageExternalStorage.request();
      }
      var receiverIp = (await ref.read(networkProvider.future)).ip;
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
      await ensureDirectory(settings.downloadDirectory);
      final server = ref.read(fileServerProvider);
      server.transferCommandHandler = _handleRemoteCommand;
      final port = await server.start(
        preferredPort: settings.preferredPort,
        downloadDirectory: settings.downloadDirectory,
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
              for (final transfer in transfers) {
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
      if (directCredentials == null) {
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
        ReceiveState(visible: true, port: port, directInvite: invite),
      );
    } catch (error) {
      await ref.read(discoveryProvider.notifier).stop();
      await ref.read(fileServerProvider).stop();
      if (directCredentials != null) {
        await ref.read(directNetworkServiceProvider).stopLocalOnlyHotspot();
      }
      state = AsyncData(
        ReceiveState(visible: false, error: 'Could not start receiver: $error'),
      );
    }
  }

  Future<void> stop() async {
    for (final control in ref.read(receiveTransferControlProvider).values) {
      control.cancel();
    }
    ref.read(incomingTransfersProvider.notifier).rejectAll();
    await ref.read(fileServerProvider).stop();
    await ref.read(discoveryProvider.notifier).stop();
    await ref.read(directNetworkServiceProvider).stopLocalOnlyHotspot();
    ref.read(receiveTransferControlProvider.notifier).clear();
    state = const AsyncData(ReceiveState(visible: false));
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
    final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 3)));
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
    }
  }
}
