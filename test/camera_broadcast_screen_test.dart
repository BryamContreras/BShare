import 'dart:async';
import 'dart:math' as math;

import 'package:bshare/src/application/camera_session_controller.dart';
import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/application/receive_controller.dart';
import 'package:bshare/src/domain/entities/camera_connection_mode.dart';
import 'package:bshare/src/domain/entities/camera_device.dart';
import 'package:bshare/src/infrastructure/services/android_screen_share_execution_service.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/camera_display_service.dart';
import 'package:bshare/src/infrastructure/services/network_service.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:bshare/src/infrastructure/services/usb_camera_network_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/screens/camera_broadcast_screen.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:bshare/src/presentation/widgets/camera_display_overlay.dart';
import 'package:bshare/src/presentation/widgets/orientation_aware_video_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _rear = CameraDevice(id: '0', label: 'Camera 0', frontFacing: false);
const _front = CameraDevice(id: '1', label: 'Camera 1', frontFacing: true);

class _Video extends ScreenShareService {
  _Video() : super(const AppLogger(), AndroidScreenShareExecutionService()) {
    state.value = const ScreenShareState(mode: ScreenShareMode.sharing);
  }

  CameraDevice camera = _rear;
  VideoShareSource shareSource = VideoShareSource.camera;

  @override
  VideoShareSource get source => shareSource;
  @override
  CameraDevice get currentCamera => camera;
}

class _Session extends CameraSessionController {
  _Session(
    this.video, {
    this.torchAvailable = true,
    this.connection = CameraConnectionMode.wifi,
  });
  final _Video video;
  final bool torchAvailable;
  final CameraConnectionMode connection;
  bool microphoneEnabled = false;
  bool torchEnabled = false;
  final microphoneChanges = <bool>[];
  final torchChanges = <bool>[];
  Completer<void>? changing;
  bool failMicrophone = false;
  bool failTorch = false;
  int stops = 0;
  final switches = <CameraDevice>[];
  Completer<void>? stopping;
  bool failSwitch = false;
  bool failStop = false;

  @override
  CameraSessionState build() => _state();

  CameraSessionState _state({bool busy = false, String? error}) =>
      CameraSessionState(
        busy: busy,
        connection: connection,
        error: error,
        microphoneEnabled: microphoneEnabled,
        torchEnabled: torchEnabled,
        torchAvailable: torchAvailable && !video.camera.frontFacing,
      );

  @override
  Future<void> setMicrophoneEnabled(bool enabled) async {
    microphoneChanges.add(enabled);
    state = _state(busy: true);
    await changing?.future;
    if (failMicrophone) {
      state = _state(error: 'cameraMicrophoneFailed');
      throw StateError('Native microphone error must not reach the UI');
    }
    microphoneEnabled = enabled;
    state = _state();
  }

  @override
  Future<void> setTorchEnabled(bool enabled) async {
    torchChanges.add(enabled);
    state = _state(busy: true);
    await changing?.future;
    if (failTorch) {
      state = _state(error: 'cameraTorchFailed');
      throw StateError('Native torch error must not reach the UI');
    }
    torchEnabled = enabled;
    state = _state();
  }

  @override
  Future<void> switchCamera(CameraDevice camera) async {
    switches.add(camera);
    state = _state(busy: true);
    await Future<void>.value();
    if (failSwitch) {
      state = _state(error: 'cameraSwitchFailed');
      throw StateError('Native error details must not reach the UI');
    }
    video.camera = camera;
    torchEnabled = false;
    state = _state();
  }

  @override
  Future<void> stop() async {
    stops++;
    state = const CameraSessionState(busy: true);
    await stopping?.future;
    if (failStop) {
      state = const CameraSessionState();
      throw StateError('Native stop failed');
    }
    video.state.value = const ScreenShareState(mode: ScreenShareMode.idle);
    state = const CameraSessionState();
  }
}

class _Receiver extends ReceiveController {
  @override
  Future<ReceiveState> build() async =>
      const ReceiveState(visible: true, port: 53319);
}

