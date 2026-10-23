// Run from the repository root with:
// dart run tool/transfer_benchmark.dart --json=/tmp/bshare-performance.json
// Uses the production HTTP sender/receiver. No Flutter engine is required.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/domain/entities/selected_transfer_file.dart';
import 'package:bshare/src/domain/entities/send_progress.dart';
import 'package:bshare/src/domain/entities/transfer_control.dart';
import 'package:bshare/src/domain/entities/transfer_progress_status.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/file_server.dart';
import 'package:bshare/src/infrastructure/services/file_transfer_client.dart';

const _mib = 1024 * 1024;
const _timeout = Duration(seconds: 30);

Future<void> main(List<String> arguments) async {
  final errors = <String>[];
  await runZonedGuarded<Future<void>>(() => _benchmark(arguments, errors), (
    error,
    stack,
  ) {
    // Keep the harness alive long enough to close servers and remove files
    // if an unawaited production task reports an asynchronous failure.
    errors.add('Asynchronous error: $error\n$stack');
    stderr.writeln('Asynchronous production error: $error');
    exitCode = 1;
  });
}

Future<void> _benchmark(List<String> arguments, List<String> errors) async {
  final options = <String, String>{
    for (final argument in arguments)
      if (argument.startsWith('--') && argument.contains('='))
        argument.substring(2, argument.indexOf('=')): argument.substring(
          argument.indexOf('=') + 1,
        ),
  };
  final sizeMiB = int.parse(options['file-mib'] ?? '32');
  final rounds = int.parse(options['rounds'] ?? '3');
  final cycles = int.parse(options['cycles'] ?? '20');
  if (sizeMiB < 1 || rounds < 1 || cycles < 1) {
    throw ArgumentError('file-mib, rounds and cycles must be positive.');
  }
  final directory = await Directory.systemTemp.createTemp('bshare-benchmark-');
  final report = <String, Object?>{
    'benchmark': 'production HTTP sender/receiver over IPv4 loopback',
    'label': options['label'] ?? 'working-tree',
    'recordedAtUtc': DateTime.now().toUtc().toIso8601String(),
    'dart': Platform.version,
    'os': Platform.operatingSystemVersion,
    'processors': Platform.numberOfProcessors,
    'fileMiB': sizeMiB,
    'rounds': rounds,
    'cycles': cycles,
  };
  try {
    final files = <SelectedTransferFile>[];
    for (var index = 0; index < 3; index++) {
      final file = File('${directory.path}/payload-$index.bin');
      await _writePayload(file, sizeMiB * _mib);
      files.add(
        SelectedTransferFile(
          path: file.path,
          name: 'payload-$index.bin',
          size: sizeMiB * _mib,
        ),
      );
    }
    final small = File('${directory.path}/session.bin');
    await _writePayload(small, 128 * 1024);
    final sessionFile = SelectedTransferFile(
      path: small.path,
      name: 'session.bin',
      size: 128 * 1024,
    );
    // Warm up Dart JIT, networking, file I/O and the real service code.
    await _transfer(directory, [sessionFile], 'warmup');
    final throughput = <Map<String, Object?>>[];
    for (final concurrency in [1, 3]) {
      for (var round = 0; round < rounds; round++) {
        final result = await _transfer(
          directory,
          files.take(concurrency).toList(),
          'throughput-$concurrency-$round',
        );
        throughput.add(result);
        stderr.writeln(jsonEncode(result));
      }
    }
    report['throughput'] = throughput;
    report['sessions'] = await _repeatedSessions(
      directory,
      sessionFile,
      cycles,
    );
    report['cancelWhileWaitingForResponse'] = await _cancelAwaitingResponse(
      sessionFile,
    );
    report['pauseThenCancel'] = await _pauseThenCancel(directory, files.first);
    report['stopDuringReceive'] = await _stopDuringReceive(directory);
    final sessions = report['sessions']! as Map<String, Object?>;
    final before = sessions['before']! as Map<String, Object?>;
    final after = sessions['after']! as Map<String, Object?>;
    final cancel =
        report['cancelWhileWaitingForResponse']! as Map<String, Object?>;
    final pause = report['pauseThenCancel']! as Map<String, Object?>;
    final stop = report['stopDuringReceive']! as Map<String, Object?>;
    final checks = <String, bool>{
      'noDescriptorGrowthAcrossSessions':
          before['fileDescriptors'] == after['fileDescriptors'] &&
          before['socketDescriptors'] == after['socketDescriptors'],
      'cancelWhileWaitingClosesStream':
          cancel['streamClosedWithin2s'] == true &&
          (cancel['terminalBeforeReceiverRelease']! as List).singleOrNull ==
              'cancelled',
      'cancelPausedCleansUp':
          (pause['terminal']! as List).singleOrNull == 'cancelled' &&
          (pause['remainingFiles']! as List).isEmpty &&
          pause['receiverActive'] == 0,
      'stopAwaitsCleanup':
          stop['activeAtStopReturn'] == 0 &&
          (stop['filesAtStopReturn']! as List).isEmpty &&
          stop['serverIsRunning'] == false,
    };
    report['checks'] = checks;
    if (checks.values.any((passed) => !passed)) exitCode = 1;
  } catch (error, stack) {
    errors.add('$error\n$stack');
    exitCode = 1;
  } finally {
    try {
      await directory.delete(recursive: true);
    } catch (error) {
      errors.add('Temporary file cleanup: $error');
      exitCode = 1;
    }
    report['errors'] = errors;
    report['finalResources'] = _resources();
    final encoded = const JsonEncoder.withIndent('  ').convert(report);
    if (options['json'] case final path?) {
      await File(path).writeAsString('$encoded\n');
    }
    stdout.writeln(encoded);
  }
}

