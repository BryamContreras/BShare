import 'dart:async';
import 'dart:io';

/// Runs finite child processes and waits for both exit and output completion.
class ProcessRunner {
  const ProcessRunner();

  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    Map<String, String>? environment,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      environment: environment,
    );
    final completed = Future.wait<Object>([
      process.exitCode,
      process.stdout.transform(systemEncoding.decoder).join(),
      process.stderr.transform(systemEncoding.decoder).join(),
    ]);
    try {
      final result = await completed.timeout(timeout);
      return ProcessResult(
        process.pid,
        result[0] as int,
        result[1] as String,
        result[2] as String,
      );
    } on TimeoutException {
      await terminateProcess(process);
      // Killing is asynchronous. Finish consuming both pipes before returning.
      try {
        await completed;
      } catch (_) {}
      throw TimeoutException('$executable timed out', timeout);
    } finally {
      try {
        await process.stdin.close();
      } catch (_) {}
    }
  }
}

/// Requests exit, escalates if necessary, and reaps the child before returning.
Future<int> terminateProcess(
  Process process, {
  Duration grace = const Duration(seconds: 2),
}) async {
  process.kill();
  try {
    return await process.exitCode.timeout(grace);
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    return await process.exitCode;
  }
}
