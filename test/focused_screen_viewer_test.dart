import 'dart:async';
import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/infrastructure/services/android_screen_share_execution_service.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/screens/screen_viewer_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
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

Future<void> _pumpViewer(
  WidgetTester tester,
  _Screen service, {
  Future<void> Function()? onClose,
}) async {
  service.state.value = const ScreenShareState(
    mode: ScreenShareMode.watching,
    status: 'Watching remote screen',
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [screenShareServiceProvider.overrideWithValue(service)],
      child: MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: FocusedScreenViewer(onClose: onClose ?? () async {}),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');
  late List<bool> fullscreenChanges;
  late bool nativeFullscreen;
  late String nativeTitleBar;
  late List<String> windowOperations;
  bool failTitleRestore = false;
  Completer<void>? fullscreenGate;
  Completer<void>? initializationGate;

  setUp(() {
    fullscreenChanges = [];
    nativeFullscreen = false;
    nativeTitleBar = 'normal';
    windowOperations = [];
    failTitleRestore = false;
    fullscreenGate = null;
    initializationGate = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'ensureInitialized') {
            await initializationGate?.future;
            return true;
          }
          if (call.method == 'isFullScreen') return nativeFullscreen;
          if (call.method == 'setFullScreen') {
            final target = (call.arguments as Map)['isFullScreen'] as bool;
            fullscreenChanges.add(target);
            windowOperations.add('fullscreen:$target');
            await fullscreenGate?.future;
            nativeFullscreen = target;
            return true;
          }
          if (call.method == 'setTitleBarStyle') {
            final style = (call.arguments as Map)['titleBarStyle'] as String;
            windowOperations.add('title:$style');
            if (style == 'normal' && failTitleRestore) {
              failTitleRestore = false;
              throw PlatformException(code: 'transient-title-bar-error');
            }
            nativeTitleBar = style;
            return true;
          }
          throw StateError('Unexpected window operation: ${call.method}');
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

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

  testWidgets(
    'windowed screen controls stay visible without window mutations',
    (tester) async {
      final service = _Screen()..closed.complete();
      addTearDown(service.dispose);
      await _pumpViewer(tester, service);
      await tester.pump(const Duration(seconds: 10));
      expect(find.byTooltip('Fullscreen'), findsOneWidget);
      expect(find.byTooltip('Close viewer'), findsOneWidget);
      expect(find.text('Watching remote screen'), findsOneWidget);
      expect(fullscreenChanges, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'fullscreen hides all controls at three seconds and mouse wakes them',
    (tester) async {
      final service = _Screen()..closed.complete();
      addTearDown(service.dispose);
      await _pumpViewer(tester, service);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(100, 300));
      await tester.tap(find.byTooltip('Fullscreen'));
      await tester.pump();
      expect(fullscreenChanges, [true]);
      expect(find.byTooltip('Exit fullscreen'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 2999));
      expect(
        find.byKey(const ValueKey('screen-viewer-controls')),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 1));
      expect(
        find.byKey(const ValueKey('screen-viewer-controls')),
        findsNothing,
      );
      expect(find.byTooltip('Close viewer'), findsNothing);
      expect(find.text('Watching remote screen'), findsNothing);
      expect(
        tester
            .widget<MouseRegion>(
              find.byKey(const ValueKey('screen-viewer-surface')),
            )
            .cursor,
        SystemMouseCursors.none,
      );
      await mouse.moveTo(const Offset(120, 300));
      await tester.pump();
      expect(find.byTooltip('Exit fullscreen'), findsOneWidget);
      expect(find.byTooltip('Close viewer'), findsOneWidget);
      expect(find.text('Watching remote screen'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 2999));
      expect(
        find.byKey(const ValueKey('screen-viewer-controls')),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 1));
      expect(
        find.byKey(const ValueKey('screen-viewer-controls')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('Escape exits fullscreen without ending the live screen viewer', (
    tester,
  ) async {
    final service = _Screen()..closed.complete();
    addTearDown(service.dispose);
    var returned = 0;
    await _pumpViewer(tester, service, onClose: () async => returned++);
    await tester.tap(find.byTooltip('Fullscreen'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(find.byKey(const ValueKey('screen-viewer-controls')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(fullscreenChanges, [true, false]);
    expect(find.byTooltip('Fullscreen'), findsOneWidget);
    expect(service.stops, 0);
    expect(returned, 0);
    expect(service.focusedViewerActive.value, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(service.stops, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'disconnection restores controls and keeps the ended message visible',
    (tester) async {
      final service = _Screen()..closed.complete();
      addTearDown(service.dispose);
      await _pumpViewer(tester, service);
      await tester.tap(find.byTooltip('Fullscreen'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      service.state.value = const ScreenShareState(
        mode: ScreenShareMode.idle,
        status: 'Screen share ended',
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      expect(find.byTooltip('Exit fullscreen'), findsOneWidget);
      expect(find.byTooltip('Close viewer'), findsOneWidget);
      expect(find.text('The sender has disconnected.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'Close restores the window after receiver cleanup and returns once',
    (tester) async {
      final service = _Screen();
      addTearDown(service.dispose);
      var returned = 0;
      await _pumpViewer(
        tester,
        service,
        onClose: () async {
          expect(nativeFullscreen, isFalse);
          returned++;
        },
      );
      await tester.tap(find.byTooltip('Fullscreen'));
      await tester.pump();
      await tester.tap(find.byTooltip('Close viewer'));
      await tester.pump();
      expect(service.stops, 1);
      expect(fullscreenChanges, [true]);
      expect(returned, 0);
      service.closed.complete();
      await tester.pumpAndSettle();
      expect(fullscreenChanges, [true, false]);
      expect(returned, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(service.stops, 1);
    },
  );

  testWidgets('unmount restores only the window changed by this viewer', (
    tester,
  ) async {
    final service = _Screen()..closed.complete();
    addTearDown(service.dispose);
    await _pumpViewer(tester, service);
    await tester.tap(find.byTooltip('Fullscreen'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(fullscreenChanges, [true, false]);
    expect(nativeFullscreen, isFalse);
    expect(service.stops, 1);
  });

  testWidgets('Escape during native entry serializes the final exit', (
    tester,
  ) async {
    final service = _Screen()..closed.complete();
    addTearDown(service.dispose);
    await _pumpViewer(tester, service);
    fullscreenGate = Completer<void>();
    await tester.tap(find.byTooltip('Fullscreen'));
    await tester.pump();
    expect(fullscreenChanges, [true]);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    fullscreenGate!.complete();
    await tester.pump();
    expect(fullscreenChanges, [true, false]);
    expect(nativeFullscreen, isFalse);
    expect(service.stops, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unmount during initialization never enters fullscreen late', (
    tester,
  ) async {
    final service = _Screen()..closed.complete();
    addTearDown(service.dispose);
    await _pumpViewer(tester, service);
    initializationGate = Completer<void>();
    await tester.tap(find.byTooltip('Fullscreen'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    initializationGate!.complete();
    await tester.pump();
    expect(fullscreenChanges, isEmpty);
    expect(nativeFullscreen, isFalse);
    expect(service.stops, 1);
  });

  testWidgets('an existing fullscreen window is left alone on viewer unmount', (
    tester,
  ) async {
    final service = _Screen()..closed.complete();
    addTearDown(service.dispose);
    nativeFullscreen = true;
    await _pumpViewer(tester, service);
    await tester.tap(find.byTooltip('Fullscreen'));
    await tester.pump();
    expect(find.byTooltip('Exit fullscreen'), findsOneWidget);
    expect(fullscreenChanges, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(fullscreenChanges, isEmpty);
    expect(nativeFullscreen, isTrue);
  });

  testWidgets(
    'Windows hides the caption after saving native placement and restores it',
    (tester) async {
      final service = _Screen()..closed.complete();
      addTearDown(service.dispose);
      await _pumpViewer(tester, service);
      await tester.tap(find.byTooltip('Fullscreen'));
      await tester.pump();
      expect(windowOperations, ['fullscreen:true', 'title:hidden']);
      expect(nativeTitleBar, 'hidden');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(windowOperations, [
        'fullscreen:true',
        'title:hidden',
        'fullscreen:false',
        'title:normal',
      ]);
      expect(nativeTitleBar, 'normal');
      expect(service.stops, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'Close retries an owned caption restore after fullscreen already exited',
    (tester) async {
      final service = _Screen()..closed.complete();
      addTearDown(service.dispose);
      var returned = 0;
      await _pumpViewer(tester, service, onClose: () async => returned++);
      await tester.tap(find.byTooltip('Fullscreen'));
      await tester.pump();
      failTitleRestore = true;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(nativeFullscreen, isFalse);
      expect(nativeTitleBar, 'hidden');
      await tester.tap(find.byTooltip('Close viewer'));
      await tester.pump();
      expect(nativeTitleBar, 'normal');
      expect(windowOperations, [
        'fullscreen:true',
        'title:hidden',
        'fullscreen:false',
        'title:normal',
        'title:normal',
      ]);
      expect(returned, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
    skip: !Platform.isWindows,
  );
}
