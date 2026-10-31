import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bshare/src/infrastructure/services/process_runner.dart';
import 'package:bshare/src/infrastructure/services/usb_turn_relay.dart';

enum UsbAdbDeviceState { authorized, unauthorized, offline }

typedef UsbAdbMappingCreator =
    Future<int> Function({
      required int transportId,
      required bool reverse,
      required int listenerPort,
      required int targetPort,
    });

class UsbAdbDevice {
  const UsbAdbDevice({
    required this.serial,
    required this.label,
    required this.state,
    required this.transportId,
  });
  final String serial;
  final String label;
  final UsbAdbDeviceState state;
  final int transportId;
}

class UsbAdbTransportException implements Exception {
  const UsbAdbTransportException(this.code);
  final String code;
  @override
  String toString() => 'UsbAdbTransportException: $code';
}

/// Uses ADB's existing authorized USB transport, never ADB over Wi-Fi.
/// Does not install drivers, accept debugging prompts, or restart the ADB server.
class UsbAdbTransportService {
  UsbAdbTransportService({
    ProcessRunner runner = const ProcessRunner(),
    String? executable,
    Map<String, String>? environment,
    Future<String?> Function()? readDeviceProtocol,
    UsbAdbMappingCreator? createMapping,
    this.adbServerPort = 5037,
  }) : // Keep the public injection names independent of private fields.
       // ignore: prefer_initializing_formals
       _runner = runner,
       _configuredExecutable = executable,
       _environment = environment ?? Platform.environment,
       // ignore: prefer_initializing_formals
       _readDeviceProtocol = readDeviceProtocol,
       // ignore: prefer_initializing_formals
       _createMapping = createMapping;

  final ProcessRunner _runner;
  final String? _configuredExecutable;
  final Map<String, String> _environment;
  final Future<String?> Function()? _readDeviceProtocol;
  final UsbAdbMappingCreator? _createMapping;
  final int adbServerPort;
  String? _executable;
  List<String> get _serverOptions => [
    '-H',
    '127.0.0.1',
    '-P',
    '$adbServerPort',
  ];

  Future<String> _resolve() async {
    if (_executable != null) return _executable!;
    final suffix = Platform.isWindows ? '.exe' : '';
    final base = File(Platform.resolvedExecutable).parent.path;
    final separator = Platform.pathSeparator;
    String adbAt(String directory) =>
        '$directory${separator}platform-tools${separator}adb$suffix';
    final candidates = <String>[
      if (_configuredExecutable?.isNotEmpty ?? false) _configuredExecutable!,
      if (_environment['BSHARE_ADB']?.isNotEmpty ?? false)
        _environment['BSHARE_ADB']!,
      // macOS requires a flat executable in Contents/MacOS; notices and the
      // upstream manifest live separately in Contents/Resources.
      if (Platform.isMacOS) '$base${separator}adb',
      '$base${separator}tools${separator}platform-tools${separator}adb$suffix',
      '$base${separator}tools${separator}adb$suffix',
      'adb',
      for (final key in ['ANDROID_SDK_ROOT', 'ANDROID_HOME'])
        if (_environment[key]?.isNotEmpty ?? false) adbAt(_environment[key]!),
      if (_environment['LOCALAPPDATA']?.isNotEmpty ?? false)
        adbAt(
          '${_environment['LOCALAPPDATA']}${separator}Android${separator}Sdk',
        ),
      for (final key in ['HOME', 'USERPROFILE'])
        if (_environment[key]?.isNotEmpty ?? false) ...[
          adbAt('${_environment[key]}${separator}Android${separator}Sdk'),
          adbAt(
            '${_environment[key]}${separator}Library${separator}Android${separator}sdk',
          ),
        ],
    ];
    for (final candidate in candidates.toSet()) {
      try {
        final result = await _runner.run(candidate, [
          'version',
        ], timeout: const Duration(seconds: 3));
        if (result.exitCode == 0 &&
            '${result.stdout}'.contains('Android Debug Bridge')) {
          return _executable = candidate;
        }
      } catch (_) {}
      // An explicitly configured binary must not silently select another tool.
      if (candidate == _configuredExecutable ||
          candidate == _environment['BSHARE_ADB']) {
        break;
      }
    }
    throw const UsbAdbTransportException('adb-not-found');
  }

