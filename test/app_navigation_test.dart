import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/navigation/app_navigation.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  late GoRouter router;
  late AppNavigation navigation;

  Future<void> mount(WidgetTester tester, {String initial = '/'}) async {
    router = GoRouter(
      initialLocation: initial,
      routes: [
        for (final path in [
          '/',
          '/send',
          '/receive',
          '/settings',
          '/screen',
          '/send/media',
        ])
          GoRoute(
            path: path,
            builder: (context, _) => AppShell(
              title: path,
              backPath: path == '/send/media' ? '/send' : null,
              child: Column(
                children: [
                  Text('page:$path'),
                  if (path == '/send/media')
                    TextButton(
                      onPressed: () =>
                          AppNavigationScope.back(context, fallback: '/send'),
                      child: const Text('Complete selection'),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
    navigation = AppNavigation(router);
    addTearDown(() {
      navigation.dispose();
      router.dispose();
    });
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (_, child) =>
            AppNavigationScope(navigation: navigation, child: child!),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> go(WidgetTester tester, String path) async {
    router.go(path);
    await tester.pumpAndSettle();
  }

  testWidgets('app and system Back return through the visited tabs', (
    tester,
  ) async {
    await mount(tester);
    await go(tester, '/send');
    await go(tester, '/receive');
    await go(tester, '/settings');
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('page:/receive'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('page:/send'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('page:/'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('page:/'), findsOneWidget);
    expect(navigation.canGoBack, isFalse);
  });

  testWidgets(
    'settings from Screen returns to Screen; repeated tabs keep their origin',
    (tester) async {
      await mount(tester);
      await go(tester, '/screen');
      await go(tester, '/settings');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('page:/screen'), findsOneWidget);
      await go(tester, '/send');
      await go(tester, '/receive');
      await go(tester, '/send');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('page:/receive'), findsOneWidget);
      expect(find.text('page:/send'), findsNothing);
    },
  );

  testWidgets(
    'picker Back returns to Send and direct entry has a parent fallback',
    (tester) async {
      await mount(tester, initial: '/send/media');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('page:/send'), findsOneWidget);
      await go(tester, '/send/media');
      await tester.tap(find.text('Complete selection'));
      await tester.pumpAndSettle();
      expect(find.text('page:/send'), findsOneWidget);
      await go(tester, '/');
      await go(tester, '/receive');
      await go(tester, '/send');
      await go(tester, '/send/media');
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('page:/send'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('page:/receive'), findsOneWidget);
    },
  );
}
