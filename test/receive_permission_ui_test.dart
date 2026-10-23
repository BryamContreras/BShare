import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/application/receive_controller.dart';
import 'package:bshare/src/domain/entities/app_settings.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/screens/receive_screen.dart';
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

class _Receiver extends ReceiveController {
  _Receiver(this.grant);
  final bool grant;
  int starts = 0;
  @override
  Future<ReceiveState> build() async =>
      const ReceiveState(visible: true, port: 53317);
  @override
  Future<void> start() async {
    starts++;
    state = AsyncData(
      ReceiveState(
        visible: true,
        acceptingFiles: grant,
        port: 53317,
        error: grant ? null : 'storagePermissionRequired',
      ),
    );
  }
}

void main() {
  for (final grant in [false, true]) {
    testWidgets('video receiver can request file access, grant=$grant', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final receiver = _Receiver(grant);
      final container = ProviderContainer(
        overrides: [
          receiveControllerProvider.overrideWith(() => receiver),
          settingsProvider.overrideWith(_Settings.new),
        ],
      );
      addTearDown(container.dispose);
      final router = GoRouter(
        initialLocation: '/receive',
        routes: [
          GoRoute(path: '/receive', builder: (_, _) => const ReceiveScreen()),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            locale: const Locale('es'),
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
      expect(
        find.textContaining('La recepción de archivos está desactivada'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Iniciar receptor'));
      await tester.tap(find.text('Iniciar receptor'));
      await tester.pumpAndSettle();
      expect(receiver.starts, 1);
      expect(container.read(receiveControllerProvider).value!.visible, isTrue);
      expect(
        container.read(receiveControllerProvider).value!.acceptingFiles,
        grant,
      );
      expect(
        find.textContaining('Permite el acceso a archivos'),
        grant ? findsNothing : findsOneWidget,
      );
      expect(find.text('storagePermissionRequired'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
