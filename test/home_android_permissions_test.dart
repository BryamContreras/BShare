import 'dart:async';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/app_settings.dart';
import 'package:bshare/src/infrastructure/services/android_platform_info_service.dart';
import 'package:bshare/src/infrastructure/services/network_service.dart';
import 'package:bshare/src/infrastructure/services/permission_request_coordinator.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/screens/home_screen.dart';
import 'package:bshare/src/presentation/widgets/action_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

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

Future<void> _pumpHome(
  WidgetTester tester, {
  required AndroidPlatformInfoService platformInfo,
  required PermissionRequestCoordinator coordinator,
  required VoidCallback onNetworkRead,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => HomeScreen(permissionCoordinator: coordinator),
      ),
      GoRoute(
        path: '/send',
        builder: (_, _) => const Scaffold(body: Text('send-page')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        androidPlatformInfoProvider.overrideWithValue(platformInfo),
        settingsProvider.overrideWith(_Settings.new),
        networkProvider.overrideWith((_) async {
          onNetworkRead();
          return const NetworkSnapshot(ip: '192.168.1.20');
        }),
      ],
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
}

void main() {
  for (final sdkInt in [23, 28, 32, 33, 34, 36]) {
    testWidgets(
      'Home requests only supported startup permissions on API $sdkInt',
      (tester) async {
        final checked = <Permission>[];
        final requested = <Permission>[];
        var networkReads = 0;
        await _pumpHome(
          tester,
          platformInfo: AndroidPlatformInfoService(
            isAndroid: true,
            readSdkInt: () async => sdkInt,
          ),
          coordinator: PermissionRequestCoordinator(
            readStatus: (permission) async {
              checked.add(permission);
              return PermissionStatus.denied;
            },
            requestPermission: (permission) async {
              requested.add(permission);
              return PermissionStatus.granted;
            },
          ),
          onNetworkRead: () => networkReads++,
        );
        expect(checked, sdkInt >= 33 ? [Permission.notification] : isEmpty);
        expect(requested, sdkInt >= 33 ? [Permission.notification] : isEmpty);
        expect(networkReads, 1);
        expect(find.text('192.168.1.20'), findsOneWidget);
        await tester.tap(find.widgetWithText(ActionCard, 'Send'));
        await tester.pumpAndSettle();
        expect(find.text('send-page'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'Home skips Android version and permission APIs on other platforms',
    (tester) async {
      var networkReads = 0;
      var versionReads = 0;
      final permissions = <Permission>[];
      await _pumpHome(
        tester,
        platformInfo: AndroidPlatformInfoService(
          isAndroid: false,
          readSdkInt: () async {
            versionReads++;
            throw StateError('Version lookup must not run');
          },
        ),
        coordinator: PermissionRequestCoordinator(
          readStatus: (permission) async {
            permissions.add(permission);
            return PermissionStatus.granted;
          },
        ),
        onNetworkRead: () => networkReads++,
      );
      expect(versionReads, 0);
      expect(permissions, isEmpty);
      expect(networkReads, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('notification denial keeps LAN and navigation usable', (
    tester,
  ) async {
    var networkReads = 0;
    final requested = <Permission>[];
    await _pumpHome(
      tester,
      platformInfo: AndroidPlatformInfoService(
        isAndroid: true,
        readSdkInt: () async => 33,
      ),
      coordinator: PermissionRequestCoordinator(
        readStatus: (_) async => PermissionStatus.denied,
        requestPermission: (permission) async {
          requested.add(permission);
          return PermissionStatus.permanentlyDenied;
        },
      ),
      onNetworkRead: () => networkReads++,
    );
    expect(requested, [Permission.notification]);
    expect(networkReads, 1);
    expect(find.text('192.168.1.20'), findsOneWidget);
    await tester.tap(find.widgetWithText(ActionCard, 'Send'));
    await tester.pumpAndSettle();
    expect(find.text('send-page'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending notification does not block navigation or reload LAN', (
    tester,
  ) async {
    final response = Completer<PermissionStatus>();
    var networkReads = 0;
    final requested = <Permission>[];
    await _pumpHome(
      tester,
      platformInfo: AndroidPlatformInfoService(
        isAndroid: true,
        readSdkInt: () async => 34,
      ),
      coordinator: PermissionRequestCoordinator(
        readStatus: (_) async => PermissionStatus.denied,
        requestPermission: (permission) {
          requested.add(permission);
          return response.future;
        },
      ),
      onNetworkRead: () => networkReads++,
    );
    expect(requested, [Permission.notification]);
    await tester.tap(find.widgetWithText(ActionCard, 'Send'));
    await tester.pumpAndSettle();
    expect(find.text('send-page'), findsOneWidget);
    response.complete(PermissionStatus.granted);
    await tester.pumpAndSettle();
    expect(networkReads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('late OS version cannot request permission after Home unmounts', (
    tester,
  ) async {
    final version = Completer<int>();
    final checked = <Permission>[];
    await _pumpHome(
      tester,
      platformInfo: AndroidPlatformInfoService(
        isAndroid: true,
        readSdkInt: () => version.future,
      ),
      coordinator: PermissionRequestCoordinator(
        readStatus: (permission) async {
          checked.add(permission);
          return PermissionStatus.granted;
        },
      ),
      onNetworkRead: () {},
    );
    await tester.pumpWidget(const SizedBox.shrink());
    version.complete(36);
    await tester.pumpAndSettle();
    expect(checked, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
