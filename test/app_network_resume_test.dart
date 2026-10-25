import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/app_settings.dart';
import 'package:bshare/src/infrastructure/services/network_service.dart';
import 'package:bshare/src/presentation/app.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Settings extends SettingsController {
  @override
  Future<AppSettings> build() async => const AppSettings(
    deviceId: 'phone',
    deviceName: 'My phone',
    downloadDirectory: '/tmp',
    autoAccept: false,
    preferredPort: 53317,
    themeMode: 'system',
    languageCode: 'en',
  );
}

class _Cleanup extends RuntimeCleanup {
  _Cleanup(super.ref);

  final gate = Completer<void>();

  @override
  Future<void> cleanupNetworking({
    bool cancelTransfers = true,
    bool cleanupSelectedFiles = false,
  }) => gate.future;
}

void main() {
  late ProviderContainer container;
  late _Cleanup cleanup;
  var ip = '192.168.1.5';
  var networkReads = 0;

  Future<void> mount(WidgetTester tester) async {
    ip = '192.168.1.5';
    networkReads = 0;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        networkProvider.overrideWith((_) async {
          networkReads++;
          return NetworkSnapshot(ip: ip);
        }),
        runtimeCleanupProvider.overrideWith((ref) => cleanup = _Cleanup(ref)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const BShareApp()),
    );
    await tester.pumpAndSettle();
    expect(networkReads, 1);
    expect(find.text('192.168.1.5'), findsOneWidget);
    expect((await container.read(networkProvider.future)).ip, '192.168.1.5');
  }

  for (final backgroundStates in [
    [AppLifecycleState.hidden],
    [AppLifecycleState.paused],
    [AppLifecycleState.hidden, AppLifecycleState.paused],
  ]) {
    testWidgets('Home reloads IP once after $backgroundStates and resume', (
      tester,
    ) async {
      await mount(tester);
      ip = '192.168.1.4';
      for (final state in backgroundStates) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      expect(networkReads, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(networkReads, 2);
      expect(find.text('192.168.1.5'), findsNothing);
      expect(find.text('192.168.1.4'), findsOneWidget);
      expect((await container.read(networkProvider.future)).ip, '192.168.1.4');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(networkReads, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('startup resume and inactive dialogs keep the cached IP', (
    tester,
  ) async {
    await mount(tester);
    ip = '192.168.1.4';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(networkReads, 1);
    expect(find.text('192.168.1.5'), findsOneWidget);
    expect((await container.read(networkProvider.future)).ip, '192.168.1.5');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('disposed app does not invalidate the snapshot on resume', (
    tester,
  ) async {
    await mount(tester);
    ip = '192.168.1.4';
    await tester.pumpWidget(const SizedBox.shrink());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(networkReads, 1);
    expect((await container.read(networkProvider.future)).ip, '192.168.1.5');
    expect(tester.takeException(), isNull);
  });

  testWidgets('exit cleanup prevents refresh while pending and after it ends', (
    tester,
  ) async {
    await mount(tester);
    ip = '192.168.1.4';
    final exit = tester.binding.handleRequestAppExit();
    await tester.pump();
    for (var attempt = 0; attempt < 2; attempt++) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(networkReads, 1);
      expect(find.text('192.168.1.5'), findsOneWidget);
      if (attempt == 0) {
        cleanup.gate.complete();
        expect(await exit, AppExitResponse.exit);
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
