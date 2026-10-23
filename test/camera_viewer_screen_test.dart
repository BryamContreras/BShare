import 'dart:async';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/infrastructure/services/android_screen_share_execution_service.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/screens/camera_viewer_screen.dart';
import 'package:bshare/src/presentation/widgets/orientation_aware_video_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _phone = DeviceInfo(
  id: 'phone',
  name: 'Test phone',
  platform: 'Android',
  ip: '192.168.1.20',
  port: 53317,
  lastSeen: DateTime(2026),
);

class _CameraVideo extends ScreenShareService {
  _CameraVideo()
    : super(const AppLogger(), AndroidScreenShareExecutionService());

  int watches = 0;
  int stops = 0;
  DeviceInfo? watchedDevice;
  List<String>? allowed;
  Completer<void>? connecting;
  Completer<void>? stopping;
  Object? connectionError;

  @override
  VideoShareSource get source => VideoShareSource.camera;

  @override
  Future<void> watchCamera(
    DeviceInfo device, {
    List<String>? allowedLocalIps,
  }) async {
    watches++;
    watchedDevice = device;
    allowed = allowedLocalIps;
    state.value = const ScreenShareState(mode: ScreenShareMode.watching);
    await connecting?.future;
    if (connectionError case final error?) throw error;
  }

  @override
  Future<void> stopWatching({String status = 'Idle'}) async {
    stops++;
    await stopping?.future;
    state.value = ScreenShareState(mode: ScreenShareMode.idle, status: status);
  }
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    _CameraVideo video, {
    DeviceInfo? device,
    List<String>? allowedLocalIps,
    Future<void> Function()? onClose,
    Locale locale = const Locale('en'),
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [screenShareServiceProvider.overrideWithValue(video)],
        child: MaterialApp(
          locale: locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: FocusedCameraViewer(
            device: device,
            allowedLocalIps: allowedLocalIps,
            onClose: onClose ?? () async {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('connects once and uses the existing remote renderer', (
    tester,
  ) async {
    final video = _CameraVideo();
    addTearDown(video.dispose);
    await mount(
      tester,
      video,
      device: _phone,
      allowedLocalIps: const ['192.168.42.2'],
    );
    expect(video.watches, 1);
    final stop = tester.widget<IconButton>(
      find.byKey(const ValueKey('camera-viewer-stop')),
    );
    expect(stop.style!.backgroundColor!.resolve({}), Colors.transparent);
    final stopPosition = tester.getTopRight(
      find.byKey(const ValueKey('camera-viewer-stop')),
    );
    expect(
      stopPosition.dx,
      greaterThan(
        tester.view.physicalSize.width / tester.view.devicePixelRatio - 70,
      ),
    );
    expect(stopPosition.dy, lessThan(30));
    expect(video.watchedDevice, same(_phone));
    expect(video.allowed, ['192.168.42.2']);
    expect(video.focusedViewerActive.value, isTrue);
    expect(
      tester
          .widget<OrientationAwareVideoView>(
            find.byType(OrientationAwareVideoView),
          )
          .renderer,
      same(video.remoteRenderer),
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.tapAt(const Offset(200, 200));
    await tester.pump();
    expect(video.watches, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(video.stops, 1);
    expect(video.focusedViewerActive.value, isFalse);
  });

  testWidgets('hides Stop after inactivity and first touch only reveals it', (
    tester,
  ) async {
    final video = _CameraVideo();
    addTearDown(video.dispose);
    await mount(tester, video, device: _phone);
    final stop = find.byKey(const ValueKey('camera-viewer-stop'));
    final buttonPosition = tester.getCenter(stop);
    await tester.pump(const Duration(seconds: 3));
    expect(stop, findsNothing);
    await tester.tapAt(buttonPosition);
    await tester.pump();
    expect(stop, findsOneWidget);
    expect(video.stops, 0);
    await tester.tap(stop);
    await tester.pump();
    expect(video.stops, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
    expect(video.stops, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'mouse movement resets inactivity and keyboard reveals controls',
    (tester) async {
      final video = _CameraVideo();
      addTearDown(video.dispose);
      await mount(tester, video, device: _phone);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(200, 200));
      addTearDown(mouse.removePointer);
      await tester.pump(const Duration(seconds: 2));
      await mouse.moveTo(const Offset(240, 200));
      await tester.pump(const Duration(seconds: 2));
      expect(find.byKey(const ValueKey('camera-viewer-stop')), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('camera-viewer-stop')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(find.byKey(const ValueKey('camera-viewer-stop')), findsOneWidget);
      expect(video.stops, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('remote disconnect reveals Stop and keeps it visible', (
    tester,
  ) async {
    final video = _CameraVideo();
    addTearDown(video.dispose);
    await mount(tester, video, device: _phone);
    await tester.pump(const Duration(seconds: 3));
    video.state.value = const ScreenShareState(
      mode: ScreenShareMode.idle,
      status: 'Camera share ended',
    );
    await tester.pump();
    expect(find.text('Camera transmission ended'), findsOneWidget);
    expect(find.byKey(const ValueKey('camera-viewer-stop')), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    expect(find.byKey(const ValueKey('camera-viewer-stop')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'connection failure shows localized text and leaves Stop visible',
    (tester) async {
      final video = _CameraVideo()
        ..connectionError = StateError('native implementation details');
      addTearDown(video.dispose);
      await mount(tester, video, device: _phone, locale: const Locale('es'));
      await tester.pump();
      expect(
        find.textContaining('No se pudo conectar con la cámara'),
        findsOneWidget,
      );
      expect(
        find.textContaining('native implementation details'),
        findsNothing,
      );
      await tester.pump(const Duration(seconds: 10));
      expect(find.byTooltip('Detener'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('Back and Stop await one shutdown before returning', (
    tester,
  ) async {
    final video = _CameraVideo()..stopping = Completer<void>();
    addTearDown(video.dispose);
    var returned = 0;
    await mount(
      tester,
      video,
      device: _phone,
      onClose: () async {
        returned++;
      },
    );
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.tap(find.byKey(const ValueKey('camera-viewer-stop')));
    await tester.pump();
    expect(video.stops, 1);
    expect(returned, 0);
    video.stopping!.complete();
    // The callback intentionally leaves this test route mounted. Its closing
    // spinner remains active until the real router removes the viewer.
    await tester.pump();
    await tester.pump();
    expect(returned, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(video.stops, 1);
    expect(video.focusedViewerActive.value, isFalse);
  });

  testWidgets('unmount during connection cancels its viewer exactly once', (
    tester,
  ) async {
    final video = _CameraVideo()..connecting = Completer<void>();
    addTearDown(video.dispose);
    await mount(tester, video, device: _phone);
    expect(video.watches, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(video.stops, 1);
    video.connecting!.complete();
    await tester.pump(const Duration(seconds: 5));
    expect(video.watches, 1);
    expect(video.stops, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an attached camera viewer reuses its peer without reconnecting',
    (tester) async {
      final video = _CameraVideo();
      addTearDown(video.dispose);
      video.state.value = const ScreenShareState(
        mode: ScreenShareMode.watching,
      );
      await mount(tester, video);
      expect(video.watches, 0);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.tap(find.byKey(const ValueKey('camera-viewer-stop')));
      await tester.pump();
      expect(video.stops, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
