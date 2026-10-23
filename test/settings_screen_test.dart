import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/camera_device.dart';
import 'package:bshare/src/infrastructure/repositories/settings_repository.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('capture choices preserve edited device name and port drafts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({
      'deviceId': 'test',
      'deviceName': 'Original',
      'downloadDirectory': '/tmp',
      'autoAcceptDefaultMigrated': true,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);
    final router = GoRouter(
      initialLocation: '/settings',
      routes: [
        GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: ThemeData(platform: TargetPlatform.android),
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
    await tester.enterText(find.byType(TextField).first, 'My edited name');
    await tester.enterText(find.byType(TextField).at(1), '54321');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final nameController = tester
        .widget<TextField>(find.byType(TextField).first)
        .controller!;
    final portController = tester
        .widget<TextField>(find.byType(TextField).at(1))
        .controller!;
    final resolution = find.byKey(const ValueKey('screen-resolution'));
    await tester.scrollUntilVisible(
      resolution,
      160,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(resolution);
    await tester.pumpAndSettle();
    await tester.tap(find.text('720p').last);
    await tester.pumpAndSettle();
    final cadence = find.byKey(const ValueKey('screen-frame-rate'));
    await tester.scrollUntilVisible(
      cadence,
      160,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(cadence);
    await tester.pumpAndSettle();
    await tester.tap(find.text('60 FPS').last);
    await tester.pumpAndSettle();
    expect(nameController.text, 'My edited name');
    expect(portController.text, '54321');
    expect(container.read(settingsProvider).value!.deviceName, 'Original');
    expect(container.read(settingsProvider).value!.preferredPort, 53317);
    expect(
      container.read(settingsProvider).value!.screenCapture.resolution,
      720,
    );
    expect(container.read(settingsProvider).value!.screenCapture.frameRate, 60);
    final save = find.widgetWithText(FilledButton, 'Save settings');
    await tester.scrollUntilVisible(
      save,
      250,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    ScaffoldMessenger.of(tester.element(save)).hideCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(
      container.read(settingsProvider).value!.deviceName,
      'My edited name',
    );
    expect(container.read(settingsProvider).value!.preferredPort, 54321);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      '$platform edits only rear and front profiles without camera detection',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({
          'deviceId': 'test',
          'deviceName': 'Original',
          'downloadDirectory': '/tmp',
          'autoAcceptDefaultMigrated': true,
          'cameraCaptureSettings':
              '{"front":{"resolution":1080,"frameRate":30},'
              '"back":{"resolution":1080,"frameRate":30},'
              '"devices":{"rear-wide":{"resolution":1440,"frameRate":24}}}',
        });
        var detections = 0;
        final container = ProviderContainer(
          overrides: [
            cameraDevicesProvider.overrideWith((ref) async {
              detections++;
              return const [
                CameraDevice(
                  id: 'rear-wide',
                  label: 'Rear wide',
                  frontFacing: false,
                ),
              ];
            }),
          ],
        );
        addTearDown(container.dispose);
        await container.read(settingsProvider.future);
        final router = GoRouter(
          initialLocation: '/settings',
          routes: [
            GoRoute(
              path: '/settings',
              builder: (_, _) => const SettingsScreen(),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              routerConfig: router,
              theme: ThemeData(platform: platform),
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
        expect(detections, 0);

        Future<void> tapKey(String key) async {
          final finder = find.byKey(ValueKey(key));
          await tester.scrollUntilVisible(
            finder,
            250,
            scrollable: find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.pumpAndSettle();
          await tester.tap(finder);
          await tester.pumpAndSettle();
        }

        Future<void> choose(String key, String label) async {
          await tapKey(key);
          if (key.endsWith('frame-rate')) {
            final dropdown = tester.widget<DropdownButton<dynamic>>(
              find.descendant(
                of: find.byKey(ValueKey(key)),
                matching: find.byWidgetPredicate(
                  (widget) => widget is DropdownButton<dynamic>,
                ),
              ),
            );
            expect(
              dropdown.items!.map((item) => item.value as int),
              everyElement(inInclusiveRange(1, 60)),
            );
          }
          await tester.tap(find.text(label).last);
          await tester.pumpAndSettle();
        }

        await tapKey('camera-profile-back');
        await choose('camera-back-resolution', '720p');
        await choose('camera-back-frame-rate', '15 FPS');
        await tapKey('camera-profile-front');
        await choose('camera-front-resolution', '480p');
        await choose('camera-front-frame-rate', '60 FPS');
        expect(detections, 0);
        final settings = container.read(settingsProvider).value!;
        expect(settings.cameraCapture.back.resolution, 720);
        expect(settings.cameraCapture.back.frameRate, 15);
        expect(settings.cameraCapture.front.resolution, 480);
        expect(settings.cameraCapture.front.frameRate, 60);
        expect(settings.screenCapture.resolution, 1080);
        expect(settings.screenCapture.frameRate, 30);

        expect(find.byKey(const ValueKey('detect-cameras')), findsNothing);
        expect(
          find.byKey(const ValueKey('camera-device-rear-wide')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('reset-camera-overrides')),
          findsNothing,
        );
        // Old overrides are retained for safe settings round trips, but cannot
        // silently override the two profiles used for capture.
        expect(settings.cameraCapture.devices['rear-wide']!.resolution, 1440);
        expect(settings.cameraCapture.devices['rear-wide']!.frameRate, 24);
        final persisted = await SettingsRepository(
          await SharedPreferences.getInstance(),
        ).load();
        expect(persisted.cameraCapture.front.resolution, 480);
        expect(persisted.cameraCapture.front.frameRate, 60);
        expect(persisted.cameraCapture.back.resolution, 720);
        expect(persisted.cameraCapture.back.frameRate, 15);
        expect(persisted.cameraCapture.devices['rear-wide']!.frameRate, 24);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final scenario in [
    (
      name: '320 dp portrait with double text',
      size: const Size(320, 700),
      pixelRatio: 1.0,
      textScale: 2.0,
      density: VisualDensity.standard,
    ),
    (
      name: '320 dp portrait with triple text and compact density',
      size: const Size(320, 700),
      pixelRatio: 3.0,
      textScale: 3.0,
      density: VisualDensity.compact,
    ),
    (
      name: 'phone landscape with double text',
      size: const Size(700, 360),
      pixelRatio: 2.0,
      textScale: 2.0,
      density: VisualDensity.comfortable,
    ),
    (
      name: 'tablet landscape with double text',
      size: const Size(1024, 800),
      pixelRatio: 1.5,
      textScale: 2.0,
      density: VisualDensity.compact,
    ),
    (
      name: 'tablet portrait with triple text',
      size: const Size(800, 1280),
      pixelRatio: 2.0,
      textScale: 3.0,
      density: VisualDensity.standard,
    ),
  ]) {
    testWidgets('settings choices remain readable at ${scenario.name}', (
      tester,
    ) async {
      tester.view.physicalSize = scenario.size * scenario.pixelRatio;
      tester.view.devicePixelRatio = scenario.pixelRatio;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({
        'deviceId': 'test',
        'deviceName': 'Original',
        'downloadDirectory': '/tmp',
        'autoAcceptDefaultMigrated': true,
        'languageCode': 'es',
        'screenResolution': 0,
        'screenFrameRate': 60,
        'cameraCaptureSettings':
            '{"front":{"resolution":0,"frameRate":60},'
            '"back":{"resolution":0,"frameRate":60}}',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(settingsProvider.future);
      final router = GoRouter(
        initialLocation: '/settings',
        routes: [
          GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            locale: const Locale('es'),
            theme: ThemeData(
              platform: TargetPlatform.android,
              visualDensity: scenario.density,
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scenario.textScale)),
              child: child!,
            ),
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

      Future<void> showField(String key) async {
        await tester.scrollUntilVisible(
          find.byKey(ValueKey(key)),
          120,
          maxScrolls: 100,
          scrollable: find
              .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
      }

      Future<void> checkDropdown(String key, String label) async {
        await showField(key);
        final field = find.byKey(ValueKey(key));
        final dropdown = tester.widget<DropdownButton<dynamic>>(
          find.descendant(
            of: field,
            matching: find.byWidgetPredicate(
              (widget) => widget is DropdownButton<dynamic>,
            ),
          ),
        );
        expect(dropdown.isExpanded, isTrue);
        expect(dropdown.itemHeight, isNull);
        final selected = find
            .descendant(
              of: field,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Text &&
                    widget.data == label &&
                    widget.maxLines == 1 &&
                    widget.overflow == TextOverflow.ellipsis,
              ),
            )
            .hitTestable();
        expect(selected, findsOneWidget);
        final fieldRect = tester.getRect(field);
        final selectedRect = tester.getRect(selected);
        expect(selectedRect.left, greaterThanOrEqualTo(fieldRect.left));
        expect(selectedRect.right, lessThanOrEqualTo(fieldRect.right));
        expect(selectedRect.height, lessThanOrEqualTo(fieldRect.height));

        await tester.tap(field);
        await tester.pumpAndSettle();
        final fullLabel = find.byWidgetPredicate(
          (widget) =>
              widget is Text && widget.data == label && widget.maxLines == null,
        );
        await tester.scrollUntilVisible(
          fullLabel,
          80,
          maxScrolls: 30,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pumpAndSettle();
        expect(fullLabel.hitTestable(), findsOneWidget);
        final paragraph = tester.renderObject<RenderParagraph>(fullLabel);
        expect(paragraph.didExceedMaxLines, isFalse);
        if (scenario.size.width == 320 && label == 'Resolución original') {
          expect(
            paragraph.getBoxesForSelection(
              TextSelection(baseOffset: 0, extentOffset: label.length),
            ),
            hasLength(greaterThan(1)),
            reason: 'The complete original-resolution label wraps in the menu.',
          );
        }
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      await checkDropdown('settings-theme', 'Sistema');
      await checkDropdown('settings-language', 'Español');
      await checkDropdown('screen-resolution', 'Resolución original');
      await checkDropdown('screen-frame-rate', '60 FPS');
      for (final camera in ['back', 'front']) {
        await showField('camera-profile-$camera');
        await tester.tap(find.byKey(ValueKey('camera-profile-$camera')));
        await tester.pumpAndSettle();
        await checkDropdown('camera-$camera-resolution', 'Resolución original');
        await checkDropdown('camera-$camera-frame-rate', '60 FPS');
      }
      final settings = container.read(settingsProvider).value!;
      expect(settings.screenCapture.resolution, 0);
      expect(settings.screenCapture.frameRate, 60);
      expect(settings.cameraCapture.front.resolution, 0);
      expect(settings.cameraCapture.front.frameRate, 60);
      expect(settings.cameraCapture.back.resolution, 0);
      expect(settings.cameraCapture.back.frameRate, 60);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }
}
