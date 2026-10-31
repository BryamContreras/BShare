import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bshare/src/infrastructure/services/process_runner.dart';
import 'package:bshare/src/infrastructure/services/usb_adb_transport_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _protocol = '''
device { serial: "any-vendor-serial" state: DEVICE model: "Some_Phone" connection_type: USB transport_id: 41 }
device { serial: "pending" state: UNAUTHORIZED connection_type: USB transport_id: 42 }
device { serial: "off" state: OFFLINE connection_type: USB transport_id: 43 }
device { serial: "wireless-name" state: DEVICE connection_type: SOCKET transport_id: 44 }
device { serial: "emulator-5554" state: DEVICE connection_type: SOCKET transport_id: 45 }
''';

class _Runner extends ProcessRunner {
  final List<List<String>> calls = [];
  bool failReverse = false;
  bool throwReverseList = false;
  String reverseTarget = '';
  String listing = '';

  Future<int> createMapping({
    required int transportId,
    required bool reverse,
    required int listenerPort,
    required int targetPort,
  }) async {
    calls.add([
      '-H',
      '127.0.0.1',
      '-P',
      '5037',
      '-t',
      '$transportId',
      reverse ? 'reverse' : 'forward',
      '--no-rebind',
      'tcp:localhost:$listenerPort',
      'tcp:$targetPort',
    ]);
    if (reverse) {
      reverseTarget = 'tcp:$targetPort';
      if (failReverse) {
        throw const UsbAdbTransportException('adb-command-failed');
      }
    }
    return reverse ? 41231 : 41230;
  }

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    Map<String, String>? environment,
  }) async {
    calls.add(List.of(arguments));
    if (arguments.length == 1 && arguments.first == 'version') {
      return ProcessResult(1, 0, 'Android Debug Bridge version 1.0.41', '');
    }
    final command = arguments.skip(4).toList();
    var output = '';
    var code = 0;
    if (command.join(' ') == 'devices -l') output = listing;
    if (command.contains('get-devpath')) output = 'unknown';
    if (command.contains('forward') && command.contains('--no-rebind')) {
      output = '41230';
    }
    if (command.contains('reverse') && command.contains('--no-rebind')) {
      reverseTarget = command.last;
      if (failReverse) {
        code = 1;
      } else {
        output = '41231';
      }
    }
    if (command.join(' ') == 'forward --list') {
      output = 'any-vendor-serial tcp:41230 tcp:53317';
    }
    if (command.contains('reverse') && command.contains('--list')) {
      if (throwReverseList) {
        throw const ProcessException('test-adb', [], 'timeout');
      }
      output = 'UsbFfs tcp:41231 $reverseTarget';
    }
    return ProcessResult(1, code, output, '');
  }
}

void main() {
  test('AOSP connection type accepts USB despite missing Windows bus path', () {
    final devices = UsbAdbTransportService.parseDeviceProtocol(_protocol);
    expect(devices.map((item) => item.serial), [
      'any-vendor-serial',
      'pending',
      'off',
    ]);
    expect(devices.map((item) => item.state), [
      UsbAdbDeviceState.authorized,
      UsbAdbDeviceState.unauthorized,
      UsbAdbDeviceState.offline,
    ]);
    expect(devices.first.label, 'Some Phone');
    expect(devices.first.transportId, 41);
  });

  test(
    'invalid or ambiguous device identities never become USB transports',
    () {
      const text = '''