class _QuietLogger extends AppLogger {
  @override
  void info(String message) {}
  @override
  void warn(String message) {}
  @override
  void error(String message, [Object? error]) {}
}

class _Receiver {
  _Receiver(this.directory);
  final Directory directory;
  final server = FileServer(_QuietLogger());
  final controls = <String, TransferControl>{};
  final active = <String>{};
  final saved = <String>[];
  final terminal = <String, TransferProgressStatus>{};
  int maximumActive = 0;
  int progressEvents = 0;

  Future<DeviceInfo> start() async {
    final port = await server.start(
      preferredPort: 0,
      downloadDirectory: directory.path,
      autoAccept: true,
      onIncoming: (_) async => true,
      onSaved: ({required transfer, required savedPath}) async {
        saved.add(savedPath);
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
            progressEvents++;
            if (status == TransferProgressStatus.receiving) {
              active.add(transfer.id);
              maximumActive = math.max(maximumActive, active.length);
            }
            if (status.isTerminal) {
              active.remove(transfer.id);
              terminal[transfer.id] = status;
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
    return DeviceInfo(
      id: 'benchmark',
      name: 'Loopback',
      platform: Platform.operatingSystem,
      ip: InternetAddress.loopbackIPv4.address,
      port: port,
      lastSeen: DateTime.now(),
    );
  }
}

Future<Map<String, Object?>> _transfer(
  Directory root,
  List<SelectedTransferFile> files,
  String label,
) async {
  final destination = Directory('${root.path}/$label');
  final receiver = _Receiver(destination);
  final client = FileTransferClient(_QuietLogger());
  final initialResources = _resources();
  var peakRss = ProcessInfo.currentRss;
  final sampler = Timer.periodic(const Duration(milliseconds: 10), (_) {
    peakRss = math.max(peakRss, ProcessInfo.currentRss);
  });
  final statuses = <String, TransferProgressStatus>{};
  var senderEvents = 0;
  try {
    final target = await receiver.start();
    final stopwatch = Stopwatch()..start();
    await for (final event
        in client
            .sendFiles(
              target: target,
              files: files,
              senderId: label,
              senderName: 'Benchmark',
              controls: {
                for (final file in files) file.path: TransferControl(),
              },
            )
            .timeout(_timeout)) {
      senderEvents++;
      if (event.isDone) statuses[event.id] = event.status;
    }
    stopwatch.stop();
    if (statuses.length != files.length ||
        statuses.values.any((s) => s != TransferProgressStatus.completed) ||
        receiver.saved.length != files.length) {
      throw StateError('Incomplete $label: $statuses / ${receiver.saved}');
    }
    // Validation is outside the throughput interval and reads every byte.
    for (final file in files) {
      await _validatePayload(
        File('${destination.path}/${file.name}'),
        file.size,
      );
    }
    final totalBytes = files.fold<int>(0, (sum, file) => sum + file.size);
    return {
      'label': label,
      'concurrency': files.length,
      'totalMiB': totalBytes / _mib,
      'elapsedMs': stopwatch.elapsedMicroseconds / 1000,
      'aggregateMiBPerSecond':
          totalBytes / _mib / (stopwatch.elapsedMicroseconds / 1000000),
      'peakSampledRssMiB': peakRss / _mib,
      'startRssMiB': (initialResources['rssBytes']! as int) / _mib,
      'maximumReceiving': receiver.maximumActive,
      'senderProgressEvents': senderEvents,
      'receiverProgressEvents': receiver.progressEvents,
      'verifiedFiles': receiver.saved.length,
    };
  } finally {
    sampler.cancel();
    client.dispose();
    await receiver.server.stop();
    if (await destination.exists()) await destination.delete(recursive: true);
  }
}

Future<Map<String, Object?>> _repeatedSessions(
  Directory root,
  SelectedTransferFile file,
  int cycles,
) async {
  final before = _resources();
  final watch = Stopwatch()..start();
  final samples = <Map<String, Object?>>[];
  for (var index = 0; index < cycles; index++) {
    await _transfer(root, [file], 'session-$index');
    // Let completed HTTP sockets and file handles close before sampling.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    samples.add({'session': index + 1, ..._resources()});
  }
  watch.stop();
  return {
    'completed': cycles,
    'elapsedMs': watch.elapsedMicroseconds / 1000,
    'before': before,
    'after': _resources(),
    'samples': samples,
  };
}

Future<Map<String, Object?>> _cancelAwaitingResponse(
  SelectedTransferFile file,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final client = FileTransferClient(_QuietLogger());
  final control = TransferControl();
  final bodyReceived = Completer<void>();
  final releaseResponse = Completer<void>();
  final handler = server.first.then((request) async {
    try {
      await request.drain<void>();
      bodyReceived.complete();
      await releaseResponse.future;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"ok":true}');
      await request.response.close();
    } catch (_) {
      // Client cancellation is the event under measurement.
    }
  });
  final events = <SendProgress>[];
  final finished = client
      .sendFile(
        target: DeviceInfo(
          id: 'hold-response',
          name: 'Hold response',
          platform: 'benchmark',
          ip: '127.0.0.1',
          port: server.port,
          lastSeen: DateTime.now(),
        ),
        file: file,
        transferId: 'cancel-waiting',
        senderId: 'benchmark',
        senderName: 'Benchmark',
        control: control,
      )
      .forEach(events.add);
  try {
    await bodyReceived.future.timeout(_timeout);
    final watch = Stopwatch()..start();
    control.cancel();
    var completedBeforeRelease = true;
    try {
      await finished.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      completedBeforeRelease = false;
    }
    watch.stop();
    return {
      'streamClosedWithin2s': completedBeforeRelease,
      'observedMs': watch.elapsedMicroseconds / 1000,
      'terminalBeforeReceiverRelease': events
          .where((event) => event.isDone)
          .map((event) => event.status.name)
          .toList(),
    };
  } finally {
    releaseResponse.complete();
    await handler.timeout(_timeout);
    await finished.timeout(_timeout);
    client.dispose();
    await server.close(force: true);
  }
}

Future<Map<String, Object?>> _pauseThenCancel(
  Directory root,
  SelectedTransferFile file,
) async {
  final destination = Directory('${root.path}/cancel-paused');
  final receiver = _Receiver(destination);
  final client = FileTransferClient(_QuietLogger());
  final control = TransferControl();
  final watch = Stopwatch();
  Timer? cancelTimer;
  final terminal = <String>[];
  try {
    final target = await receiver.start();
    await for (final event
        in client
            .sendFile(
              target: target,
              file: file,
              transferId: 'cancel-paused',
              senderId: 'benchmark',
              senderName: 'Benchmark',
              control: control,
            )
            .timeout(_timeout)) {
      if (event.sentBytes > 0 && cancelTimer == null) {
        control.pause();
        cancelTimer = Timer(const Duration(milliseconds: 50), () {
          watch.start();
          control.cancel();
        });
      }
      if (event.isDone) terminal.add(event.status.name);
    }
    watch.stop();
    await receiver.server.stop();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return {
      'terminal': terminal,
      'cancelToStreamClosedMs': watch.elapsedMicroseconds / 1000,
      'remainingFiles': await _fileNames(destination),
      'receiverActive': receiver.active.length,
    };
  } finally {
    cancelTimer?.cancel();
    control.cancel();
    client.dispose();
    await receiver.server.stop();
    if (await destination.exists()) await destination.delete(recursive: true);
  }
}

Future<Map<String, Object?>> _stopDuringReceive(Directory root) async {
  final destination = Directory('${root.path}/stop-receive');
  final receiver = _Receiver(destination);
  final http = HttpClient();
  HttpClientRequest? request;
  try {
    final target = await receiver.start();
    request = await http.postUrl(
      target.baseUri.replace(path: '/api/transfers'),
    );
    request.contentLength = 4 * _mib;
    request.headers.set('x-bshare-file-size', 4 * _mib);
    request.headers.set('x-bshare-file-name', 'interrupted.bin');
    request.headers.set('x-bshare-transfer-id', 'interrupted');
    request.add(Uint8List(64 * 1024));
    await request.flush();
    // Observe the file itself: UI progress callbacks can be throttled and need
    // not emit the first chunk before a deliberately stalled body.
    final partial = File('${destination.path}/interrupted.bin');
    final waitForWrite = Stopwatch()..start();
    while (!await partial.exists() || await partial.length() == 0) {
      if (waitForWrite.elapsed > _timeout) {
        throw TimeoutException('Receiver did not write the initial chunk');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final watch = Stopwatch()..start();
    await receiver.server.stop().timeout(const Duration(seconds: 2));
    watch.stop();
    final activeAtStopReturn = receiver.active.length;
    final filesAtStopReturn = await _fileNames(destination);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return {
      'stopMs': watch.elapsedMicroseconds / 1000,
      'activeAtStopReturn': activeAtStopReturn,
      'filesAtStopReturn': filesAtStopReturn,
      'remainingFiles': await _fileNames(destination),
      'receiverActive': receiver.active.length,
      'receiverTerminal': receiver.terminal.values.map((s) => s.name).toList(),
      'serverIsRunning': receiver.server.isRunning,
    };
  } finally {
    request?.abort();
    http.close(force: true);
    await receiver.server.stop();
    if (await destination.exists()) await destination.delete(recursive: true);
  }
}

Future<List<String>> _fileNames(Directory directory) async {
  if (!await directory.exists()) return [];
  return directory
      .list(recursive: true)
      .where((entity) => entity is File)
      .map((entity) => entity.path.substring(directory.path.length + 1))
      .toList();
}

Map<String, Object?> _resources() {
  int? handles;
  int? sockets;
  if (Platform.isLinux) {
    final entries = Directory('/proc/self/fd').listSync();
    handles = entries.length;
    sockets = 0;
    for (final entry in entries) {
      try {
        if (Link(entry.path).targetSync().startsWith('socket:')) {
          sockets = (sockets ?? 0) + 1;
        }
      } on FileSystemException {
        // The descriptor used by listSync itself is already closed.
      }
    }
  }
  return {
    'rssBytes': ProcessInfo.currentRss,
    'fileDescriptors': handles,
    'socketDescriptors': sockets,
  };
}

Future<void> _writePayload(File file, int length) async {
  final bytes = Uint8List(256 * 1024);
  for (var index = 0; index < bytes.length; index++) {
    bytes[index] = index % 251;
  }
  final handle = await file.open(mode: FileMode.write);
  try {
    var offset = 0;
    while (offset < length) {
      final count = math.min(bytes.length, length - offset);
      await handle.writeFrom(bytes, 0, count);
      offset += count;
    }
    await handle.flush();
  } finally {
    await handle.close();
  }
}

Future<void> _validatePayload(File file, int expectedLength) async {
  var offset = 0;
  await for (final chunk in file.openRead()) {
    for (var index = 0; index < chunk.length; index++) {
      if (chunk[index] != ((offset + index) % (256 * 1024)) % 251) {
        throw StateError('Payload mismatch at ${offset + index}: ${file.path}');
      }
    }
    offset += chunk.length;
  }
  if (offset != expectedLength) {
    throw StateError(
      'Expected $expectedLength bytes, got $offset: ${file.path}',
    );
  }
}
