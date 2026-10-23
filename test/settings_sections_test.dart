import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/camera_device.dart';
import 'package:bshare/src/infrastructure/repositories/settings_repository.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/screens/settings_screen.dart';
import 'package:bshare/src/presentation/widgets/settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.linux,
    TargetPlatform.windows,
    TargetPlatform.macOS,
  ]) {
    testWidgets('$platform groups every setting without detecting cameras', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({
        'deviceId': 'test',
        'deviceName': 'Original',
        'downloadDirectory': '/tmp',
        'autoAcceptDefaultMigrated': true,
        'cameraCaptureSettings':
            '{"front":{"resolution":720,"frameRate":60},'
            '"back":{"resolution":1440,"frameRate":24},'
            '"devices":{"rear-wide":{"resolution":480,"frameRate":15}}}',
      });
      var detections = 0;
      final container = ProviderContainer(
        overrides: [
          cameraDevicesProvider.overrideWith((ref) async {
            detections++;
            return const <CameraDevice>[];
          }),
        ],
      );
      addTearDown(container.dispose);
      await container.read(settingsProvider.future);
      final originalProfiles = container
          .read(settingsProvider)
          .value!
          .cameraCapture;
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

      final mobile =
          platform == TargetPlatform.android || platform == TargetPlatform.iOS;
      final list = tester.widget<ListView>(find.byType(ListView));
      final children =
          (list.childrenDelegate as SliverChildListDelegate).children;
      final sections = children.whereType<SettingsSection>().toList();
      expect(sections.map((section) => section.key), [
        const ValueKey('settings-section-device'),
        const ValueKey('settings-section-transfers'),
        const ValueKey('settings-section-appearance'),
        const ValueKey('settings-section-screen'),
        if (mobile) const ValueKey('settings-section-camera'),
      ]);

      final sectionFields = {
        'device': ['settings-device-name'],
        'transfers': [
          'settings-preferred-port',
          'settings-auto-accept',
          'settings-download-folder',
          'settings-clear-history',
        ],
        'appearance': ['settings-theme', 'settings-language'],
        'screen': ['screen-resolution', 'screen-frame-rate'],
        if (mobile) 'camera': ['camera-profile-back', 'camera-profile-front'],
      };
      final scrollable = find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first;
      for (final group in sectionFields.entries) {
        for (final key in group.value) {
          final field = find.byKey(ValueKey(key));
          await tester.scrollUntilVisible(
            field,
            160,
            maxScrolls: 100,
            scrollable: scrollable,
          );
          await tester.pumpAndSettle();
          final section = find.ancestor(
            of: field,
            matching: find.byType(SettingsSection),
          );
          expect(section, findsOneWidget);
          expect(
            tester.widget<SettingsSection>(section).key,
            ValueKey('settings-section-${group.key}'),
          );
          final card = tester.widget<Card>(
            find.descendant(of: section, matching: find.byType(Card)),
          );
          expect(card.margin, EdgeInsets.zero);
          expect(tester.takeException(), isNull);
        }
      }
      expect(detections, 0);
      if (!mobile) {
        expect(
          find.byKey(const ValueKey('settings-section-camera')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('camera-profile-back')), findsNothing);
        expect(
          find.byKey(const ValueKey('camera-profile-front')),
          findsNothing,
        );

        // Saving desktop choices preserves mobile-only capture profiles,
        // including historical per-device overrides.
        final resolution = find.byKey(const ValueKey('screen-resolution'));
        await tester.ensureVisible(resolution);
        await tester.pumpAndSettle();
        await tester.tap(resolution);
        await tester.pumpAndSettle();
        await tester.tap(find.text('480p').last);
        await tester.pumpAndSettle();
        final persisted = await SettingsRepository(
          await SharedPreferences.getInstance(),
        ).load();
        expect(persisted.screenCapture.resolution, 480);
        expect(persisted.cameraCapture.toJson(), originalProfiles.toJson());
        expect(detections, 0);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }
}