device { serial: "192.168.1.5:5555" state: DEVICE connection_type: USB transport_id: 1 }
device { serial: "emulator-5554" state: DEVICE connection_type: USB transport_id: 2 }
device { serial: "adb-phone._adb-tls-connect._tcp" state: DEVICE connection_type: USB transport_id: 3 }
device { serial: "-option" state: DEVICE connection_type: USB transport_id: 4 }
device { serial: "without-type" state: DEVICE transport_id: 5 }
device { serial: "no-id" state: DEVICE connection_type: USB }
device { serial: "ok" state: DEVICE connection_type: USB transport_id: 6 }
device { serial: "duplicate" state: DEVICE connection_type: USB transport_id: 6 }
''';
      expect(
        UsbAdbTransportService.parseDeviceProtocol(
          text,
        ).map((item) => item.serial),
        ['ok'],
      );
    },
  );

  test(
    'legacy fallback requires actual USB path, never a plausible phone serial',
    () async {
      final runner = _Runner()
        ..listing = 'phone device model:Phone transport_id:1\n';
      final service = UsbAdbTransportService(
        runner: runner,
        createMapping: runner.createMapping,
        executable: 'test-adb',
        readDeviceProtocol: () async => null,
      );
      expect(await service.listDevices(), isEmpty);
    },
  );

  test(
    'session owns two dynamic mappings, relay-only config and idempotent close',
    () async {
      final runner = _Runner();
      final service = UsbAdbTransportService(
        runner: runner,
        createMapping: runner.createMapping,
        executable: 'test-adb',
        readDeviceProtocol: () async => _protocol,
      );
      final device = (await service.listDevices()).first;
      final session = await service.open(device);
      expect(session.signalingUri.toString(), 'http://127.0.0.1:41230');
      expect(session.serial, device.serial);
      expect(session.transportId, 41);
      expect(
        runner.calls
            .where((call) => call.contains('--no-rebind'))
            .every(
              (call) =>
                  call.any(
                    (value) =>
                        RegExp(r'^tcp:localhost:[1-9]\d+$').hasMatch(value),
                  ) &&
                  call.contains('-t'),
            ),
        isTrue,
      );
      expect(session.desktopIceConfiguration['iceTransportPolicy'], 'relay');
      expect(session.androidIceConfiguration['iceTransportPolicy'], 'relay');
      final desktop =
          (session.desktopIceConfiguration['iceServers'] as List).first as Map;
      final android =
          (session.androidIceConfiguration['iceServers'] as List).single as Map;
      expect(android['urls'], ['turn:127.0.0.1:41231?transport=tcp']);
      expect(android['username'], isNot(desktop['username']));
      expect(android['credential'], isNot(desktop['credential']));
      await session.close();
      await session.close();
      final removals = runner.calls
          .where((arguments) => arguments.contains('--remove'))
          .toList();
      expect(removals.length, 2);
      expect(
        removals.every((call) => call.contains('-t') && call.contains('41')),
        isTrue,
      );
      expect(
        runner.calls.expand((item) => item),
        isNot(contains('--remove-all')),
      );
      expect(
        runner.calls.expand((item) => item),
        isNot(contains('kill-server')),
      );
      final port = int.parse(runner.reverseTarget.substring('tcp:'.length));
      await expectLater(
        Socket.connect('127.0.0.1', port),
        throwsA(isA<SocketException>()),
      );
    },
  );

  test(
    'partial failure removes only the already created forward and closes relay',
    () async {
      final runner = _Runner()..failReverse = true;
      final service = UsbAdbTransportService(
        runner: runner,
        createMapping: runner.createMapping,
        executable: 'test-adb',
        readDeviceProtocol: () async => _protocol,
      );
      await expectLater(
        service.open((await service.listDevices()).first),
        throwsA(isA<UsbAdbTransportException>()),
      );
      final removals = runner.calls
          .where((arguments) => arguments.contains('--remove'))
          .toList();
      expect(removals.length, 1);
      expect(removals.single, contains('forward'));
    },
  );

  test(
    'changed USB transport is rejected before any listener is created',
    () async {
      final runner = _Runner();
      var protocol = _protocol;
      final service = UsbAdbTransportService(
        runner: runner,
        createMapping: runner.createMapping,
        executable: 'test-adb',
        readDeviceProtocol: () async => protocol,
      );
      final device = (await service.listDevices()).first;
      protocol = protocol.replaceAll('transport_id: 41', 'transport_id: 99');
      await expectLater(
        service.open(device),
        throwsA(
          isA<UsbAdbTransportException>().having(
            (error) => error.code,
            'code',
            'usb-device-disconnected',
          ),
        ),
      );
      expect(
        runner.calls.expand((item) => item),
        isNot(contains('--no-rebind')),
      );
    },
  );

  test(
    'disconnection during cleanup never retargets a replacement transport',
    () async {
      final runner = _Runner();
      var protocol = _protocol;
      final service = UsbAdbTransportService(
        runner: runner,
        createMapping: runner.createMapping,
        executable: 'test-adb',
        readDeviceProtocol: () async => protocol,
      );
      final session = await service.open((await service.listDevices()).first);
      protocol = _protocol.replaceAll('transport_id: 41', 'transport_id: 98');
      await session.close();
      expect(runner.calls.expand((item) => item), isNot(contains('--remove')));
    },
  );

  test(
    'reverse cleanup failure still removes independent owned forward',
    () async {
      final runner = _Runner();
      final service = UsbAdbTransportService(
        runner: runner,
        createMapping: runner.createMapping,
        executable: 'test-adb',
        readDeviceProtocol: () async => _protocol,
      );
      final session = await service.open((await service.listDevices()).first);
      runner.throwReverseList = true;
      await session.close();
      final removals = runner.calls
          .where((call) => call.contains('--remove'))
          .toList();
      expect(removals.length, 1);
      expect(removals.single, contains('forward'));
      expect(session.isClosed, isTrue);
    },
  );

  test(
    'real smart socket bypasses CLI hostname restriction and retries occupied ports',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      var rejectFirstForward = true;
      final sockets = <Socket>{};
      final listener = server.listen((socket) async {
        sockets.add(socket);
        final input = StreamIterator(socket);
        final pending = <int>[];
        Future<List<int>> read(int count) async {
          while (pending.length < count) {
            if (!await input.moveNext()) throw StateError('socket closed');
            pending.addAll(input.current);
          }
          final bytes = pending.sublist(0, count);
          pending.removeRange(0, count);
          return bytes;
        }

        Future<String> request() async {
          final length = int.parse(ascii.decode(await read(4)), radix: 16);
          final value = utf8.decode(await read(length));
          requests.add(value);
          return value;
        }

        try {
          var command = await request();
          if (command == 'host:transport-id:41') {
            socket.add(ascii.encode('OKAY'));
            await socket.flush();
            command = await request();
            expect(
              command,
              startsWith('reverse:forward:norebind:tcp:localhost:'),
            );
          } else {
            expect(
              command,
              startsWith(
                'host-transport-id:41:forward:norebind:tcp:localhost:',
              ),
            );
            if (rejectFirstForward) {
              rejectFirstForward = false;
              const failure = 'listener already occupied';
              socket.add(
                ascii.encode(
                  'FAIL${failure.length.toRadixString(16).padLeft(4, '0')}$failure',
                ),
              );
              await socket.flush();
              return;
            }
          }
          final port = int.parse(
            RegExp(r'localhost:(\d+);').firstMatch(command)![1]!,
          );
          expect(port, inInclusiveRange(49152, 65535));
          // Fragment both acknowledgments across multiple TCP writes. Fixed
          // port listeners remain created without a resolved-port response.
          for (final part in ['O', 'KAYO', 'KAY']) {
            socket.add(ascii.encode(part));
            await socket.flush();
          }
        } finally {
          await input.cancel();
          socket.destroy();
          sockets.remove(socket);
        }
      });
      addTearDown(() async {
        await listener.cancel();
        await server.close();
        for (final socket in sockets) {
          socket.destroy();
        }
      });
      final runner = _Runner();
      final service = UsbAdbTransportService(
        runner: runner,
        executable: 'test-adb',
        adbServerPort: server.port,
        readDeviceProtocol: () async => _protocol,
      );
      final session = await service.open((await service.listDevices()).first);
      await session.close();
      expect(
        requests
            .where(
              (command) => command.startsWith('host-transport-id:41:forward:'),
            )
            .length,
        2,
      );
      expect(
        requests.where((command) => command == 'host:transport-id:41').length,
        1,
      );
      expect(
        requests
            .where((command) => command.startsWith('reverse:forward:'))
            .length,
        1,
      );
      expect(
        requests.every((command) => !command.contains('localhost:0')),
        isTrue,
      );
      expect(
        runner.calls.expand((call) => call),
        isNot(contains('--no-rebind')),
      );
    },
  );
}
