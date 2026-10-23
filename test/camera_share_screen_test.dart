import 'package:bshare/src/application/camera_session_controller.dart';
import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/app_settings.dart';
import 'package:bshare/src/domain/entities/camera_connection_mode.dart';
import 'package:bshare/src/domain/entities/camera_device.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/infrastructure/services/android_screen_share_execution_service.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:bshare/src/infrastructure/services/usb_camera_network_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/screens/camera_share_screen.dart';
import 'package:bshare/src/presentation/screens/camera_viewer_screen.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:bshare/src/presentation/widgets/orientation_aware_video_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _rear = CameraDevice(id: '0', label: 'Lens 0', frontFacing: false);
const _front = CameraDevice(id: '1', label: 'Lens 1', frontFacing: true);

class _Settings extends SettingsController {
  @override
  Future<AppSettings> build() async => const AppSettings(
    deviceId: 'test',
    deviceName: 'Test',
    downloadDirectory: '/tmp',
    autoAccept: false,
    preferredPort: 53317,
    themeMode: 'system',
    languageCode: 'en',
  );
}

class _Video extends ScreenShareService {
  _Video() : super(const AppLogger(), AndroidScreenShareExecutionService());
  int enumerations = 0;
  int watches = 0;
  int viewerStops = 0;
  CameraDevice? camera;
  @override
  VideoShareSource get source => VideoShareSource.camera;
  @override
  CameraDevice? get currentCamera => camera;
  @override
  Future<List<CameraDevice>> enumerateCameras() async {
    enumerations++;
    return [_rear, _front];
  }

  @override
  Future<void> watchCamera(
    DeviceInfo device, {
    List<String>? allowedLocalIps,
  }) async {
    watches++;
    state.value = const ScreenShareState(mode: ScreenShareMode.watching);
  }

  @override
  Future<void> stopWatching({String status = 'Idle'}) async {
    viewerStops++;
    await Future<void>.value();
    state.value = const ScreenShareState(mode: ScreenShareMode.idle);
  }
}

class _Session extends CameraSessionController {
  _Session(this.video);
  final _Video video;
  int starts = 0;
  int stops = 0;
  int switches = 0;
  CameraConnectionMode? lastConnection;
  @override
  CameraSessionState build() => const CameraSessionState();
  @override
  Future<void> start({
    required CameraConnectionMode connection,
    required CameraDevice camera,
  }) async {
    starts++;
    lastConnection = connection;
    video.camera = camera;
    state = CameraSessionState(connection: connection);
    video.state.value = const ScreenShareState(mode: ScreenShareMode.sharing);
  }

  @override
  Future<void> switchCamera(CameraDevice camera) async {
    switches++;
    video.camera = camera;
    state = CameraSessionState(connection: lastConnection);
  }

  @override
  Future<void> stop() async {
    stops++;
    video.state.value = const ScreenShareState(mode: ScreenShareMode.idle);
    state = CameraSessionState(connection: lastConnection);
  }
}

class _Discovery extends DiscoveryController {
  int starts = 0;
  @override
  List<DeviceInfo> build() => [
    DeviceInfo(
      id: 'phone',
      name: 'My phone',
      platform: 'Android',
      ip: '192.168.1.20',
      port: 53317,
      lastSeen: DateTime(2026),
    ),
  ];
  @override
  Future<void> start({bool advertise = false, String? ipOverride}) async {
    starts++;
  }
}

