import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/infrastructure/services/android_storage_access_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/screens/android_storage_picker_screen.dart';
import 'package:bshare/src/presentation/widgets/gradient_action_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _Storage extends AndroidStorageAccessService {
  bool granted = false;
  final requests = <String>[];
  final checks = <String>[];

  @override
  Future<bool> requestAccess(String path) async {
    requests.add(path);
    return granted;
  }

  @override
  Future<bool> hasAccess(String path) async {
    checks.add(path);
    return granted;
  }
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    _Storage storage, {
    required AndroidStoragePickerMode mode,
    required String path,
  }) async {
    final router = GoRouter(
      initialLocation: '/picker',
      routes: [
        GoRoute(
          path: '/picker',
          builder: (_, _) => AndroidStoragePickerScreen(
            mode: mode,
            initialDirectoryPath: path,
          ),
        ),
        GoRoute(path: '/send', builder: (_, _) => const Text('send-route')),
        GoRoute(path: '/settings', builder: (_, _) => const Text('settings')),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [androidStorageAccessProvider.overrideWithValue(storage)],
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
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
    });
  }

  for (final mode in AndroidStoragePickerMode.values) {
    testWidgets('denied $mode does not browse or allow confirmation', (
      tester,
    ) async {
      final storage = _Storage();
      const path = '/bshare-inaccessible-test/does-not-exist';
      await mount(tester, storage, mode: mode, path: path);
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(AndroidStoragePickerScreen));
      final permissionText = context.l10n.t('storagePermissionRequired');
      expect(find.text(permissionText), findsOneWidget);
      expect(find.text(context.l10n.t('openFolderFailed')), findsNothing);
      expect(storage.requests, [path]);
      expect(storage.checks, isEmpty);
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton &&
                    widget.tooltip == context.l10n.t('accept'),
              ),
            )
            .onPressed,
        isNull,
      );
      if (mode == AndroidStoragePickerMode.folder) {
        expect(
          tester
              .widget<GradientActionButton>(find.byType(GradientActionButton))
              .onPressed,
          isNull,
        );
      }
      await tester.tap(find.text(context.l10n.t('retry')));
      await tester.pumpAndSettle();
      expect(storage.requests, [path, path]);
      expect(find.text(permissionText), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'returning to the picker rechecks access without another dialog',
    (tester) async {
      final storage = _Storage();
      const path = '/bshare-inaccessible-test/does-not-exist';
      await mount(
        tester,
        storage,
        mode: AndroidStoragePickerMode.folder,
        path: path,
      );
      await tester.pumpAndSettle();
      expect(storage.requests, [path]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(storage.requests, [path]);
      expect(storage.checks, [path]);
      final context = tester.element(find.byType(AndroidStoragePickerScreen));
      expect(
        find.text(context.l10n.t('storagePermissionRequired')),
        findsOneWidget,
      );
      expect(find.text('send-route'), findsNothing);
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton &&
                    widget.tooltip == context.l10n.t('accept'),
              ),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
