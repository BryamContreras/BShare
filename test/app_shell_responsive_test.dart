import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  Future<GoRouter> mount(
    WidgetTester tester, {
    required Size size,
    required TargetPlatform platform,
    required double textScale,
    Widget? content,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    final router = GoRouter(
      routes: [
        for (final path in [
          '/',
          '/send',
          '/receive',
          '/transfers',
          '/screen',
          '/camera',
          '/settings',
        ])
          GoRoute(
            path: path,
            builder: (_, _) => AppShell(
              title: path == '/' ? 'BShare' : 'Page $path',
              child: content ?? Center(child: Text('page:$path')),
            ),
          ),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
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
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.linux]) {
    for (final width in [900.0, 1200.0]) {
      for (final textScale in [2.0, 3.0]) {
        testWidgets(
          '$platform sidebar at ${width}x320 and ${textScale}x text scrolls '
          'without clipping Spanish labels and opens Transfers',
          (tester) async {
            final router = await mount(
              tester,
              size: Size(width, 320),
              platform: platform,
              textScale: textScale,
            );

            expect(find.byType(NavigationBar), findsNothing);
            expect(find.text('Actividad'), findsNothing);
            expect(
              find.text('Compartir pantalla'),
              platform == TargetPlatform.android
                  ? findsNothing
                  : findsOneWidget,
            );
            final navigation = find.byType(SingleChildScrollView);
            expect(navigation, findsOneWidget);
            expect(
              find.byKey(const ValueKey('desktop-navigation-brand')),
              platform == TargetPlatform.android
                  ? findsNothing
                  : findsOneWidget,
            );
            final scrollable = tester.state<ScrollableState>(
              find.descendant(
                of: navigation,
                matching: find.byType(Scrollable),
              ),
            );
            expect(scrollable.position.maxScrollExtent, greaterThan(0));
            expect(tester.takeException(), isNull);

            final transfers = find.text('Transferencias');
            final button = find.ancestor(
              of: transfers,
              matching: find.byType(InkWell),
            );
            final text = tester.renderObject<RenderParagraph>(transfers);
            final textBoxes = text.getBoxesForSelection(
              const TextSelection(baseOffset: 0, extentOffset: 14),
            );
            expect(text.didExceedMaxLines, isFalse);
            expect(textBoxes.length, greaterThan(1));
            expect(
              textBoxes
                  .map((box) => box.bottom)
                  .reduce((left, right) => left > right ? left : right),
              lessThanOrEqualTo(text.size.height + 0.01),
            );
            expect(tester.getSize(button).height, greaterThan(54));
            for (final element
                in find
                    .descendant(of: navigation, matching: find.byType(InkWell))
                    .evaluate()) {
              final size = tester.getSize(
                find.byElementPredicate(
                  (candidate) => identical(candidate, element),
                ),
              );
              expect(size.width, greaterThanOrEqualTo(48));
              expect(size.height, greaterThanOrEqualTo(48));
            }

            await tester.ensureVisible(button);
            await tester.pumpAndSettle();
            expect(button.hitTestable(), findsOneWidget);
            await tester.tap(button);
            await tester.pumpAndSettle();
            expect(
              router.routeInformationProvider.value.uri.path,
              '/transfers',
            );
            expect(find.text('page:/transfers'), findsOneWidget);
            expect(tester.takeException(), isNull);

            // The final desktop entries remain reachable in a short window.
            if (platform == TargetPlatform.linux) {
              final camera = find.ancestor(
                of: find.text('Cámara del dispositivo'),
                matching: find.byType(InkWell),
              );
              await tester.ensureVisible(camera);
              await tester.pumpAndSettle();
              expect(camera.hitTestable(), findsOneWidget);
              await tester.tap(camera);
              await tester.pumpAndSettle();
              expect(router.routeInformationProvider.value.uri.path, '/camera');
              expect(tester.takeException(), isNull);

              final settings = find.ancestor(
                of: find.text('Ajustes'),
                matching: find.byType(InkWell),
              );
              await tester.ensureVisible(settings);
              await tester.pumpAndSettle();
              expect(settings.hitTestable(), findsOneWidget);
              await tester.tap(settings);
              await tester.pumpAndSettle();
              expect(
                router.routeInformationProvider.value.uri.path,
                '/settings',
              );
              expect(tester.takeException(), isNull);
            }
          },
        );
      }
    }
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform phone keeps its mobile bottom destinations', (
      tester,
    ) async {
      await mount(
        tester,
        size: const Size(390, 700),
        platform: platform,
        textScale: 2,
      );
      expect(find.byType(SingleChildScrollView), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
      final destinations = tester.widgetList<NavigationDestination>(
        find.byType(NavigationDestination),
      );
      expect(destinations.map((destination) => destination.label), [
        'Inicio',
        'Enviar',
        'Recibir',
        'Transferencias',
      ]);
      expect(find.text('Pantalla'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('unscaled sidebar keeps navigation targets at least 54 high', (
    tester,
  ) async {
    await mount(
      tester,
      size: const Size(1000, 700),
      platform: TargetPlatform.linux,
      textScale: 1,
    );
    final navigation = find.byType(SingleChildScrollView);
    // The sidebar fills the window, with 16 dp inner padding at each end.
    expect(tester.getRect(navigation).top, 16);
    expect(tester.getSize(navigation).height, 668);
    final brand = find.byKey(const ValueKey('desktop-navigation-brand'));
    expect(tester.getRect(brand).top, 16);
    expect(tester.getRect(brand).height, lessThan(80));
    final home = find.descendant(of: navigation, matching: find.text('Inicio'));
    expect(
      tester.getTopLeft(home).dy,
      greaterThan(tester.getRect(brand).bottom),
    );
    expect(
      tester.getTopLeft(home).dy,
      lessThan(tester.getRect(brand).bottom + 60),
    );
    for (final element
        in find
            .descendant(of: navigation, matching: find.byType(InkWell))
            .evaluate()) {
      final size = tester.getSize(
        find.byElementPredicate((candidate) => identical(candidate, element)),
      );
      expect(size.height, greaterThanOrEqualTo(54));
      expect(size.width, greaterThanOrEqualTo(48));
    }
    expect(tester.takeException(), isNull);
  });

  for (final platform in [
    TargetPlatform.linux,
    TargetPlatform.windows,
    TargetPlatform.macOS,
  ]) {
    testWidgets('$platform preserves content state and scroll across 900 dp', (
      tester,
    ) async {
      await mount(
        tester,
        size: const Size(1280, 700),
        platform: platform,
        textScale: 1,
        content: const _RetainedScrollContent(),
      );
      final content = find.byType(_RetainedScrollContent);
      final originalState = tester.state<_RetainedScrollContentState>(content);
      await tester.tap(find.text('State changes: 0'));
      await tester.pumpAndSettle();
      originalState.scrollController.jumpTo(700);
      await tester.pumpAndSettle();
      expect(originalState.scrollController.offset, 700);

      for (final width in [800.0, 1280.0]) {
        tester.view.physicalSize = Size(width, 700);
        await tester.pumpAndSettle();
        expect(
          tester.state<_RetainedScrollContentState>(content),
          same(originalState),
        );
        expect(originalState.mounted, isTrue);
        expect(find.text('State changes: 1'), findsOneWidget);
        expect(originalState.scrollController.offset, closeTo(700, 0.01));
        expect(
          tester
              .getSize(find.byKey(const ValueKey('desktop-navigation')))
              .width,
          width < 900 ? 80 : 280,
        );
        expect(
          find.byKey(const ValueKey('desktop-navigation-brand')),
          findsOneWidget,
        );
        expect(find.text('BShare'), findsOneWidget);
        expect(find.byType(NavigationBar), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('app-bar-title')),
            matching: find.byType(Image),
          ),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      }
    });

    for (final width in [800.0, 900.0, 1200.0]) {
      testWidgets('$platform keeps branding only in its full height sidebar at '
          '${width}x320 and triple text', (tester) async {
        final router = await mount(
          tester,
          size: Size(width, 320),
          platform: platform,
          textScale: 3,
        );
        final side = find.byKey(const ValueKey('desktop-navigation'));
        final brand = find.byKey(const ValueKey('desktop-navigation-brand'));
        final appTitle = find.byKey(const ValueKey('app-bar-title'));
        expect(tester.getSize(side), Size(width < 900 ? 80 : 280, 320));
        expect(tester.getRect(side).top, 0);
        expect(tester.getRect(brand).top, 16);
        expect(find.byType(NavigationBar), findsNothing);
        expect(find.text('BShare'), findsOneWidget);
        expect(
          find.descendant(of: brand, matching: find.text('BShare')),
          findsOneWidget,
        );
        final logo = find.byWidgetPredicate(
          (widget) =>
              widget is Image &&
              widget.image is AssetImage &&
              (widget.image as AssetImage).assetName ==
                  'assets/brand/app_icon.png',
        );
        expect(logo, findsOneWidget);
        expect(find.descendant(of: brand, matching: logo), findsOneWidget);
        expect(find.descendant(of: appTitle, matching: logo), findsNothing);
        expect(
          find.descendant(of: appTitle, matching: find.text('Inicio')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);

        // Compact desktop navigation retains named destinations via tooltips.
        final settings = width < 900
            ? find.byTooltip('Ajustes')
            : find.ancestor(
                of: find.text('Ajustes'),
                matching: find.byType(InkWell),
              );
        await tester.ensureVisible(settings);
        await tester.pumpAndSettle();
        await tester.tap(settings);
        await tester.pumpAndSettle();
        expect(router.routeInformationProvider.value.uri.path, '/settings');
        expect(find.text('BShare'), findsOneWidget);
        expect(find.text('Page /settings'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}

class _RetainedScrollContent extends StatefulWidget {
  const _RetainedScrollContent();

  @override
  State<_RetainedScrollContent> createState() => _RetainedScrollContentState();
}

class _RetainedScrollContentState extends State<_RetainedScrollContent> {
  final scrollController = ScrollController();
  var changes = 0;

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextButton(
        onPressed: () => setState(() => changes++),
        child: Text('State changes: $changes'),
      ),
      Expanded(
        child: ListView.builder(
          controller: scrollController,
          itemCount: 100,
          itemExtent: 56,
          itemBuilder: (_, index) => Text('Scrollable row $index'),
        ),
      ),
    ],
  );
}
