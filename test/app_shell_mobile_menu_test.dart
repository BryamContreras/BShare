import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  Future<void> mount(WidgetTester tester, TargetPlatform platform) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const AppShell(child: Text('Content')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        theme: ThemeData(platform: platform),
        locale: const Locale('es'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform menu hides Screen and preserves Transferencias', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester, platform);
      final destinations = tester.widgetList<NavigationDestination>(
        find.byType(NavigationDestination),
      );
      expect(destinations.map((item) => item.label), [
        'Inicio',
        'Enviar',
        'Recibir',
        'Transferencias',
      ]);
      expect(find.text('Actividad'), findsNothing);
      expect(find.text('Pantalla'), findsNothing);
      expect(find.byTooltip('Ajustes'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('desktop-navigation-brand')),
        findsNothing,
      );
      final appTitle = find.byKey(const ValueKey('app-bar-title'));
      expect(
        find.descendant(of: appTitle, matching: find.text('BShare')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: appTitle, matching: find.byType(Image)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final platform in [
    TargetPlatform.linux,
    TargetPlatform.windows,
    TargetPlatform.macOS,
  ]) {
    testWidgets('$platform sidebar exposes screen and device camera viewing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester, platform);
      expect(find.byType(NavigationBar), findsNothing);
      final navigation = find.byKey(const ValueKey('desktop-navigation'));
      for (final label in [
        'Compartir pantalla',
        'Cámara del dispositivo',
        'Transferencias',
        'Ajustes',
      ]) {
        expect(
          find.descendant(of: navigation, matching: find.text(label)),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}
