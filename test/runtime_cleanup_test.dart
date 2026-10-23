import 'dart:async';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/application/receive_controller.dart';
import 'package:bshare/src/application/send_controller.dart';
import 'package:bshare/src/domain/entities/incoming_transfer.dart';
import 'package:bshare/src/domain/entities/selected_transfer_file.dart';
import 'package:bshare/src/domain/entities/transfer_control.dart';
import 'package:bshare/src/infrastructure/services/android_screen_share_execution_service.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/direct_network_service.dart';
import 'package:bshare/src/infrastructure/services/file_server.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Logger extends AppLogger {
  final warnings = <String>[];
  @override
  void warn(String message) => warnings.add(message);
}

class _Send extends SendController {
  _Send(super.ref);
  int calls = 0;
  @override
  Future<void> dispose({
    bool updateState = true,
    bool cleanupSelectedFiles = false,
    List<SelectedTransferFile> selectedFiles = const [],
  }) async {
    calls++;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    throw StateError('send stop failed');
  }
}

class _Receive extends ReceiveController {
  int calls = 0;
  @override
  Future<bool> stop({bool force = false}) async {
    calls++;
    throw StateError('receive stop failed');
  }
}

class _Discovery extends DiscoveryController {
  int calls = 0;
  @override
  Future<void> stop() async {
    calls++;
    throw StateError('discovery stop failed');
  }
}

class _Direct extends DirectNetworkService {
  int hotspotStops = 0;
  int disconnects = 0;
  @override
  Future<void> stopLocalOnlyHotspot() async {
    hotspotStops++;
    throw StateError('hotspot stop failed');
  }

  @override
  Future<void> disconnectWifi() async {
    disconnects++;
  }
}

class _Server extends FileServer {
  _Server() : super(const AppLogger());
  int calls = 0;
  @override
  Future<void> stop() async {
    calls++;
  }
}

class _Screen extends ScreenShareService {
  _Screen() : super(const AppLogger(), AndroidScreenShareExecutionService());
  int calls = 0;
  @override
  Future<void> stop(FileServer server, {String status = 'Idle'}) async {
    calls++;
    throw StateError('screen stop failed');
  }
}

void main() {
  test(
    'cleanup coalesces concurrent calls and attempts every step after failures',
    () async {
      final logger = _Logger();
      final direct = _Direct();
      final server = _Server();
      final screen = _Screen();
      late _Send send;
      late _Receive receive;
      late _Discovery discovery;
      final container = ProviderContainer(
        overrides: [
          loggerProvider.overrideWithValue(logger),
          sendControllerProvider.overrideWith((ref) => send = _Send(ref)),
          receiveControllerProvider.overrideWith(() => receive = _Receive()),
          discoveryProvider.overrideWith(() => discovery = _Discovery()),
          directNetworkServiceProvider.overrideWithValue(direct),
          fileServerProvider.overrideWithValue(server),
          screenShareServiceProvider.overrideWithValue(screen),
        ],
      );
      addTearDown(container.dispose);
      await container.read(receiveControllerProvider.future);
      final outgoingControl = TransferControl()..pause();
      final incomingControl = TransferControl()..pause();
      container.read(transferControlProvider.notifier).set({
        'outgoing': outgoingControl,
      });
      container.read(receiveTransferControlProvider.notifier).set({
        'incoming': incomingControl,
      });
      final decision = container
          .read(incomingTransfersProvider.notifier)
          .requestDecision(
            IncomingTransfer(
              id: 'incoming',
              senderName: 'Sender',
              senderId: 'sender',
              fileName: 'file',
              size: 1,
              createdAt: DateTime.now(),
              decision: Completer<bool>(),
            ),
          );
      final cleanup = container.read(runtimeCleanupProvider);
      final first = cleanup.cleanupNetworking();
      final duplicate = cleanup.cleanupNetworking();
      expect(duplicate, same(first));
      await Future.wait([first, duplicate]);
      expect(send.calls, 1);
      expect(screen.calls, 1);
      expect(receive.calls, 1);
      expect(discovery.calls, 1);
      expect(server.calls, 1);
      expect(direct.hotspotStops, 1);
      expect(direct.disconnects, 1);
      expect(logger.warnings, hasLength(5));
      expect(outgoingControl.isCancelled, isTrue);
      expect(incomingControl.isCancelled, isTrue);
      expect(await decision, isFalse);
      expect(container.read(transferControlProvider), isEmpty);
      expect(container.read(receiveTransferControlProvider), isEmpty);
      await cleanup.cleanupNetworking();
      expect(direct.disconnects, 2);
    },
  );

  test(
    'disposing pending decisions resolves them without accessing disposed state',
    () async {
      final container = ProviderContainer();
      final pending = container
          .read(incomingTransfersProvider.notifier)
          .requestDecision(
            IncomingTransfer(
              id: 'pending',
              senderName: 'Sender',
              senderId: 'sender',
              fileName: 'file',
              size: 1,
              createdAt: DateTime.now(),
              decision: Completer<bool>(),
            ),
          );
      container.dispose();
      expect(await pending, isFalse);
    },
  );
}