  Future<ProcessResult> _command(
    List<String> arguments, {
    bool checked = true,
  }) async {
    final result = await _runner.run(await _resolve(), [
      ..._serverOptions,
      ...arguments,
    ], timeout: const Duration(seconds: 5));
    if (checked && result.exitCode != 0) {
      throw const UsbAdbTransportException('adb-command-failed');
    }
    return result;
  }

  Future<List<UsbAdbDevice>> listDevices() async {
    // This finite command also starts an absent local ADB server normally.
    final listing = await _command(['devices', '-l']);
    String? protocol;
    try {
      protocol =
          await (_readDeviceProtocol?.call() ??
              _firstDeviceProtocol(adbServerPort));
    } catch (_) {}
    if (protocol != null) return parseDeviceProtocol(protocol);
    final devices = <UsbAdbDevice>[];
    for (final row in '${listing.stdout}'.split(RegExp(r'[\r\n]+'))) {
      final match = RegExp(
        r'^(\S+)\s+(device|unauthorized|offline)\b(.*)$',
      ).firstMatch(row.trim());
      if (match == null || !_physicalSerial(match[1]!)) continue;
      final transport = int.tryParse(
        RegExp(r'\btransport_id:(\d+)').firstMatch(match[3]!)?[1] ?? '',
      );
      if (transport == null || transport < 1) continue;
      final state = _state(match[2]!);
      var usb = RegExp(r'\busb:\S+').hasMatch(match[3]!);
      if (!usb && state == UsbAdbDeviceState.authorized) {
        final path = await _command([
          '-t',
          '$transport',
          'get-devpath',
        ], checked: false);
        usb = path.exitCode == 0 && '${path.stdout}'.trim().startsWith('usb:');
      }
      if (!usb) continue; // Never infer a cable from a serial number or model.
      final label = RegExp(
        r'\bmodel:(\S+)',
      ).firstMatch(match[3]!)?[1]?.replaceAll('_', ' ');
      devices.add(
        UsbAdbDevice(
          serial: match[1]!,
          label: label ?? 'Android USB',
          state: state,
          transportId: transport,
        ),
      );
    }
    return List.unmodifiable(devices);
  }

