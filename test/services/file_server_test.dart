import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bshare/src/domain/entities/incoming_transfer.dart';
import 'package:bshare/src/domain/entities/transfer_control.dart';
import 'package:bshare/src/domain/entities/transfer_progress_status.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/file_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late FileServer server;
  late HttpClient client;
  late Map<String, TransferControl> controls;
  late List<({IncomingTransfer transfer, TransferProgressStatus status})>
  progress;

  Future<int> start({
    bool autoAccept = true,
    IncomingTransferHandler? onIncoming,
  }) {
    return server.start(
      preferredPort: 0,
      downloadDirectory: directory.path,
      autoAccept: autoAccept,
      onIncoming: onIncoming ?? (_) async => true,
      onSaved: ({required transfer, required savedPath}) async {},
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
            progress.add((transfer: transfer, status: status));
          },
      onQueue:
          ({
            required senderId,
            required senderName,
            required transfers,
            controlHost,
            controlPort,
          }) {},
      resolveControl: (id) => controls.putIfAbsent(id, TransferControl.new),
    );
  }

  Future<({int status, Map<String, dynamic> body})> send(
    int port,
    String id,
    List<int> bytes, {
    String name = 'shared.bin',
  }) async {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/api/transfers'),
    );
    request.contentLength = bytes.length;
    request.headers.set('x-bshare-transfer-id', id);
    request.headers.set('x-bshare-file-name', name);
    request.headers.set('x-bshare-file-size', bytes.length);
    request.add(bytes);
    final response = await request.close();
    final body =
        jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>;
    return (status: response.statusCode, body: body);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bshare-receiver-test-');
    server = FileServer(const AppLogger());
    client = HttpClient();
    controls = {};
    progress = [];
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    await directory.delete(recursive: true);
  });

  test(
    'video-only signaling refuses uploads and queue announcements',
    () async {
      server.fileReceptionEnabled = false;
      server.cameraMetadataHandler = () => {'source': 'camera'};
      var accessChecks = 0;
      server.fileAccessHandler = (_) async {
        accessChecks++;
        return true;
      };
      final port = await start();
      final upload = await send(port, 'unsolicited', [1, 2]);
      expect(upload.status, HttpStatus.forbidden);
      expect(upload.body['error'], 'file-reception-disabled');
      final queue = await client.postUrl(
        Uri.parse('http://127.0.0.1:$port/api/transfers/queue'),
      );
      queue.write('{}');
      final rejectedQueue = await queue.close();
      expect(rejectedQueue.statusCode, HttpStatus.forbidden);
      await rejectedQueue.drain<void>();
      final metadata = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/api/camera/metadata'),
      );
      final response = await metadata.close();
      expect(response.statusCode, HttpStatus.ok);
      await response.drain<void>();
      expect(accessChecks, 0);
      expect(controls, isEmpty);
      expect(progress, isEmpty);
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test(
    'denied or failed storage checks reject files before prompting',
    () async {
      var prompts = 0;
      final port = await start(
        onIncoming: (_) async {
          prompts++;
          return true;
        },
      );
      server.fileAccessHandler = (_) async => false;
      expect((await send(port, 'denied', [1])).status, HttpStatus.forbidden);
      server.fileAccessHandler = (_) async =>
          throw StateError('permission revoked');
      expect(
        (await send(port, 'unavailable', [1])).status,
        HttpStatus.forbidden,
      );
      expect(prompts, 0);
      expect(controls, isEmpty);
      expect(progress.map((item) => item.transfer.id), [
        'denied',
        'unavailable',
      ]);
      expect(progress.every((item) => item.status.isTerminal), isTrue);
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test(
    'access revoked while accepting is rechecked before any file write',
    () async {
      final incoming = Completer<IncomingTransfer>();
      var allowed = true;
      var checks = 0;
      server.fileAccessHandler = (path) async {
        expect(path, directory.path);
        checks++;
        return allowed;
      };
      final port = await start(
        autoAccept: false,
        onIncoming: (transfer) {
          if (!incoming.isCompleted) incoming.complete(transfer);
          return transfer.decision.future;
        },
      );
      final sending = send(port, 'revoked-at-decision', [4, 5]);
      final transfer = await incoming.future;
      allowed = false;
      transfer.decision.complete(true);
      final result = await sending;
      expect(result.status, HttpStatus.forbidden);
      expect(checks, 2);
      expect(progress.last.status, TransferProgressStatus.failed);
      expect(await directory.list().toList(), isEmpty);

      allowed = true;
      server.updateReceiverSettings(
        downloadDirectory: directory.path,
        autoAccept: true,
      );
      expect((await send(port, 'granted-again', [7])).status, HttpStatus.ok);
      expect(await File('${directory.path}/shared.bin').readAsBytes(), [7]);
    },
  );

  test(
    'disabling reception during an async access check blocks the upload',
    () async {
      final checking = Completer<void>();
      final finishCheck = Completer<bool>();
      server.fileAccessHandler = (_) {
        checking.complete();
        return finishCheck.future;
      };
      final port = await start();
      final sending = send(port, 'disabled-during-check', [8]);
      await checking.future;
      server.fileReceptionEnabled = false;
      finishCheck.complete(true);
      expect((await sending).status, HttpStatus.forbidden);
      expect(controls, isEmpty);
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test(
    'concurrent starts share one listener and stop closes its port',
    () async {
      final ports = await Future.wait(List.generate(12, (_) => start()));
      expect(ports.toSet(), hasLength(1));
      await server.stop();
      expect(server.isRunning, isFalse);
      expect(
        () => Socket.connect('127.0.0.1', ports.first),
        throwsA(isA<SocketException>()),
      );
    },
  );

  test(
    'concurrent uploads with the same filename preserve every payload',
    () async {
      final port = await start();
      final results = await Future.wait(
        List.generate(
          12,
          (index) => send(port, 'transfer-$index', List.filled(1024, index)),
        ),
      );
      expect(results.every((result) => result.status == HttpStatus.ok), isTrue);
      final paths = results
          .map((result) => result.body['path'] as String)
          .toList();
      expect(paths.toSet(), hasLength(12));
      for (var index = 0; index < paths.length; index++) {
        expect(
          await File(paths[index]).readAsBytes(),
          List.filled(1024, index),
        );
      }
    },
  );

  test(
    'duplicate active transfer IDs are rejected while a decision is pending',
    () async {
      final incoming = Completer<IncomingTransfer>();
      final port = await start(
        autoAccept: false,
        onIncoming: (transfer) {
          incoming.complete(transfer);
          return transfer.decision.future;
        },
      );
      final first = send(port, 'same-id', [1]);
      final transfer = await incoming.future;
      final duplicate = await send(port, 'same-id', [2]);
      expect(duplicate.status, HttpStatus.conflict);
      transfer.decision.complete(true);
      expect((await first).status, HttpStatus.ok);
      expect(await File('${directory.path}/shared.bin').readAsBytes(), [1]);
    },
  );

  test(
    'live receiver settings apply to new uploads without interrupting an existing request',
    () async {
      final incoming = Completer<IncomingTransfer>();
      final idle = Completer<void>();
      var prompts = 0;
      final port = await start(
        autoAccept: false,
        onIncoming: (transfer) {
          prompts++;
          incoming.complete(transfer);
          return transfer.decision.future;
        },
      );
      server.onIdle = () {
        if (!idle.isCompleted) idle.complete();
      };
      final first = send(port, 'old-folder', [1], name: 'before.bin');
      final transfer = await incoming.future;
      final nextDirectory = await Directory('${directory.path}/next').create();
      server.updateReceiverSettings(
        downloadDirectory: nextDirectory.path,
        autoAccept: true,
      );
      final second = await send(port, 'new-folder', [2], name: 'after.bin');
      expect(second.status, HttpStatus.ok);
      expect(prompts, 1);
      expect(server.port, port);
      expect(await File('${nextDirectory.path}/after.bin').readAsBytes(), [2]);
      expect(idle.isCompleted, isFalse);
      transfer.decision.complete(true);
      expect((await first).status, HttpStatus.ok);
      expect(await File('${directory.path}/before.bin').readAsBytes(), [1]);
      await idle.future.timeout(const Duration(seconds: 2));
      expect(server.isRunning, isTrue);
    },
  );

  test('stop resolves pending decisions and joins request cleanup', () async {
    final incoming = Completer<IncomingTransfer>();
    final port = await start(
      autoAccept: false,
      onIncoming: (transfer) {
        incoming.complete(transfer);
        return transfer.decision.future;
      },
    );
    final upload = send(port, 'pending', [
      1,
      2,
      3,
    ]).then<Object?>((result) => result, onError: (Object error) => error);
    final transfer = await incoming.future;
    await server.stop().timeout(const Duration(seconds: 3));
    await upload;
    expect(transfer.decision.isCompleted, isTrue);
    expect(controls['pending']!.isCancelled, isTrue);
    expect(progress.last.status, TransferProgressStatus.cancelled);
    expect(await directory.list().toList(), isEmpty);
  });

  test(
    'rejection emits a terminal status and leaves no partial file',
    () async {
      final port = await start(
        autoAccept: false,
        onIncoming: (_) async => false,
      );
      final result = await send(port, 'rejected', [1, 2, 3]);
      expect(result.status, HttpStatus.forbidden);
      expect(progress.last.status.isTerminal, isTrue);
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test('malformed escaped headers do not terminate the listener', () async {
    final port = await start();
    final result = await send(port, 'bad-header', [1], name: '%invalid');
    expect(result.status, HttpStatus.badRequest);
    expect((await send(port, 'healthy', [2])).status, HttpStatus.ok);
  });
  test(
    'cancel interrupts an idle request body and deletes its partial file',
    () async {
      final port = await start();
      final socket = await Socket.connect('127.0.0.1', port);
      addTearDown(socket.destroy);
      final response = utf8.decoder.bind(socket).join();
      socket.write(
        'POST /api/transfers HTTP/1.1\r\n'
        'Host: 127.0.0.1\r\n'
        'Content-Length: 1048576\r\n'
        'x-bshare-transfer-id: idle-body\r\n'
        'x-bshare-file-size: 1048576\r\n\r\n',
      );
      socket.add([1, 2, 3]);
      await socket.flush();
      while (progress.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      controls['idle-body']!.cancel();
      expect(
        await response.timeout(const Duration(seconds: 3)),
        anyOf(isEmpty, contains('499')),
      );
      await server.stop();
      expect(progress.last.status, TransferProgressStatus.cancelled);
      expect(await directory.list().toList(), isEmpty);
    },
  );
  test(
    'camera and screen endpoints remain independent and clear on stop',
    () async {
      final port = await start();
      Future<({int status, Map<String, dynamic> body})> request(
        String path, {
        bool post = false,
      }) async {
        final request = await client.openUrl(
          post ? 'POST' : 'GET',
          Uri.parse('http://127.0.0.1:$port$path'),
        );
        if (post) {
          request.write(jsonEncode({'type': 'offer', 'sdp': 'camera-offer'}));
        }
        final response = await request.close();
        return (
          status: response.statusCode,
          body:
              jsonDecode(await utf8.decoder.bind(response).join())
                  as Map<String, dynamic>,
        );
      }

      expect(
        (await request('/api/camera/offer', post: true)).body['error'],
        'camera-share-not-active',
      );
      expect(
        (await request('/api/camera/metadata')).status,
        HttpStatus.serviceUnavailable,
      );
      server.cameraOfferHandler = (offer) async => {
        'type': 'answer',
        'sdp': offer['sdp'],
      };
      server.cameraMetadataHandler = () => {
        'source': 'camera',
        'cameraId': '1',
      };
      final offer = await request('/api/camera/offer', post: true);
      expect(offer.status, HttpStatus.ok);
      expect(offer.body['answer'], {'type': 'answer', 'sdp': 'camera-offer'});
      expect((await request('/api/camera/metadata')).body['metadata'], {
        'source': 'camera',
        'cameraId': '1',
      });
      expect(
        (await request('/api/screen/metadata')).body['error'],
        'screen-share-not-active',
      );
      expect(
        (await request('/api/screen/offer', post: true)).status,
        HttpStatus.serviceUnavailable,
      );
      await server.stop();
      expect(server.cameraOfferHandler, isNull);
      expect(server.cameraMetadataHandler, isNull);
      expect(server.cameraAllowedRemoteSubnets, isNull);
    },
  );

  test(
    'USB camera endpoints enforce the exact tethering subnet prefix',
    () async {
      final port = await start();
      var offers = 0;
      server.cameraOfferHandler = (_) async {
        offers++;
        return {'type': 'answer', 'sdp': 'usb'};
      };
      server.cameraMetadataHandler = () => {'source': 'camera'};
      Future<int> request(String path, {bool post = false}) async {
        final request = await client.openUrl(
          post ? 'POST' : 'GET',
          Uri.parse('http://127.0.0.1:$port$path'),
        );
        if (post) request.write(jsonEncode({'type': 'offer', 'sdp': 'usb'}));
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      }

      // /32 deliberately differs from the client's loopback address by one bit.
      server.cameraAllowedRemoteSubnets = ['127.0.0.0/32'];
      expect(await request('/api/camera/metadata'), HttpStatus.forbidden);
      expect(
        await request('/api/camera/offer', post: true),
        HttpStatus.forbidden,
      );
      expect(offers, 0);
      expect(await request('/api/ping'), HttpStatus.ok);
      server.cameraAllowedRemoteSubnets = ['127.0.0.0/31'];
      expect(await request('/api/camera/metadata'), HttpStatus.ok);
      expect(await request('/api/camera/offer', post: true), HttpStatus.ok);
      expect(offers, 1);
      server.cameraAllowedRemoteSubnets = [];
      expect(
        await request('/api/camera/offer', post: true),
        HttpStatus.forbidden,
      );
    },
  );
}
