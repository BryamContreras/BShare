import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/infrastructure/services/camera_display_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/widgets/camera_display_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('idle camera dims the whole app and a tap restores controls', (
    tester,
  ) async {
    final applied = <(bool, bool)>[];
    final display = CameraDisplayService(
      applyState: (awake, dimmed) async => applied.add((awake, dimmed)),
    );
    var actions = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cameraDisplayServiceProvider.overrideWithValue(display)],
        child: MaterialApp(
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: CameraDisplayOverlay(
            child: Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => actions++,
                  child: const Text('Visible control'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final starting = display.start();
    await tester.pump();
    await starting;
    await tester.pump(const Duration(seconds: 59));
    expect(display.dimmed.value, isFalse);
    await tester.tap(find.text('Visible control'));
    expect(actions, 1);
    await tester.pump(const Duration(seconds: 2));
    expect(display.dimmed.value, isFalse);
    await tester.pump(const Duration(seconds: 58));
    await tester.pump();
    expect(display.dimmed.value, isTrue);
    expect(find.text('Tap to show camera controls'), findsOneWidget);
    await tester.tap(find.text('Tap to show camera controls'));
    await tester.pump();
    expect(display.dimmed.value, isFalse);
    expect(actions, 1);
    await tester.tap(find.text('Visible control'));
    expect(actions, 2);
    final stopping = display.stop();
    await tester.pump();
    await stopping;
    await tester.pump(const Duration(minutes: 2));
    expect(display.dimmed.value, isFalse);
    expect(applied, [
      (true, false),
      (true, true),
      (true, false),
      (false, false),
    ]);
    await tester.pumpWidget(const SizedBox.shrink());
    final disposing = display.dispose();
    await tester.pump();
    await disposing;
  });

  const viewports = [
    (
      Size(320, 568),
      1.0,
      1.0,
      Locale('es'),
      EdgeInsets.only(top: 24, bottom: 24),
    ),
    (
      Size(360, 800),
      3.0,
      1.0,
      Locale('es'),
      EdgeInsets.only(top: 24, bottom: 24),
    ),
    (
      Size(568, 320),
      2.0,
      1.3,
      Locale('es'),
      EdgeInsets.only(left: 44, right: 24),
    ),
    (
      Size(800, 240),
      1.0,
      2.0,
      Locale('es'),
      EdgeInsets.only(top: 24, bottom: 24),
    ),
    (Size(240, 240), 1.5, 3.0, Locale('es'), EdgeInsets.all(8)),
    (Size(800, 1280), 2.0, 2.0, Locale('en'), EdgeInsets.all(24)),
    (
      Size(1280, 800),
      1.25,
      3.0,
      Locale('es'),
      EdgeInsets.only(top: 24, bottom: 24),
    ),
    (
      Size(216, 120),
      1.0,
      3.0,
      Locale('es'),
      EdgeInsets.only(top: 16, bottom: 16),
    ),
  ];

  for (final (size, density, scale, locale, padding) in viewports) {
    testWidgets('dim hint fits $size at density $density and text $scale', (
      tester,
    ) async {
      tester.view.physicalSize = size * density;
      tester.view.devicePixelRatio = density;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final display = CameraDisplayService(
        dimAfter: const Duration(milliseconds: 10),
        applyState: (_, _) async {},
      );
      var actions = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [cameraDisplayServiceProvider.overrideWithValue(display)],
          child: MaterialApp(
            locale: locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                padding: padding,
                viewPadding: padding,
              ),
              // Reproduce the fallback style outside a Scaffold. The dim layer
              // must never inherit its large monospace font or decoration.
              child: DefaultTextStyle(
                style: const TextStyle(
                  fontSize: 48,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w900,
                  decoration: TextDecoration.underline,
                ),
                child: CameraDisplayOverlay(child: child!),
              ),
            ),
            home: Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => actions++,
                  child: const Text('Visible control'),
                ),
              ),
            ),
          ),
        ),
      );
      final starting = display.start();
      await tester.pump();
      await starting;
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();

      final hint = find.byKey(const ValueKey('camera-dim-hint'));
      final rich = tester.widget<RichText>(
        find.descendant(of: hint, matching: find.byType(RichText)),
      );
      expect(rich.text.style!.fontSize, 12);
      expect(rich.text.style!.fontWeight, FontWeight.w400);
      expect(rich.text.style!.decoration, TextDecoration.none);
      expect(rich.text.style!.fontFamily, isNot('monospace'));
      expect(rich.textScaler.scale(12), closeTo(12 * scale, 0.01));
      final viewport = tester.getRect(
        find.ancestor(of: hint, matching: find.byType(SingleChildScrollView)),
      );
      expect(viewport.width, lessThanOrEqualTo(280));
      expect(viewport.left, greaterThanOrEqualTo(padding.left));
      expect(viewport.right, lessThanOrEqualTo(size.width - padding.right));
      expect(viewport.top, greaterThanOrEqualTo(padding.top));
      expect(viewport.bottom, lessThanOrEqualTo(size.height - padding.bottom));
      expect(tester.takeException(), isNull);

      // The whole display wakes, even when the label needs scrolling. The tap
      // must not activate the hidden button underneath it.
      await tester.tapAt(Offset(size.width / 2, size.height / 2));
      await tester.pump();
      expect(display.dimmed.value, isFalse);
      expect(actions, 0);
      expect(tester.takeException(), isNull);
      final stopping = display.stop();
      await tester.pump();
      await stopping;
      await tester.pumpWidget(const SizedBox.shrink());
      final disposing = display.dispose();
      await tester.pump();
      await disposing;
    });
  }

  testWidgets('dimmed semantics expose only the wake action', (tester) async {
    final semantics = tester.ensureSemantics();
    final display = CameraDisplayService(
      dimAfter: const Duration(milliseconds: 10),
      applyState: (_, _) async {},
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cameraDisplayServiceProvider.overrideWithValue(display)],
        child: MaterialApp(
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (_, child) => CameraDisplayOverlay(child: child!),
          home: Scaffold(
            body: TextButton(
              onPressed: () {},
              child: const Text('Hidden control'),
            ),
          ),
        ),
      ),
    );
    final starting = display.start();
    await tester.pump();
    await starting;
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    expect(find.semantics.byLabel('Hidden control'), findsNothing);
    final wakeAction = find.semantics.byLabel('Tap to show camera controls');
    expect(wakeAction, findsOne);
    tester.semantics.tap(wakeAction);
    await tester.pump();
    expect(display.dimmed.value, isFalse);
    expect(find.semantics.byLabel('Hidden control'), findsOne);
    semantics.dispose();
    final stopping = display.stop();
    await tester.pump();
    await stopping;
    await tester.pumpWidget(const SizedBox.shrink());
    final disposing = display.dispose();
    await tester.pump();
    await disposing;
  });
}