  /// Parses AOSP's text protobuf schema, whose connection type is independent
  /// of the optional bus path (the native Windows backend may omit that path).
  static List<UsbAdbDevice> parseDeviceProtocol(String text) {
    if (text.length > 65535) {
      throw const FormatException('ADB device list too large');
    }
    final result = <UsbAdbDevice>[];
    final ids = <int>{};
    for (final block in RegExp(
      r'\bdevice\s*\{([^{}]*)\}',
      dotAll: true,
    ).allMatches(text)) {
      final body = block[1]!;
      String? field(String name) => RegExp(
        '\\b$name\\s*:\\s*("(?:[^"\\\\]|\\\\.)*"|[A-Za-z0-9_]+)',
      ).firstMatch(body)?[1];
      String? string(String name) {
        final value = field(name);
        if (value == null || !value.startsWith('"')) return null;
        try {
          return jsonDecode(value) as String;
        } catch (_) {
          return null;
        }
      }

      if (field('connection_type') != 'USB') continue;
      final serial = string('serial');
      final transport = int.tryParse(field('transport_id') ?? '');
      if (serial == null ||
          !_physicalSerial(serial) ||
          transport == null ||
          transport < 1 ||
          !ids.add(transport)) {
        continue;
      }
      final state = field('state');
      if (![
        'DEVICE',
        'UNAUTHORIZED',
        'AUTHORIZING',
        'OFFLINE',
        'NOPERMISSION',
      ].contains(state)) {
        continue;
      }
      result.add(
        UsbAdbDevice(
          serial: serial,
          label: string('model')?.replaceAll('_', ' ') ?? 'Android USB',
          state: state == 'DEVICE'
              ? UsbAdbDeviceState.authorized
              : (state == 'UNAUTHORIZED' ||
                    state == 'AUTHORIZING' ||
                    state == 'NOPERMISSION')
              ? UsbAdbDeviceState.unauthorized
              : UsbAdbDeviceState.offline,
          transportId: transport,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  Future<void> _verifyDevice(UsbAdbDevice device) async {
    final current = await listDevices();
    if (!current.any(
      (item) =>
          item.serial == device.serial &&
          item.transportId == device.transportId &&
          item.state == UsbAdbDeviceState.authorized,
    )) {
      throw const UsbAdbTransportException('usb-device-disconnected');
    }
  }

  Future<UsbRelaySession> open(
    UsbAdbDevice device, {
    int remotePort = 53317,
  }) async {
    if (!_physicalSerial(device.serial) ||
        device.transportId < 1 ||
        device.state != UsbAdbDeviceState.authorized) {
      throw const UsbAdbTransportException('usb-device-not-authorized');
    }
    if (remotePort < 1 || remotePort > 65535) {
      throw ArgumentError.value(remotePort, 'remotePort');
    }
    await _verifyDevice(device);
    final relay = await UsbTurnRelay.start();
    int? forwardPort;
    int? reversePort;
    Future<void> cleanup() async {
      try {
        await _verifyDevice(device);
      } catch (_) {
        await relay.close();
        return;
      }
      try {
        try {
          if (reversePort != null) {
            final existing = await _command([
              '-t',
              '${device.transportId}',
              'reverse',
              '--list',
            ], checked: false);
            if (_ownsMapping(
              '${existing.stdout}',
              'tcp:$reversePort',
              'tcp:${relay.port}',
            )) {
              await _command([
                '-t',
                '${device.transportId}',
                'reverse',
                '--remove',
                'tcp:$reversePort',
              ], checked: false);
            }
          }
        } catch (_) {}
        try {
          if (forwardPort != null) {
            final existing = await _command([
              'forward',
              '--list',
            ], checked: false);
            if (_ownsMapping(
              '${existing.stdout}',
              'tcp:$forwardPort',
              'tcp:$remotePort',
              serial: device.serial,
            )) {
              await _command([
                '-t',
                '${device.transportId}',
                'forward',
                '--remove',
                'tcp:$forwardPort',
              ], checked: false);
            }
          }
        } catch (_) {}
      } finally {
        await relay.close();
      }
    }

    try {
      forwardPort = await _openMapping(
        device,
        reverse: false,
        targetPort: remotePort,
      );
      await _verifyDevice(device);
      reversePort = await _openMapping(
        device,
        reverse: true,
        targetPort: relay.port,
      );
      await _verifyDevice(device);
      return UsbRelaySession._(
        device: device,
        signalingUri: Uri(scheme: 'http', host: '127.0.0.1', port: forwardPort),
        desktopIceConfiguration: relay.desktopIceConfiguration(),
        androidIceConfiguration: relay.androidIceConfiguration(reversePort),
        diagnostics: () => relay.diagnostics,
        close: cleanup,
      );
    } catch (_) {
      await cleanup();
      rethrow;
    }
  }

  Future<int> _openMapping(
    UsbAdbDevice device, {
    required bool reverse,
    required int targetPort,
  }) async {
    // The adb CLI accepts only numeric source ports. The server accepts an
    // explicit localhost listener, but its hostname parser rejects port zero.
    // Pick a high port and use norebind; collisions never replace a listener.
    final random = Random.secure();
    for (var attempt = 0; attempt < 6; attempt++) {
      final port = 49152 + random.nextInt(16384);
      try {
        return await (_createMapping?.call(
              transportId: device.transportId,
              reverse: reverse,
              listenerPort: port,
              targetPort: targetPort,
            ) ??
            _createLoopbackMapping(
              device.transportId,
              reverse,
              port,
              targetPort,
              adbServerPort,
            ));
      } on UsbAdbTransportException catch (error) {
        if (error.code != 'adb-listener-unavailable' || attempt == 5) rethrow;
      }
    }
    throw const UsbAdbTransportException('adb-listener-unavailable');
  }

  static bool _ownsMapping(
    String text,
    String local,
    String remote, {
    String? serial,
  }) => text.split(RegExp(r'[\r\n]+')).any((line) {
    final columns = line.trim().split(RegExp(r'\s+'));
    return columns.length == 3 &&
        (serial == null || columns[0] == serial) &&
        columns[1] == local &&
        columns[2] == remote;
  });
  static bool _physicalSerial(String serial) =>
      serial.isNotEmpty &&
      serial.length <= 256 &&
      !serial.startsWith('-') &&
      !serial.startsWith('emulator-') &&
      !serial.contains(':') &&
      !serial.contains(RegExp(r'\s|[\x00-\x1f]')) &&
      !serial.contains('_adb-tls-');
  static UsbAdbDeviceState _state(String state) => state == 'device'
      ? UsbAdbDeviceState.authorized
      : state == 'unauthorized'
      ? UsbAdbDeviceState.unauthorized
      : UsbAdbDeviceState.offline;
}

class UsbRelaySession {
  UsbRelaySession._({
    required this.device,
    required this.signalingUri,
    required this.desktopIceConfiguration,
    required this.androidIceConfiguration,
    required Map<String, int> Function() diagnostics,
    required Future<void> Function() close,
  }) : // The callback stays private; callers use the idempotent close method.
       // ignore: prefer_initializing_formals
       _close = close,
       // ignore: prefer_initializing_formals
       _diagnostics = diagnostics;
  final UsbAdbDevice device;
  String get serial => device.serial;
  int get transportId => device.transportId;
  final Uri signalingUri;
  final Map<String, dynamic> desktopIceConfiguration;
  final Map<String, dynamic> androidIceConfiguration;
  final Future<void> Function() _close;
  final Map<String, int> Function() _diagnostics;
  Map<String, int> get diagnostics => _diagnostics();
  Future<void>? _closing;
  bool get isClosed => _closing != null;
  Future<void> close() => _closing ??= _close();
}

Future<String?> _firstDeviceProtocol(int serverPort) async {
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    serverPort,
    timeout: const Duration(seconds: 2),
  );
  final iterator = StreamIterator(socket);
  final pending = <int>[];
  Future<List<int>> read(int length) async {
    while (pending.length < length) {
      if (!await iterator.moveNext().timeout(const Duration(seconds: 2))) {
        throw const FormatException('Truncated ADB frame');
      }
      if (pending.length + iterator.current.length > 65543) {
        throw const FormatException('ADB frame too large');
      }
      pending.addAll(iterator.current);
    }
    final value = pending.sublist(0, length);
    pending.removeRange(0, length);
    return value;
  }

  try {
    const command = 'host:track-devices-proto-text';
    socket.add(
      utf8.encode(
        '${command.length.toRadixString(16).padLeft(4, '0')}$command',
      ),
    );
    await socket.flush();
    if (ascii.decode(await read(4)) != 'OKAY') return null;
    final length = int.tryParse(ascii.decode(await read(4)), radix: 16);
    if (length == null || length > 65535) return null;
    return utf8.decode(await read(length));
  } finally {
    await iterator.cancel();
    socket.destroy();
  }
}

Future<int> _createLoopbackMapping(
  int transportId,
  bool reverse,
  int listenerPort,
  int targetPort,
  int serverPort,
) async {
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    serverPort,
    timeout: const Duration(seconds: 2),
  );
  final input = StreamIterator(socket);
  final pending = <int>[];
  Future<List<int>> read(int length) async {
    while (pending.length < length) {
      if (!await input.moveNext().timeout(const Duration(seconds: 3))) {
        throw const UsbAdbTransportException('adb-response-truncated');
      }
      if (pending.length + input.current.length > 8192) {
        throw const UsbAdbTransportException('adb-response-too-large');
      }
      pending.addAll(input.current);
    }
    final result = pending.sublist(0, length);
    pending.removeRange(0, length);
    return result;
  }

  Future<String> text() async {
    final length = int.tryParse(ascii.decode(await read(4)), radix: 16);
    if (length == null || length > 4096) {
      throw const UsbAdbTransportException('adb-invalid-response');
    }
    return utf8.decode(await read(length));
  }

  Future<void> status(String failureCode) async {
    final value = ascii.decode(await read(4));
    if (value == 'OKAY') return;
    if (value == 'FAIL') {
      await text(); // Drain bounded diagnostic, never log it.
    }
    throw UsbAdbTransportException(failureCode);
  }

  Future<void> request(String command) async {
    socket.add(
      utf8.encode(
        '${command.length.toRadixString(16).padLeft(4, '0')}$command',
      ),
    );
    await socket.flush();
  }

  try {
    final mapping =
        'forward:norebind:tcp:localhost:$listenerPort;tcp:$targetPort';
    if (reverse) {
      await request('host:transport-id:$transportId');
      await status('usb-device-disconnected');
      await request('reverse:$mapping');
    } else {
      await request('host-transport-id:$transportId:$mapping');
    }
    await status('adb-listener-unavailable');
    await status('adb-listener-unavailable');
    // Both acknowledgments mean the explicit listener was created. Some old
    // daemons omit a resolved-port string for fixed ports; its known port is
    // enough for ownership and cleanup, so do not strand it waiting for output.
    return listenerPort;
  } finally {
    await input.cancel();
    socket.destroy();
  }
}
