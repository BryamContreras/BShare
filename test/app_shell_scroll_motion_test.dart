import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  Future<ScrollController> mount(
    WidgetTester tester, {
    required bool disableAnimations,
  }) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    final controller = ScrollController();
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => AppShell(
            title: 'Scroll test',
            scrollController: controller,
            child: ListView.builder(
              controller: controller,
              itemExtent: 64,
              itemCount: 80,
              itemBuilder: (_, index) => Text('Item $index'),
            ),
          ),
        ),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      controller.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp.router(
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
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: disableAnimations),
          child: child!,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Volver arriba'), findsNothing);
    controller.jumpTo(640);
    await tester.pump();
    expect(find.byTooltip('Volver arriba'), findsOneWidget);
    return controller;
  }

  testWidgets('reduced motion returns to top immediately without assertions', (
    tester,
  ) async {
    final controller = await mount(tester, disableAnimations: true);
    await tester.tap(find.byTooltip('Volver arriba'));

    // No animation frame or duration is needed to change the scroll position.
    expect(controller.offset, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Volver arriba'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('normal motion returns to top with the brief 220 ms animation', (
    tester,
  ) async {
    final controller = await mount(tester, disableAnimations: false);
    await tester.tap(find.byTooltip('Volver arriba'));
    expect(controller.offset, 640);

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    expect(controller.offset, greaterThan(0));
    expect(controller.offset, lessThan(640));
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(milliseconds: 110));
    expect(controller.offset, closeTo(0, 0.01));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Volver arriba'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
