import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/infrastructure/services/android_screen_share_execution_service.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/screens/screen_share_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _Discovery extends DiscoveryController {
  @override
  List<DeviceInfo> build() => [
    DeviceInfo(
      id: 'device',
      name: 'Mi teléfono',
      platform: 'Android',
      ip: '192.168.1.20',
      port: 53317,
      lastSeen: DateTime(2026),
    ),
  ];

  @override
  Future<void> start({bool advertise = false, String? ipOverride}) async {}
}

void main() {
  testWidgets('Share and Watch follow device selection at the end', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = ScreenShareService(
      const AppLogger(),
      AndroidScreenShareExecutionService(),
    );
    addTearDown(service.dispose);
    final container = ProviderContainer(
      overrides: [
        screenShareServiceProvider.overrideWithValue(service),
        discoveryProvider.overrideWith(_Discovery.new),
      ],
    );
    addTearDown(container.dispose);
    container
        .read(discoveryStatusProvider.notifier)
        .set(const DiscoveryStatus(phase: DiscoveryPhase.listening));
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const ScreenShareScreen()),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: ThemeData(platform: TargetPlatform.android),
          locale: const Locale('es'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final share = find.widgetWithText(FilledButton, 'Compartir pantalla');
    final watch = find.widgetWithText(OutlinedButton, 'Ver');
    expect(
      tester.getTopLeft(share).dy,
      greaterThan(tester.getBottomLeft(find.text('Mi teléfono')).dy),
    );
    expect(
      tester.getTopLeft(watch).dy,
      greaterThan(tester.getTopLeft(share).dy),
    );
    expect(tester.widget<OutlinedButton>(watch).onPressed, isNull);
    await tester.tap(find.text('Mi teléfono'));
    await tester.pumpAndSettle();
    expect(tester.widget<OutlinedButton>(watch).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
