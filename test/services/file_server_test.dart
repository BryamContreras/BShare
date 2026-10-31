import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bshare/src/domain/entities/incoming_transfer.dart';
import 'package:bshare/src/domain/entities/transfer_control.dart';
import 'package:bshare/src/domain/entities/transfer_progress_status.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/file_server.dart';
import 'package:bshare/src/infrastructure/services/usb_ice_configuration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late FileServer server;
  late HttpClient client;
  late Map<String, TransferControl> controls;
  late Map<String, Completer<TransferProgressStatus>> terminalProgress;
  late List<({IncomingTransfer transfer, TransferProgressStatus status})>
  progress;

  // Receiving an HTTP response does not order the client's continuation after
  // the server's progress callback. Wait for the particular transfer to finish.
  Future<TransferProgressStatus> terminalFor(String id) => terminalProgress
      .putIfAbsent(id, Completer<TransferProgressStatus>.new)
      .future
      .timeout(const Duration(seconds: 2));

  Future<int> start({
    bool autoAccept = true,
    IncomingTransferHandler? onIncoming,
    int preferredPort = 0,
  }) {
    return server.start(
      preferredPort: preferredPort,
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
            if (status.isTerminal) {
              final terminal = terminalProgress.putIfAbsent(
                transfer.id,
                Completer<TransferProgressStatus>.new,
              );
              if (!terminal.isCompleted) terminal.complete(status);
            }
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
    terminalProgress = {};
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
    'camera control enforces interface, bounded JSON and capability errors',
    () async {
      var commands = 0;
      server.cameraControlHandler = (command) async {
        commands++;
        if (command['token'] != 'valid-token') {
          throw const CameraControlException(
            'camera-control-forbidden',
            status: HttpStatus.forbidden,
          );
        }
        return const CameraControlReply({
          'version': 1,
          'microphoneEnabled': false,
        });
      };
      final port = await start();
      Future<({int status, Map<String, dynamic> body})> control(
        Object body,
      ) async {
        final request = await client.postUrl(
          Uri.parse('http://127.0.0.1:$port/api/camera/control'),
        );
        request.write(jsonEncode(body));
        final response = await request.close();
        return (
          status: response.statusCode,
          body:
              jsonDecode(await utf8.decoder.bind(response).join())
                  as Map<String, dynamic>,
        );
      }

      server.cameraAllowedRemoteSubnets = ['192.0.2.0/24'];
      expect(
        (await control({'token': 'valid-token'})).status,
        HttpStatus.forbidden,
      );
      expect(commands, 0);
      server.cameraAllowedRemoteSubnets = null;
      expect((await control([])).status, HttpStatus.badRequest);
      expect(
        (await control({'token': 'x' * 4096})).status,
        HttpStatus.requestEntityTooLarge,
      );
      expect(commands, 0);
      final rejected = await control({'token': 'wrong'});
      expect(rejected.status, HttpStatus.forbidden);
      expect(rejected.body['error'], 'camera-control-forbidden');
      final accepted = await control({'token': 'valid-token'});
      expect(accepted.status, HttpStatus.ok);
      expect((accepted.body['controls'] as Map)['microphoneEnabled'], isFalse);
      server.cameraControlHandler = null;
      final inactive = await control({'token': 'valid-token'});
      expect(inactive.status, HttpStatus.serviceUnavailable);
      expect(inactive.body['error'], 'camera-share-not-active');
    },
  );

  test(
    'camera stop reply is delivered before its listener drains this request',
    () async {
      final stopped = Completer<void>();
      server.cameraControlHandler = (_) async => CameraControlReply(
        {'stopping': true},
        afterResponse: () async {
          await server.stop();
          stopped.complete();
        },
      );
      final port = await start();
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:$port/api/camera/control'),
      );
      request.write('{}');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await utf8.decoder.bind(response).join()) as Map;
      expect((body['controls'] as Map)['stopping'], isTrue);
      await stopped.future.timeout(const Duration(seconds: 2));
      expect(server.isRunning, isFalse);
      expect(server.cameraControlHandler, isNull);
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
      expect(await terminalFor('denied'), TransferProgressStatus.failed);
      server.fileAccessHandler = (_) async =>
          throw StateError('permission revoked');
      expect(
        (await send(port, 'unavailable', [1])).status,
        HttpStatus.forbidden,
      );
      expect(await terminalFor('unavailable'), TransferProgressStatus.failed);
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
      expect(
        await terminalFor('revoked-at-decision'),
        TransferProgressStatus.failed,
      );
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

  test('another BShare instance cannot share a signaling listener', () async {
    final occupied = await HttpServer.bind(
      InternetAddress.anyIPv4,
      0,
      shared: true,
    );
    addTearDown(() => occupied.close(force: true));
    final port = await start(preferredPort: occupied.port);
    expect(port, isNot(occupied.port));
    expect(server.port, port);
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/api/ping'),
    );
    final response = await request.close();
    expect(response.statusCode, HttpStatus.ok);
    await response.drain<void>();
  });

  test(
    'viewer stop releases only its requested media session and validates ID',
    () async {
      final stopped = <String>[];
      server.screenViewerStopHandler = (id) async => stopped.add('screen:$id');
      server.cameraViewerStopHandler = (id) async => stopped.add('camera:$id');
      final port = await start();
      for (final source in ['screen', 'camera']) {
        final request = await client.postUrl(
          Uri.parse('http://127.0.0.1:$port/api/$source/stop-viewer'),
        );
        request.write(jsonEncode({'viewerId': 'viewer-12345678901234'}));
        final response = await request.close();
        expect(response.statusCode, HttpStatus.ok);
        await response.drain<void>();
      }
      expect(stopped, [
        'screen:viewer-12345678901234',
        'camera:viewer-12345678901234',
      ]);
      final invalid = await client.postUrl(
        Uri.parse('http://127.0.0.1:$port/api/screen/stop-viewer'),
      );
      invalid.write('{}');
      final rejected = await invalid.close();
      expect(rejected.statusCode, HttpStatus.badRequest);
      await rejected.drain<void>();
      expect(stopped, hasLength(2));
      await server.stop();
      expect(server.cameraViewerStopHandler, isNull);
      expect(server.screenViewerStopHandler, isNull);
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
      expect(await terminalFor('rejected'), TransferProgressStatus.failed);
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

  test(
    'USB-only offers require relay configuration even from loopback',
    () async {
      server.usbVideoOnly = true;
      var offers = 0;
      Future<Map<String, dynamic>> answer(Map<String, dynamic> offer) async {
        offers++;
        return {'type': 'answer', 'sdp': offer['sdp']};
      }

      server.cameraOfferHandler = answer;
      server.screenOfferHandler = answer;
      final port = await start();
      for (final source in ['camera', 'screen']) {
        final request = await client.postUrl(
          Uri.parse('http://127.0.0.1:$port/api/$source/offer'),
        );
        request.write(jsonEncode({'type': 'offer', 'sdp': 'no-relay'}));
        final response = await request.close();
        final body =
            jsonDecode(await utf8.decoder.bind(response).join())
                as Map<String, dynamic>;
        expect(response.statusCode, HttpStatus.forbidden);
        expect(body['error'], 'usb-relay-required');
      }
      expect(offers, 0);
    },
  );

  test(
    'loopback USB offers reach the owner handler with validated relay-only SDP',
    () async {
      server.usbVideoOnly = true;
      const relay = 'a=candidate:relay 1 udp 1 127.0.0.1 44000 typ relay';
      final configuration = <String, dynamic>{
        'iceTransportPolicy': 'relay',
        'iceServers': [
          {
            'urls': ['turn:127.0.0.1:43000?transport=tcp'],
            'username': 'test_user_12345678',
            'credential': 'test_password_12345678',
          },
        ],
      };
      var offers = 0;
      Future<Map<String, dynamic>> answer(Map<String, dynamic> offer) async {
        offers++;
        final validated = UsbIceConfiguration.validate(offer['usbRelay']);
        expect(validated['iceTransportPolicy'], 'relay');
        // The video session owns validation and SDP sanitizing; FileServer owns
        // the HTTP transport boundary and must deliver this offer only locally.
        return {
          'type': 'answer',
          'sdp': UsbIceConfiguration.relaySdp(offer['sdp'] as String),
        };
      }

      server.cameraOfferHandler = answer;
      server.screenOfferHandler = answer;
      final port = await start();
      for (final source in ['camera', 'screen']) {
        final request = await client.postUrl(
          Uri.parse('http://127.0.0.1:$port/api/$source/offer'),
        );
        request.write(
          jsonEncode({
            'type': 'offer',
            'sdp':
                'v=0\r\nc=IN IP4 192.168.1.20\r\na=candidate:lan 1 udp 1 192.168.1.20 55000 typ host\r\n$relay\r\n',
            'usbRelay': configuration,
          }),
        );
        final response = await request.close();
        final body =
            jsonDecode(await utf8.decoder.bind(response).join())
                as Map<String, dynamic>;
        expect(response.statusCode, HttpStatus.ok);
        final received = body['answer'] as Map<String, dynamic>;
        expect(received['type'], 'answer');
        expect(received['sdp'], contains(relay));
        expect(received['sdp'], contains('c=IN IP4 127.0.0.1'));
        expect(received['sdp'], isNot(contains('192.168.')));
      }
      expect(offers, 2);
    },
  );

  test(
    'a non-loopback HTTP caller cannot supply USB relay configuration',
    () async {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      final address = interfaces
          .expand((interface) => interface.addresses)
          .where((address) => !address.isLoopback)
          .firstOrNull;
      if (address == null) {
        markTestSkipped(
          'No non-loopback IPv4 interface available for the local HTTP boundary check',
        );
        return;
      }
      var offers = 0;
      Future<Map<String, dynamic>> answer(Map<String, dynamic> offer) async {
        offers++;
        return {'type': 'answer', 'sdp': 'must-not-be-called'};
      }

      server.cameraOfferHandler = answer;
      server.screenOfferHandler = answer;
      server.cameraMetadataHandler = () => {'source': 'camera'};
      server.screenMetadataHandler = () => {'source': 'screen'};
      final port = await start();
      final lanClient = HttpClient()
        ..findProxy = ((_) => 'DIRECT')
        ..connectionTimeout = const Duration(seconds: 2)
        ..connectionFactory = (uri, proxyHost, proxyPort) =>
            Socket.startConnect(address, port, sourceAddress: address);
      addTearDown(() => lanClient.close(force: true));
      // Connect only to this test's listener on this machine, never an external
      // network peer. Some CI systems prohibit even this local-interface route.
      try {
        final ping = await lanClient.getUrl(
          Uri.parse('http://${address.address}:$port/api/ping'),
        );
        final response = await ping.close().timeout(const Duration(seconds: 3));
        await response.drain<void>();
        expect(response.statusCode, HttpStatus.ok);
      } on SocketException {
        markTestSkipped(
          'The platform cannot connect to its local non-loopback interface',
        );
        return;
      } on TimeoutException {
        markTestSkipped(
          'The platform blocks the local non-loopback test route',
        );
        return;
      }
      for (final source in ['camera', 'screen']) {
        final request = await lanClient.postUrl(
          Uri.parse('http://${address.address}:$port/api/$source/offer'),
        );
        request.write(
          jsonEncode({
            'type': 'offer',
            'sdp': 'untrusted-lan-offer',
            'usbRelay': {
              'iceTransportPolicy': 'relay',
              'iceServers': [
                {
                  'urls': ['turn:127.0.0.1:43000?transport=tcp'],
                  'username': 'test_user_12345678',
                  'credential': 'test_password_12345678',
                },
              ],
            },
          }),
        );
        final response = await request.close();
        final body =
            jsonDecode(await utf8.decoder.bind(response).join())
                as Map<String, dynamic>;
        expect(response.statusCode, HttpStatus.forbidden);
        expect(body['error'], 'usb-cable-required');
      }
      expect(offers, 0);
      server.usbVideoOnly = true;
      for (final source in ['camera', 'screen']) {
        final request = await lanClient.getUrl(
          Uri.parse('http://${address.address}:$port/api/$source/metadata'),
        );
        final response = await request.close();
        final body =
            jsonDecode(await utf8.decoder.bind(response).join())
                as Map<String, dynamic>;
        expect(response.statusCode, HttpStatus.forbidden);
        expect(body['error'], 'usb-cable-required');
      }
    },
  );
}