void main() {
  late _Video video;
  late _Session session;
  late GoRouter router;

  Future<void> mount(
    WidgetTester tester, {
    List<CameraDevice> cameras = const [_rear, _front],
    CameraDisplayService? display,
    bool torchAvailable = true,
    Size size = const Size(400, 800),
    double textScale = 1,
    Locale locale = const Locale('en'),
    EdgeInsets safeInsets = EdgeInsets.zero,
    CameraConnectionMode connection = CameraConnectionMode.wifi,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    video = _Video();
    session = _Session(
      video,
      torchAvailable: torchAvailable,
      connection: connection,
    );
    final container = ProviderContainer(
      overrides: [
        screenShareServiceProvider.overrideWithValue(video),
        cameraSessionProvider.overrideWith(() => session),
        cameraDevicesProvider.overrideWith((_) async => cameras),
        receiveControllerProvider.overrideWith(_Receiver.new),
        networkProvider.overrideWith(
          (_) async => const NetworkSnapshot(ip: '192.168.1.20'),
        ),
        usbCameraNetworkProvider.overrideWith(
          (_) async => const UsbCameraNetworkSnapshot(
            addresses: [
              UsbCameraAddress(
                ip: '192.168.42.129',
                prefixLength: 24,
                interfaceName: 'usb0',
              ),
            ],
          ),
        ),
        if (display != null)
          cameraDisplayServiceProvider.overrideWithValue(display),
      ],
    );
    router = GoRouter(
      initialLocation: '/camera/live',
      routes: [
        GoRoute(
          path: '/camera/live',
          builder: (_, _) => const CameraBroadcastScreen(),
        ),
        GoRoute(
          path: '/camera',
          builder: (_, _) => const Scaffold(body: Text('camera-setup')),
        ),
        GoRoute(
          path: '/settings',
          builder: (_, _) => const Scaffold(body: Text('settings')),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
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
              textScaler: TextScaler.linear(textScale),
              padding: safeInsets,
              viewPadding: safeInsets,
            ),
            child: display == null
                ? child!
                : CameraDisplayOverlay(child: child!),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      router.dispose();
      container.dispose();
      await video.dispose();
    });
  }

  testWidgets(
    'broadcast starts hidden and shows the shared renderer on demand',
    (tester) async {
      await mount(tester);
      expect(find.byType(AppShell), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(OrientationAwareVideoView), findsNothing);
      expect(find.text('Preview hidden'), findsOneWidget);
      expect(find.text('Your camera is still being shared.'), findsOneWidget);
      expect(find.byTooltip('Show preview'), findsOneWidget);
      await tester.tap(find.byTooltip('Show preview'));
      await tester.pumpAndSettle();
      expect(find.byType(OrientationAwareVideoView), findsOneWidget);
      final preview = tester.widget<OrientationAwareVideoView>(
        find.byType(OrientationAwareVideoView),
      );
      expect(preview.renderer, same(video.localRenderer));
      expect(find.text('Rear camera'), findsOneWidget);
      expect(find.byTooltip('Switch camera'), findsOneWidget);
      expect(find.byTooltip('Hide preview'), findsOneWidget);
      expect(session.stops, 0);
      expect(session.switches, isEmpty);
    },
  );

  testWidgets('hidden preview puts a plain address below the sharing message', (
    tester,
  ) async {
    await mount(tester);
    expect(find.textContaining('192.168.1.20:53319'), findsOneWidget);
    expect(find.textContaining('192.168.42.129'), findsNothing);
    final address = find.byKey(const ValueKey('camera-broadcast-address'));
    final message = find.text('Your camera is still being shared.');
    expect(tester.widget(address), isA<Text>());
    expect(
      tester.getTopLeft(address).dy,
      greaterThan(tester.getBottomLeft(message).dy),
    );
    expect(
      tester.getCenter(address).dx,
      closeTo(tester.getCenter(message).dx, .1),
    );
    expect(find.byType(Card), findsNothing);
    expect(find.byType(SelectableText), findsNothing);
    expect(find.byIcon(Icons.copy_rounded), findsNothing);
    expect(find.byType(OrientationAwareVideoView), findsNothing);
    expect(video.state.value.mode, ScreenShareMode.sharing);
    expect(session.stops, 0);
    await tester.tap(find.byTooltip('Show preview'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('camera-broadcast-address')),
      findsNothing,
    );
    expect(find.textContaining('192.168.1.20:53319'), findsNothing);
    expect(video.state.value.mode, ScreenShareMode.sharing);
  });

  testWidgets('USB broadcast shows its port without a LAN or tether address', (
    tester,
  ) async {
    await mount(tester, connection: CameraConnectionMode.usb);
    expect(find.textContaining('USB · Port: 53319'), findsOneWidget);
    expect(find.textContaining('192.168.42.129'), findsNothing);
    expect(find.textContaining('192.168.1.20'), findsNothing);
    expect(find.byType(OrientationAwareVideoView), findsNothing);
    expect(video.state.value.mode, ScreenShareMode.sharing);
    expect(session.stops, 0);
    await tester.tap(find.byTooltip('Show preview'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('camera-broadcast-address')),
      findsNothing,
    );
    expect(find.textContaining('192.168.42.129'), findsNothing);
    expect(video.state.value.mode, ScreenShareMode.sharing);
  });

  testWidgets('camera controls stay vertical, transparent and at top right', (
    tester,
  ) async {
    await mount(tester);
    final keys = [
      'camera-live-switch',
      'camera-live-preview-toggle',
      'camera-live-torch',
      'camera-live-microphone',
      'camera-live-stop',
    ];
    void checkControls() {
      var previousY = -1.0;
      double? firstX;
      for (final key in keys) {
        final finder = find.byKey(ValueKey(key));
        final center = tester.getCenter(finder);
        firstX ??= center.dx;
        expect(center.dx, closeTo(firstX, 0.1));
        expect(center.dx, greaterThan(tester.view.physicalSize.width - 70));
        expect(center.dy, greaterThan(previousY));
        previousY = center.dy;
        final button = tester.widget<IconButton>(finder);
        expect(button.style!.backgroundColor!.resolve({}), Colors.transparent);
      }
      expect(
        tester.getTopLeft(find.byKey(ValueKey(keys.first))).dy,
        lessThan(30),
      );
    }

    checkControls();
    tester.view.physicalSize = const Size(800, 400);
    await tester.pumpAndSettle();
    checkControls();
    expect(tester.takeException(), isNull);
  });

  for (final (name, size, scale, insets) in const [
    ('small portrait', Size(320, 480), 2.0, EdgeInsets.zero),
    (
      'short landscape with cutout',
      Size(568, 240),
      3.0,
      EdgeInsets.fromLTRB(30, 0, 18, 18),
    ),
    ('split screen', Size(320, 200), 3.0, EdgeInsets.fromLTRB(0, 24, 0, 16)),
    ('tablet', Size(1024, 768), 2.0, EdgeInsets.all(24)),
    (
      'portrait with system insets',
      Size(390, 844),
      3.0,
      EdgeInsets.fromLTRB(0, 44, 0, 34),
    ),
  ]) {
    testWidgets(
      'Spanish $name keeps camera actions reachable with large text',
      (tester) async {
        await mount(
          tester,
          size: size,
          textScale: scale,
          locale: const Locale('es'),
          safeInsets: insets,
        );
        final stop = find.byKey(const ValueKey('camera-live-stop'));
        final initialStop = tester.getRect(stop);
        final availableHeight =
            size.height -
            math.max(12, insets.top) -
            math.max(12, insets.bottom);
        final compact = availableHeight < 256;
        expect(initialStop.width, greaterThanOrEqualTo(48));
        expect(initialStop.height, greaterThanOrEqualTo(48));
        expect(initialStop.top, greaterThanOrEqualTo(math.max(12, insets.top)));
        expect(
          initialStop.right,
          lessThanOrEqualTo(size.width - math.max(12, insets.right)),
        );
        expect(
          initialStop.bottom,
          lessThanOrEqualTo(size.height - math.max(12, insets.bottom)),
        );
        expect(
          find.byKey(const ValueKey('camera-live-controls-scroll')),
          compact ? findsOneWidget : findsNothing,
        );
        if (compact) {
          expect(
            initialStop.bottom,
            closeTo(size.height - math.max(12, insets.bottom), .1),
          );
          final scroll = tester.getRect(
            find.byKey(const ValueKey('camera-live-controls-scroll')),
          );
          expect(scroll.bottom, lessThan(initialStop.top));
        }
        for (final key in [
          'camera-live-switch',
          'camera-live-preview-toggle',
          'camera-live-torch',
          'camera-live-microphone',
        ]) {
          final action = find.byKey(ValueKey(key));
          expect(tester.getSize(action).width, greaterThanOrEqualTo(48));
          expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
          expect(
            tester
                .widget<IconButton>(action)
                .style!
                .backgroundColor!
                .resolve({}),
            Colors.transparent,
          );
        }
        final microphone = find.byKey(const ValueKey('camera-live-microphone'));
        await tester.ensureVisible(microphone);
        await tester.pumpAndSettle();
        await tester.tap(microphone);
        await tester.pumpAndSettle();
        expect(session.microphoneChanges, [true]);
        expect(tester.getRect(stop), initialStop);
        final eye = find.byKey(const ValueKey('camera-live-preview-toggle'));
        await tester.ensureVisible(eye);
        await tester.pumpAndSettle();
        expect(find.text('Vista previa oculta'), findsOneWidget);
        await tester.tap(eye);
        await tester.pumpAndSettle();
        expect(find.byType(OrientationAwareVideoView), findsOneWidget);
        await tester.tap(eye);
        await tester.pumpAndSettle();
        expect(find.text('Vista previa oculta'), findsOneWidget);
        final message = tester.widget<Text>(
          find.text('La cámara continúa transmitiendo.'),
        );
        expect(message.style!.fontSize, isNotNull);
        expect(message.style!.color, Colors.white60);
        expect(find.byType(OrientationAwareVideoView), findsNothing);
        expect(video.state.value.mode, ScreenShareMode.sharing);
        expect(session.stops, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('long camera errors scroll while Stop stays reachable', (
    tester,
  ) async {
    await mount(
      tester,
      size: const Size(320, 200),
      textScale: 3,
      locale: const Locale('es'),
      safeInsets: const EdgeInsets.fromLTRB(0, 24, 0, 16),
    );
    session.failMicrophone = true;
    final microphone = find.byKey(const ValueKey('camera-live-microphone'));
    await tester.ensureVisible(microphone);
    await tester.pumpAndSettle();
    await tester.tap(microphone);
    await tester.pumpAndSettle();
    final header = find.byKey(const ValueKey('camera-live-header-scroll'));
    final scroll = tester.state<ScrollableState>(
      find.descendant(of: header, matching: find.byType(Scrollable)).first,
    );
    expect(scroll.position.maxScrollExtent, greaterThan(0));
    await tester.drag(header, const Offset(0, -70));
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('camera-live-stop')));
    await tester.pumpAndSettle();
    expect(session.stops, 1);
    expect(find.text('camera-setup'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('microphone starts off and toggles without another capture', (
    tester,
  ) async {
    await mount(tester);
    expect(find.byTooltip('Turn microphone on'), findsOneWidget);
    expect(session.microphoneChanges, isEmpty);
    await tester.tap(find.byKey(const ValueKey('camera-live-microphone')));
    await tester.pumpAndSettle();
    expect(session.microphoneChanges, [true]);
    expect(find.byTooltip('Turn microphone off'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('camera-live-microphone')));
    await tester.pumpAndSettle();
    expect(session.microphoneChanges, [true, false]);
    expect(find.byTooltip('Turn microphone on'), findsOneWidget);
    expect(video.state.value.mode, ScreenShareMode.sharing);
    expect(find.byType(OrientationAwareVideoView), findsNothing);
    expect(session.switches, isEmpty);
    expect(session.stops, 0);
  });

  testWidgets('unsupported flash stays disabled while microphone works', (
    tester,
  ) async {
    await mount(tester, torchAvailable: false);
    expect(find.byTooltip('Flash unavailable for this camera'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('camera-live-torch')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('Turn microphone on'));
    await tester.pumpAndSettle();
    expect(session.microphoneChanges, [true]);
    expect(session.torchChanges, isEmpty);
  });

  testWidgets('pending microphone changes disable duplicate camera controls', (
    tester,
  ) async {
    await mount(tester);
    session.changing = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('camera-live-microphone')));
    await tester.pump();
    for (final key in [
      'camera-live-microphone',
      'camera-live-torch',
      'camera-live-switch',
    ]) {
      expect(
        tester.widget<IconButton>(find.byKey(ValueKey(key))).onPressed,
        isNull,
      );
    }
    expect(session.microphoneChanges, [true]);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('camera-live-preview-toggle')),
          )
          .onPressed,
      isNotNull,
    );
    session.changing!.complete();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Turn microphone off'), findsOneWidget);
    expect(session.stops, 0);
  });

  testWidgets('microphone failure keeps off state and allows a retry', (
    tester,
  ) async {
    await mount(tester);
    session.failMicrophone = true;
    await tester.tap(find.byTooltip('Turn microphone on'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Could not change the microphone. Check microphone permission and try again.',
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Turn microphone on'), findsOneWidget);
    expect(find.textContaining('Native microphone'), findsNothing);
    session.failMicrophone = false;
    await tester.tap(find.byTooltip('Turn microphone on'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Turn microphone off'), findsOneWidget);
    expect(session.microphoneChanges, [true, true]);
    expect(session.stops, 0);
  });

  testWidgets(
    'flash failure keeps off state and successful retry lights icon',
    (tester) async {
      await mount(tester);
      session.failTorch = true;
      await tester.tap(find.byTooltip('Turn flash on'));
      await tester.pumpAndSettle();
      expect(
        find.text('Could not change the flash. Please try again.'),
        findsOneWidget,
      );
      expect(find.byTooltip('Turn flash on'), findsOneWidget);
      expect(find.textContaining('Native torch'), findsNothing);
      session.failTorch = false;
      await tester.tap(find.byTooltip('Turn flash on'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Turn flash off'), findsOneWidget);
      expect(session.torchChanges, [true, true]);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('camera-live-torch')))
            .isSelected,
        isTrue,
      );
      await tester.tap(find.byTooltip('Switch camera'));
      await tester.pumpAndSettle();
      expect(
        find.byTooltip('Flash unavailable for this camera'),
        findsOneWidget,
      );
      expect(session.stops, 0);
    },
  );

  testWidgets('eye removes only local preview and leaves camera sharing', (
    tester,
  ) async {
    await mount(tester);
    expect(find.byType(OrientationAwareVideoView), findsNothing);
    expect(find.text('Preview hidden'), findsOneWidget);
    expect(find.text('Your camera is still being shared.'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('camera-broadcast-address')),
      findsOneWidget,
    );
    expect(video.state.value.mode, ScreenShareMode.sharing);
    expect(session.stops, 0);
    expect(session.switches, isEmpty);
    await tester.tap(find.byTooltip('Show preview'));
    await tester.pumpAndSettle();
    expect(find.byType(OrientationAwareVideoView), findsOneWidget);
    expect(find.text('Preview hidden'), findsNothing);
    expect(
      find.byKey(const ValueKey('camera-broadcast-address')),
      findsNothing,
    );
    expect(video.state.value.mode, ScreenShareMode.sharing);
    await tester.tap(find.byTooltip('Hide preview'));
    await tester.pumpAndSettle();
    expect(find.byType(OrientationAwareVideoView), findsNothing);
    expect(
      find.byKey(const ValueKey('camera-broadcast-address')),
      findsOneWidget,
    );
    expect(video.state.value.mode, ScreenShareMode.sharing);
    expect(session.stops, 0);
  });

  testWidgets('flip selects opposite side while local preview remains hidden', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byTooltip('Switch camera'));
    await tester.pumpAndSettle();
    expect(session.switches, [_front]);
    expect(find.text('Front camera'), findsOneWidget);
    expect(find.byType(OrientationAwareVideoView), findsNothing);
    await tester.tap(find.byTooltip('Switch camera'));
    await tester.pumpAndSettle();
    expect(session.switches, [_front, _rear]);
    expect(session.stops, 0);
  });

  testWidgets('single-side hardware disables flip', (tester) async {
    await mount(tester, cameras: [_rear]);
    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey('camera-live-switch')),
    );
    expect(button.onPressed, isNull);
    expect(find.byType(OrientationAwareVideoView), findsNothing);
  });

  testWidgets('Back and Stop wait for a single complete shutdown', (
    tester,
  ) async {
    await mount(tester);
    session.stopping = Completer<void>();
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.tap(find.byKey(const ValueKey('camera-live-stop')));
    await tester.pump();
    expect(session.stops, 1);
    expect(find.text('camera-setup'), findsNothing);
    session.stopping!.complete();
    await tester.pumpAndSettle();
    expect(find.text('camera-setup'), findsOneWidget);
    expect(video.state.value.mode, ScreenShareMode.idle);
    expect(session.stops, 1);
  });

  testWidgets('app Back ends capture and restores setup', (tester) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('camera-live-back')));
    await tester.pumpAndSettle();
    expect(session.stops, 1);
    expect(find.text('camera-setup'), findsOneWidget);
  });

  testWidgets('navigation releases preview while session keeps capturing', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byTooltip('Show preview'));
    await tester.pumpAndSettle();
    router.go('/settings');
    await tester.pumpAndSettle();
    expect(find.text('settings'), findsOneWidget);
    expect(find.byType(OrientationAwareVideoView), findsNothing);
    expect(session.stops, 0);
    expect(video.state.value.mode, ScreenShareMode.sharing);
    router.go('/camera/live');
    await tester.pumpAndSettle();
    expect(find.byType(OrientationAwareVideoView), findsNothing);
    expect(find.byTooltip('Show preview'), findsOneWidget);
    expect(session.stops, 0);
  });

  testWidgets(
    'failed camera switch keeps broadcast and shows localized error',
    (tester) async {
      await mount(tester);
      session.failSwitch = true;
      await tester.tap(find.byTooltip('Switch camera'));
      await tester.pumpAndSettle();
      expect(
        find.text('Could not switch cameras. Please try again.'),
        findsOneWidget,
      );
      expect(find.textContaining('Native error'), findsNothing);
      expect(find.byType(OrientationAwareVideoView), findsNothing);
      expect(video.currentCamera, _rear);
      expect(session.stops, 0);
    },
  );

  testWidgets('failed stop allows retry and does not leave broadcast early', (
    tester,
  ) async {
    await mount(tester);
    session.failStop = true;
    await tester.tap(find.byKey(const ValueKey('camera-live-stop')));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not stop the camera. Please try again.'),
      findsOneWidget,
    );
    expect(find.text('camera-setup'), findsNothing);
    session.failStop = false;
    await tester.tap(find.byKey(const ValueKey('camera-live-stop')));
    await tester.pumpAndSettle();
    expect(find.text('camera-setup'), findsOneWidget);
    expect(session.stops, 2);
  });

  testWidgets('global dim overlay wakes without toggling preview or camera', (
    tester,
  ) async {
    final display = CameraDisplayService(applyState: (_, _) async {});
    await mount(tester, display: display);
    final starting = display.start();
    await tester.pump();
    await starting;
    await tester.pump(const Duration(seconds: 60));
    await tester.pump();
    expect(display.dimmed.value, isTrue);
    expect(find.text('Tap to show camera controls'), findsOneWidget);
    await tester.tap(find.text('Tap to show camera controls'));
    await tester.pump();
    expect(display.dimmed.value, isFalse);
    expect(find.byTooltip('Show preview'), findsOneWidget);
    expect(session.switches, isEmpty);
    expect(session.stops, 0);
    expect(video.state.value.mode, ScreenShareMode.sharing);
    final stopping = display.stop();
    await tester.pump();
    await stopping;
    final disposing = display.dispose();
    await tester.pump();
    await disposing;
  });
}
