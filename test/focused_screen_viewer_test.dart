import 'dart:async';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/infrastructure/services/android_screen_share_execution_service.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/screens/screen_viewer_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Screen extends ScreenShareService {
  _Screen() : super(const AppLogger(), AndroidScreenShareExecutionService());
  final closed = Completer<void>();
  int stops = 0;
  @override
  Future<void> stopWatching({String status = 'Idle'}) async {
    stops++;
    await closed.future;
  }
}

void main() {
  testWidgets(
    'system Back and Close share one viewer shutdown and restore its origin',
    (tester) async {
      final service = _Screen();
      addTearDown(service.dispose);
      var returned = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [screenShareServiceProvider.overrideWithValue(service)],
          child: MaterialApp(
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: FocusedScreenViewer(
              onClose: () async {
                returned++;
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.tap(find.byTooltip('Close viewer'));
      await tester.pump();
      expect(service.stops, 1);
      expect(returned, 0);
      service.closed.complete();
      await tester.pumpAndSettle();
      expect(returned, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(service.stops, 1);
      expect(service.focusedViewerActive.value, isFalse);
    },
  );
}
