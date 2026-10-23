import 'dart:async';

import 'package:bshare/src/application/camera_session_controller.dart';
import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/infrastructure/services/android_screen_share_execution_service.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/file_server.dart';
import 'package:bshare/src/infrastructure/services/permission_request_coordinator.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/screens/direct_qr_scanner_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

class _SharedVideo extends ScreenShareService {
  _SharedVideo()
    : super(const AppLogger(), AndroidScreenShareExecutionService());
  VideoShareSource chosenSource = VideoShareSource.camera;
  int stops = 0;
  @override
  VideoShareSource get source => chosenSource;
  @override
  Future<void> stop(FileServer server, {String status = 'Idle'}) async =>
      stops++;
}

class _Session extends CameraSessionController {
  _Session({this.busy = false});
  final bool busy;
  @override
  CameraSessionState build() => CameraSessionState(busy: busy);
}

class _Scanner extends MobileScannerPlatform {
  final captures = StreamController<BarcodeCapture?>.broadcast();
  int starts = 0;
  int disposals = 0;
  @override
  Stream<BarcodeCapture?> get barcodesStream => captures.stream;
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();
  @override
  Widget buildCameraView() => const ColoredBox(color: Colors.black);
  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async {
    starts++;
    return const MobileScannerViewAttributes(
      cameraDirection: CameraFacing.back,
      currentTorchMode: TorchState.off,
      size: Size(640, 480),
      numberOfCameras: 1,
    );
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> updateScanWindow(Rect? window) async {}
  @override
  Future<void> dispose() async => disposals++;
}

void main() {
  late _Scanner scanner;
  late MobileScannerPlatform previousPlatform;
  late _SharedVideo service;
  int controllers = 0;
  int permissions = 0;
  Completer<PermissionStatus>? permissionGate;

  setUp(() {
    controllers = 0;
    permissions = 0;
    permissionGate = null;
    previousPlatform = MobileScannerPlatform.instance;
    scanner = _Scanner();
    MobileScannerPlatform.instance = scanner;
    service = _SharedVideo();
  });

  tearDown(() async {
    MobileScannerPlatform.instance = previousPlatform;
    await scanner.captures.close();
    await service.dispose();
  });

  Future<void> mount(
    WidgetTester tester, {
    bool starting = false,
    ScreenShareMode mode = ScreenShareMode.sharing,
  }) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    service.chosenSource = starting
        ? VideoShareSource.screen
        : VideoShareSource.camera;
    service.state.value = ScreenShareState(mode: mode);
    final router = GoRouter(
      initialLocation: '/scan',
      routes: [
        GoRoute(
          path: '/scan',
          builder: (_, _) => DirectQrScannerScreen(
            controllerFactory: () {
              controllers++;
              return MobileScannerController(autoStart: false);
            },
            permissionCoordinator: PermissionRequestCoordinator(
              readStatus: (_) async {
                permissions++;
                if (permissionGate case final pending?) return pending.future;
                return PermissionStatus.granted;
              },
              requestPermission: (_) async => PermissionStatus.granted,
            ),
          ),
        ),
        GoRoute(
          path: '/camera',
          builder: (_, _) => const Scaffold(body: Text('camera-session-page')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          screenShareServiceProvider.overrideWithValue(service),
          cameraSessionProvider.overrideWith(() => _Session(busy: starting)),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: const [AppLocalizations.delegate],
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  for (final starting in [false, true]) {
    testWidgets(
      'QR does not create or start a scanner while camera ${starting ? 'starts' : 'streams'}',
      (tester) async {
        await mount(
          tester,
          starting: starting,
          mode: starting ? ScreenShareMode.idle : ScreenShareMode.sharing,
        );
        expect(find.text('Camera in use'), findsOneWidget);
        expect(find.byType(MobileScanner), findsNothing);
        expect(controllers, 0);
        expect(scanner.starts, 0);
        expect(permissions, 0);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(controllers, 0);
        expect(scanner.starts, 0);
        await tester.tap(find.text('Open Device camera'));
        await tester.pumpAndSettle();
        expect(find.text('camera-session-page'), findsOneWidget);
        expect(service.stops, 0);
        expect(scanner.disposals, 0);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('QR becomes available when camera capture ends', (tester) async {
    await mount(tester);
    expect(controllers, 0);
    service.state.value = const ScreenShareState(mode: ScreenShareMode.idle);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.byType(MobileScanner), findsOneWidget);
    expect(controllers, 1);
    expect(scanner.starts, 1);
    expect(permissions, 1);
    scanner.captures.add(
      const BarcodeCapture(barcodes: [Barcode(rawValue: 'invalid')]),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('This is not a valid BShare QR code'), findsOneWidget);
    expect(service.stops, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(scanner.disposals, 1);
  });

  testWidgets('watching a remote camera leaves local QR scanning available', (
    tester,
  ) async {
    await mount(tester, mode: ScreenShareMode.watching);
    expect(find.byType(MobileScanner), findsOneWidget);
    expect(controllers, 1);
    expect(scanner.starts, 1);
    expect(service.stops, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('late permission cannot start QR after camera sharing begins', (
    tester,
  ) async {
    permissionGate = Completer<PermissionStatus>();
    await mount(tester, mode: ScreenShareMode.idle);
    expect(controllers, 1);
    expect(scanner.starts, 0);
    service.state.value = const ScreenShareState(mode: ScreenShareMode.sharing);
    await tester.pump();
    expect(find.text('Camera in use'), findsOneWidget);
    permissionGate!.complete(PermissionStatus.granted);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(scanner.starts, 0);
    expect(scanner.disposals, 1);
    expect(service.stops, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
