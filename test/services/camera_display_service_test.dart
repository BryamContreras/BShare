import 'dart:async';

import 'package:bshare/src/infrastructure/services/camera_display_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'restarting display waits for pending restoration before setting awake',
    (tester) async {
      final gate = Completer<void>();
      final updates = <(bool, bool)>[];
      final display = CameraDisplayService(
        applyState: (awake, dimmed) async {
          updates.add((awake, dimmed));
          if (!awake && !gate.isCompleted) await gate.future;
        },
      );
      await display.start();
      final stopping = display.stop();
      var restarted = false;
      final starting = display.start().then((_) => restarted = true);
      await tester.pump();
      final restartedBeforeRestore = restarted;
      gate.complete();
      await Future.wait([stopping, starting]);
      expect(restartedBeforeRestore, isFalse);
      expect(updates, [(true, false), (false, false), (true, false)]);
      expect(display.active, isTrue);
      await display.dispose();
      expect(updates.last, (false, false));
    },
  );

  testWidgets(
    'dims at 60 seconds, interaction resets timer, wake restores preview',
    (tester) async {
      final updates = <(bool, bool)>[];
      final display = CameraDisplayService(
        applyState: (awake, dimmed) async => updates.add((awake, dimmed)),
      );
      await display.start();
      expect(updates, [(true, false)]);
      await tester.pump(const Duration(seconds: 59));
      expect(display.dimmed.value, isFalse);
      await display.wakeDisplay();
      await tester.pump(const Duration(seconds: 59));
      expect(display.dimmed.value, isFalse);
      expect(updates, [(true, false)]);
      await tester.pump(const Duration(seconds: 1));
      expect(display.dimmed.value, isTrue);
      expect(updates.last, (true, true));
      await display.wakeDisplay();
      expect(display.dimmed.value, isFalse);
      expect(updates.last, (true, false));
      await tester.pump(const Duration(seconds: 60));
      expect(display.dimmed.value, isTrue);
      await display.stop();
      expect(display.active, isFalse);
      expect(display.dimmed.value, isFalse);
      expect(updates.last, (false, false));
      await tester.pump(const Duration(minutes: 2));
      expect(updates.last, (false, false));
      await display.dispose();
    },
  );

  testWidgets('stopping and disposing coalesce pending platform cleanup', (
    tester,
  ) async {
    final gate = Completer<void>();
    var restores = 0;
    final display = CameraDisplayService(
      applyState: (awake, dimmed) async {
        if (!awake) {
          restores++;
          await gate.future;
        }
      },
    );
    await display.start();
    final first = display.stop();
    var secondDone = false;
    final second = display.stop().then((_) => secondDone = true);
    await tester.pump();
    final completedBeforeRestore = secondDone;
    final disposing = display.dispose();
    final duplicateDisposing = display.dispose();
    gate.complete();
    await Future.wait([first, second, disposing, duplicateDisposing]);
    expect(completedBeforeRestore, isFalse);
    expect(restores, 1);
    expect(identical(disposing, duplicateDisposing), isTrue);
  });

  testWidgets(
    'a partly applied start failure restores display and cancels timer',
    (tester) async {
      final updates = <(bool, bool)>[];
      final display = CameraDisplayService(
        applyState: (awake, dimmed) async {
          updates.add((awake, dimmed));
          if (awake) throw StateError('brightness failed after setting awake');
        },
      );
      await expectLater(display.start(), throwsStateError);
      expect(display.active, isFalse);
      expect(display.dimmed.value, isFalse);
      expect(updates, [(true, false), (false, false)]);
      await tester.pump(const Duration(minutes: 2));
      expect(updates.length, 2);
      await display.dispose();
    },
  );

  testWidgets(
    'dispose retries a failed platform restore even after stop cleared active',
    (tester) async {
      var restores = 0;
      final display = CameraDisplayService(
        applyState: (awake, dimmed) async {
          if (!awake && ++restores == 1) throw StateError('restore failed');
        },
      );
      await display.start();
      await expectLater(display.stop(), throwsStateError);
      await display.dispose();
      expect(restores, 2);
    },
  );

  testWidgets(
    'failed dimming still exposes overlay and allows restoring brightness',
    (tester) async {
      final updates = <(bool, bool)>[];
      final display = CameraDisplayService(
        applyState: (awake, dimmed) async {
          updates.add((awake, dimmed));
          if (dimmed) throw StateError('brightness unavailable');
        },
      );
      await display.start();
      await tester.pump(const Duration(minutes: 1));
      expect(display.dimmed.value, isTrue);
      await display.wakeDisplay();
      expect(display.dimmed.value, isFalse);
      expect(updates.last, (true, false));
      await display.dispose();
      expect(updates.last, (false, false));
    },
  );

  testWidgets(
    'dispose during platform start waits and restores before completing',
    (tester) async {
      final gate = Completer<void>();
      final updates = <(bool, bool)>[];
      final display = CameraDisplayService(
        applyState: (awake, dimmed) async {
          updates.add((awake, dimmed));
          if (awake) await gate.future;
        },
      );
      final starting = display.start();
      await tester.pump();
      var disposed = false;
      final disposing = display.dispose().then((_) => disposed = true);
      await tester.pump();
      final completedEarly = disposed;
      gate.complete();
      await starting;
      await disposing;
      expect(completedEarly, isFalse);
      expect(updates, [(true, false), (false, false)]);
      await expectLater(display.start(), throwsStateError);
    },
  );
}
