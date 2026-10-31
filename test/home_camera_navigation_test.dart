import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/app_settings.dart';
import 'package:bshare/src/infrastructure/services/network_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/screens/home_screen.dart';
import 'package:bshare/src/presentation/widgets/action_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _Settings extends SettingsController {
  @override
  Future<AppSettings> build() async => const AppSettings(
    deviceId: 'phone',
    deviceName: 'My phone',
    downloadDirectory: '/tmp',
    autoAccept: false,
    preferredPort: 53317,
    themeMode: 'system',
    languageCode: 'es',
  );
}

void main() {
  testWidgets('mobile Home names screen sharing and opens Device camera', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
        GoRoute(
          path: '/camera',
          builder: (_, _) => const Scaffold(body: Text('camera-page')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          networkProvider.overrideWith(
            (_) async => const NetworkSnapshot(ip: '192.168.1.20'),
          ),
        ],
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
    expect(find.text('Compartir pantalla'), findsOneWidget);
    expect(find.text('Cámara del dispositivo'), findsOneWidget);
    expect(find.text('Pantalla'), findsNothing);
    expect(
      tester
          .widgetList<ActionCard>(find.byType(ActionCard))
          .every((card) => card.compactTypography),
      isTrue,
    );
    expect(
      tester.widget<Text>(find.text('Cámara del dispositivo')).style?.fontSize,
      20,
    );
    await tester.tap(find.text('Cámara del dispositivo'));
    await tester.pumpAndSettle();
    expect(find.text('camera-page'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final (platform, locale, title, subtitle) in [
    (
      TargetPlatform.windows,
      const Locale('en'),
      'View device camera',
      'View another device’s camera on this computer.',
    ),
    (
      TargetPlatform.linux,
      const Locale('es'),
      'Ver cámara del dispositivo',
      'Ve la cámara de otro dispositivo en esta computadora.',
    ),
    (
      TargetPlatform.macOS,
      const Locale('es'),
      'Ver cámara del dispositivo',
      'Ve la cámara de otro dispositivo en esta computadora.',
    ),
  ]) {
    testWidgets(
      'desktop Home offers viewing the remote camera on ${platform.name}',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final router = GoRouter(
          routes: [
            GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
            GoRoute(
              path: '/camera',
              builder: (_, _) => const Scaffold(body: Text('camera-page')),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsProvider.overrideWith(_Settings.new),
              networkProvider.overrideWith(
                (_) async => const NetworkSnapshot(ip: '192.168.1.20'),
              ),
            ],
            child: MaterialApp.router(
              routerConfig: router,
              theme: ThemeData(platform: platform),
              locale: locale,
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
        final cameraCard = tester
            .widgetList<ActionCard>(find.byType(ActionCard))
            .singleWhere((card) => card.title == title);
        expect(cameraCard.subtitle, subtitle);
        expect(cameraCard.compactTypography, isFalse);
        expect(
          find.text('Share your device camera with a computer.'),
          findsNothing,
        );
        expect(
          find.text('Comparte la cámara del dispositivo con una computadora.'),
          findsNothing,
        );
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
        expect(find.text('camera-page'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
