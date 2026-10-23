import 'package:bshare/src/infrastructure/services/camera_capture_lifecycle_gate.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  tearDown(() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('foreground capture does not wait for a timer', (tester) async {
    final gate = CameraCaptureLifecycleGate();
    addTearDown(gate.dispose);
    await gate.waitForForeground();
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('permission result in inactive waits for the resumed event', (
    tester,
  ) async {
    final gate = CameraCaptureLifecycleGate();
    addTearDown(gate.dispose);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    var started = false;
    final ready = gate.waitForForeground().then((_) => started = true);
    await tester.pump();
    expect(started, isFalse);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await ready;
    expect(started, isTrue);
    await tester.pump(const Duration(seconds: 10));
  });

  for (final state in [
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.detached,
  ]) {
    testWidgets('capture rejects an already $state activity', (tester) async {
      final gate = CameraCaptureLifecycleGate();
      addTearDown(gate.dispose);
      binding.handleAppLifecycleStateChanged(state);
      await expectLater(gate.waitForForeground(), throwsStateError);
    });
  }

  testWidgets('going to background while waiting rejects immediately', (
    tester,
  ) async {
    final gate = CameraCaptureLifecycleGate();
    addTearDown(gate.dispose);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final failed = expectLater(gate.waitForForeground(), throwsStateError);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await failed;
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('inactive capture times out after three seconds', (tester) async {
    final gate = CameraCaptureLifecycleGate();
    addTearDown(gate.dispose);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    var completed = false;
    final failed = expectLater(
      gate.waitForForeground().whenComplete(() => completed = true),
      throwsStateError,
    );
    await tester.pump(const Duration(milliseconds: 2999));
    expect(completed, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    await failed;
    expect(completed, isTrue);
  });

  testWidgets('stop cancels pending wait and the next capture can resume', (
    tester,
  ) async {
    final gate = CameraCaptureLifecycleGate();
    addTearDown(gate.dispose);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final failed = expectLater(gate.waitForForeground(), throwsStateError);
    gate.cancel();
    await failed;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await gate.waitForForeground();
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('dispose cancels pending wait and rejects later calls', (
    tester,
  ) async {
    final gate = CameraCaptureLifecycleGate();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final failed = expectLater(gate.waitForForeground(), throwsStateError);
    gate.dispose();
    await failed;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await expectLater(gate.waitForForeground(), throwsStateError);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('overlapping waits share one lifecycle subscription', (
    tester,
  ) async {
    final gate = CameraCaptureLifecycleGate();
    addTearDown(gate.dispose);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final first = gate.waitForForeground();
    final second = gate.waitForForeground();
    expect(identical(first, second), isTrue);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await Future.wait([first, second]);
    await tester.pump(const Duration(seconds: 10));
  });
}
