import 'dart:async';
import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/app_settings.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/network_service.dart';
import 'package:bshare/src/presentation/app.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';

class _Settings extends SettingsController {
  @override
  Future<AppSettings> build() async => const AppSettings(
    deviceId: 'desktop',
    deviceName: 'Desktop',
    downloadDirectory: '/tmp',
    autoAccept: false,
    preferredPort: 53317,
    themeMode: 'system',
    languageCode: 'en',
  );
}

class _Logger extends AppLogger {
  final warnings = <String>[];
  @override
  void warn(String message) => warnings.add(message);
}

class _Cleanup extends RuntimeCleanup {
  _Cleanup(super.ref);
  final gate = Completer<void>();
  int calls = 0;
  bool? cleanupFiles;
  bool fail = false;

  @override
  Future<void> cleanupNetworking({
    bool cancelTransfers = true,
    bool cleanupSelectedFiles = false,
  }) async {
    calls++;
    cleanupFiles = cleanupSelectedFiles;
    await gate.future;
    if (fail) throw StateError('unexpected cleanup coordinator failure');
  }
}

class _ExitBinding extends AutomatedTestWidgetsFlutterBinding {
  Future<AppExitResponse> Function(AppExitType, int)? exitHandler;

  @override
  Future<AppExitResponse> exitApplication(
    AppExitType exitType, [
    int exitCode = 0,
  ]) =>
      exitHandler?.call(exitType, exitCode) ??
      super.exitApplication(exitType, exitCode);
}

void main() {
  final binding = _ExitBinding();
  late _Cleanup cleanup;
  late _Logger logger;
  const windowChannel = MethodChannel('window_manager');

  Future<void> emitLinuxClose(WidgetTester tester) async {
    // Simulate the plugin's close event at its public listener boundary. The
    // widget-test binding deliberately prevents an actual OS application exit.
    for (final listener in windowManager.listeners) {
      listener.onWindowClose();
    }
    await tester.pump();
  }

  tearDown(() {
    binding.exitHandler = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
  });

  Future<void> mount(WidgetTester tester) async {
    logger = _Logger();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          networkProvider.overrideWith(
            (_) async => const NetworkSnapshot(ip: '192.168.1.20'),
          ),
          loggerProvider.overrideWithValue(logger),
          runtimeCleanupProvider.overrideWith((ref) => cleanup = _Cleanup(ref)),
        ],
        child: const BShareApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('window exit waits for networking and capture cleanup', (
    tester,
  ) async {
    await mount(tester);
    var exited = false;
    final exit = tester.binding.handleRequestAppExit().then((response) {
      exited = true;
      return response;
    });
    await tester.pump();
    expect(cleanup.calls, 1);
    expect(cleanup.cleanupFiles, isTrue);
    expect(exited, isFalse);
    cleanup.gate.complete();
    expect(await exit, AppExitResponse.exit);
    expect(exited, isTrue);
    expect(logger.warnings, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Linux native close waits through standard Flutter exit once', (
    tester,
  ) async {
    final windowCalls = <MethodCall>[];
    final exitRequests = <({AppExitType type, int code})>[];
    var nativeExitCompleted = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      windowChannel,
      (call) async {
        windowCalls.add(call);
        return null;
      },
    );
    binding.exitHandler = (type, code) async {
      exitRequests.add((type: type, code: code));
      final result = await tester.binding.handleRequestAppExit();
      nativeExitCompleted = result == AppExitResponse.exit;
      return result;
    };
    await mount(tester);
    expect(windowCalls.map((call) => call.method), [
      'ensureInitialized',
      'setPreventClose',
    ]);
    expect(windowCalls.last.arguments, {'isPreventClose': true});
    await emitLinuxClose(tester);
    await emitLinuxClose(tester);
    expect(exitRequests, hasLength(1));
    expect(exitRequests.single, (type: AppExitType.cancelable, code: 0));
    expect(cleanup.calls, 1);
    expect(nativeExitCompleted, isFalse);
    cleanup.gate.complete();
    await tester.pump();
    expect(nativeExitCompleted, isTrue);
    expect(logger.warnings, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await emitLinuxClose(tester);
    expect(exitRequests, hasLength(1));
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('Linux canceled native close can be requested again', (
    tester,
  ) async {
    var requests = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      windowChannel,
      (_) async => null,
    );
    binding.exitHandler = (type, code) async {
      expect(type, AppExitType.cancelable);
      requests++;
      if (requests == 1) return AppExitResponse.cancel;
      return tester.binding.handleRequestAppExit();
    };
    await mount(tester);
    await emitLinuxClose(tester);
    expect(requests, 1);
    await emitLinuxClose(tester);
    expect(requests, 2);
    expect(cleanup.calls, 1);
    cleanup.gate.complete();
    await tester.pump();
    expect(logger.warnings, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('repeated exit and detached notifications share one cleanup', (
    tester,
  ) async {
    await mount(tester);
    final first = tester.binding.handleRequestAppExit();
    final second = tester.binding.handleRequestAppExit();
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    await tester.pump();
    expect(cleanup.calls, 1);
    cleanup.gate.complete();
    expect(await first, AppExitResponse.exit);
    expect(await second, AppExitResponse.exit);
    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    await tester.pump();
    expect(cleanup.calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('detached fallback waits once and contains unexpected errors', (
    tester,
  ) async {
    await mount(tester);
    // Read the fake before the first lifecycle notification creates it.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(BShareApp)),
    );
    container.read(runtimeCleanupProvider);
    cleanup.fail = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    await tester.pump();
    expect(cleanup.calls, 1);
    cleanup.gate.complete();
    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);
    await tester.pump();
    expect(cleanup.calls, 1);
    expect(
      logger.warnings.single,
      contains('Could not finish application cleanup'),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}
