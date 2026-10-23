import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bshare/src/infrastructure/services/direct_network_service.dart';
import 'package:bshare/src/infrastructure/services/process_runner.dart';
import 'package:flutter_test/flutter_test.dart';

class _PendingProcessRunner extends ProcessRunner {
  final entered = Completer<void>();
  final result = Completer<ProcessResult>();
  var calls = 0;

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    Map<String, String>? environment,
  }) {
    calls++;
    if (!entered.isCompleted) entered.complete();
    return result.future;
  }
}

void main() {
  late Directory directory;
  late File child;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bshare-process-test-');
    child = File('${directory.path}/child.dart');
    await child.writeAsString(r'''
import 'dart:async';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.first == 'output') {
    for (var index = 0; index < 128; index++) {
      stdout.writeln('output-$index');
      stderr.writeln('error-$index');
    }
    exitCode = 7;
    return;
  }
  if (arguments.first == 'ignore-term') {
    ProcessSignal.sigterm.watch().listen((_) {});
  }
  if (arguments.length > 1) {
    await File(arguments[1]).writeAsString('$pid');
  }
  stdout.writeln('ready');
  await stdout.flush();
  Timer.periodic(const Duration(milliseconds: 10), (_) {
    stdout.writeln('running');
    stderr.writeln('running');
  });
}
''');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('returns only after stdout, stderr and exit are collected', () async {
    final result = await const ProcessRunner().run('dart', [
      child.path,
      'output',
    ], timeout: const Duration(seconds: 10));
    expect(result.exitCode, 7);
    expect(
      const LineSplitter().convert(result.stdout as String),
      hasLength(128),
    );
    expect(
      const LineSplitter().convert(result.stderr as String),
      hasLength(128),
    );
    expect(result.stdout, contains('output-127'));
    expect(result.stderr, contains('error-127'));
  });

  test(
    'timeout reaps child and drains both output streams before throwing',
    () async {
      final pidFile = File('${directory.path}/pid');
      await expectLater(
        const ProcessRunner().run('dart', [
          child.path,
          'wait',
          pidFile.path,
          // Includes startup of a fresh Dart VM under concurrent Flutter builds.
        ], timeout: const Duration(seconds: 5)),
        throwsA(isA<TimeoutException>()),
      );
      final childPid = int.parse(await pidFile.readAsString());
      expect(await Directory('/proc/$childPid').exists(), isFalse);
    },
    skip: !Platform.isLinux,
  );

  test(
    'termination escalates and awaits exit when child ignores SIGTERM',
    () async {
      final process = await Process.start('dart', [child.path, 'ignore-term']);
      final ready = Completer<void>();
      final stdoutDone = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) {
            if (line == 'ready' && !ready.isCompleted) ready.complete();
          });
      final stderrDone = process.stderr.drain<void>();
      try {
        await ready.future.timeout(const Duration(seconds: 10));
        final result = await terminateProcess(
          process,
          grace: const Duration(milliseconds: 50),
        );
        expect(result, -ProcessSignal.sigkill.signalNumber);
        expect(await process.exitCode, result);
        await Future.wait([stdoutDone, stderrDone]);
        expect(await Directory('/proc/${process.pid}').exists(), isFalse);
      } finally {
        await terminateProcess(process);
        await Future.wait([stdoutDone, stderrDone]);
        await process.stdin.close();
      }
    },
    skip: !Platform.isLinux,
  );

  test(
    'direct network disposal is idempotent and prevents a new start',
    () async {
      final service = DirectNetworkService();
      final first = service.dispose();
      expect(identical(first, service.dispose()), isTrue);
      await first;
      await expectLater(service.startLocalOnlyHotspot(), throwsStateError);
    },
    skip: !Platform.isLinux,
  );

  test(
    'duplicate starts share work and dispose waits for a pending start',
    () async {
      final runner = _PendingProcessRunner();
      final service = DirectNetworkService(processRunner: runner);
      final first = service.startLocalOnlyHotspot();
      final second = service.startLocalOnlyHotspot();
      expect(identical(first, second), isTrue);
      final failure = expectLater(first, throwsStateError);
      await runner.entered.future;
      var disposed = false;
      final disposal = service.dispose().then((_) => disposed = true);
      await Future<void>.delayed(Duration.zero);
      expect(disposed, isFalse);
      runner.result.completeError(const ProcessException('nmcli', []));
      await failure;
      await disposal;
      expect(runner.calls, 1);
      expect(disposed, isTrue);
    },
    skip: !Platform.isLinux,
  );
}