void main() {
  late _Video video;
  late _Session session;
  late _Discovery discovery;
  late ProviderContainer container;
  late GoRouter router;

  Future<void> mount(WidgetTester tester, TargetPlatform platform) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    video = _Video();
    session = _Session(video);
    discovery = _Discovery();
    container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        screenShareServiceProvider.overrideWithValue(video),
        cameraSessionProvider.overrideWith(() => session),
        discoveryProvider.overrideWith(() => discovery),
        usbCameraNetworkProvider.overrideWith(
          (_) async => const UsbCameraNetworkSnapshot(),
        ),
      ],
    );
    await container.read(settingsProvider.future);
    container
        .read(discoveryStatusProvider.notifier)
        .set(const DiscoveryStatus(phase: DiscoveryPhase.listening));
    router = GoRouter(
      initialLocation: '/camera',
      routes: [
        GoRoute(path: '/camera', builder: (_, _) => const CameraShareScreen()),
        GoRoute(
          path: '/camera/live',
          builder: (_, _) => const Scaffold(body: Text('broadcast-page')),
        ),
        GoRoute(
          path: '/settings',
          builder: (_, _) => const Scaffold(body: Text('settings-page')),
        ),
      ],
    );
    addTearDown(() {
      router.dispose();
      container.dispose();
    });
    addTearDown(video.dispose);
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
  }

  testWidgets('mobile offers two facings and opens the full broadcast route', (
    tester,
  ) async {
    await mount(tester, TargetPlatform.android);
    expect(video.enumerations, 1);
    expect(discovery.starts, 0);
    expect(find.text('Rear camera'), findsOneWidget);
    expect(find.textContaining('Lens'), findsNothing);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Front camera').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('camera-share')));
    await tester.pumpAndSettle();
    expect(session.starts, 1);
    expect(session.lastConnection, CameraConnectionMode.wifi);
    expect(video.currentCamera?.id, '1');
    expect(find.text('broadcast-page'), findsOneWidget);
    expect(find.byType(OrientationAwareVideoView), findsNothing);
    expect(session.stops, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('returning to setup keeps capture and shares enumeration', (
    tester,
  ) async {
    await mount(tester, TargetPlatform.android);
    await tester.tap(find.byKey(const ValueKey('camera-share')));
    await tester.pumpAndSettle();
    router.go('/camera');
    await tester.pumpAndSettle();
    expect(video.enumerations, 1);
    expect(find.byType(OrientationAwareVideoView), findsNothing);
    await tester.tap(find.text('1080p · 30 FPS'));
    await tester.pumpAndSettle();
    expect(find.text('settings-page'), findsOneWidget);
    expect(session.stops, 0);
    expect(video.state.value.mode, ScreenShareMode.sharing);
    router.go('/camera');
    await tester.pumpAndSettle();
    expect(video.enumerations, 1);
    await tester.tap(find.byKey(const ValueKey('camera-open-broadcast')));
    await tester.pumpAndSettle();
    expect(find.text('broadcast-page'), findsOneWidget);
    expect(session.starts, 1);
    expect(session.stops, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('computer watches Wi-Fi camera and closes only its viewer', (
    tester,
  ) async {
    await mount(tester, TargetPlatform.linux);
    expect(video.enumerations, 0);
    expect(discovery.starts, 1);
    final watch = find.byKey(const ValueKey('camera-watch'));
    expect(tester.widget<FilledButton>(watch).onPressed, isNull);
    await tester.tap(find.text('My phone'));
    await tester.pumpAndSettle();
    await tester.tap(watch);
    await tester.pumpAndSettle();
    expect(video.watches, 1);
    expect(find.byType(FocusedCameraViewer), findsOneWidget);
    expect(find.byType(AppShell), findsNothing);
    expect(session.starts, 0);
    await tester.tap(find.byKey(const ValueKey('camera-viewer-stop')));
    await tester.pumpAndSettle();
    expect(find.byType(FocusedCameraViewer), findsNothing);
    expect(find.byType(AppShell), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(video.viewerStops, 1);
    expect(session.stops, 0);
  });

  testWidgets('USB rejects invalid address and never falls back to Wi-Fi', (
    tester,
  ) async {
    await mount(tester, TargetPlatform.linux);
    await tester.tap(find.text('USB'));
    await tester.pumpAndSettle();
    expect(find.text('My phone'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('camera-watch')));
    await tester.pump();
    expect(find.textContaining('valid IP address'), findsOneWidget);
    expect(video.watches, 0);
    await tester.enterText(
      find.byKey(const ValueKey('camera-usb-host')),
      '192.168.42.129',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('camera-watch')));
    await tester.pumpAndSettle();
    expect(find.textContaining('No USB network detected'), findsOneWidget);
    expect(video.watches, 0);
    expect(session.starts, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
