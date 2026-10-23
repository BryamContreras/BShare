import 'dart:async';

import 'package:bshare/src/infrastructure/services/permission_request_coordinator.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/screens/direct_qr_scanner_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

class _Camera extends MobileScannerPlatform {
  final captures = StreamController<BarcodeCapture?>.broadcast();
  int starts = 0;
  int stops = 0;
  int disposals = 0;
  Completer<void>? startGate;
  MobileScannerException? startError;

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
    await startGate?.future;
    if (startError case final error?) throw error;
    return const MobileScannerViewAttributes(
      cameraDirection: CameraFacing.back,
      currentTorchMode: TorchState.off,
      size: Size(640, 480),
      numberOfCameras: 1,
    );
  }

  @override
  Future<void> stop() async => stops++;
  @override
  Future<void> updateScanWindow(Rect? window) async {}
  @override
  Future<void> dispose() async => disposals++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  const l10n = AppLocalizations(Locale('en'));
  late _Camera camera;
  late MobileScannerPlatform originalPlatform;
  var permissionStatus = 1;

  setUp(() {
    originalPlatform = MobileScannerPlatform.instance;
    camera = _Camera();
    MobileScannerPlatform.instance = camera;
    permissionStatus = 1;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissions, (call) async {
          if (call.method == 'checkPermissionStatus') return permissionStatus;
          if (call.method == 'requestPermissions') return {1: permissionStatus};
          if (call.method == 'openAppSettings') return true;
          throw StateError('Unexpected permission method: ${call.method}');
        });
  });

  tearDown(() async {
    MobileScannerPlatform.instance = originalPlatform;
    await camera.captures.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissions, null);
  });

  Future<void> showScanner(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = GoRouter(
      initialLocation: '/scan',
      routes: [
        GoRoute(
          path: '/scan',
          builder: (_, _) => DirectQrScannerScreen(
            permissionCoordinator: PermissionRequestCoordinator(
              readStatus: (_) async =>
                  PermissionStatus.values[permissionStatus],
              requestPermission: (_) async =>
                  PermissionStatus.values[permissionStatus],
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
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

  Future<void> closeScanner(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets(
    'camera pauses in background, resumes once and disposes on exit',
    (tester) async {
      await showScanner(tester);
      expect(camera.starts, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(camera.stops, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(camera.starts, 2);
      await closeScanner(tester);
      expect(camera.stops, 2);
      expect(camera.disposals, 1);
      expect(camera.captures.hasListener, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'exiting while camera starts waits and releases the late camera',
    (tester) async {
      camera.startGate = Completer<void>();
      await showScanner(tester);
      expect(camera.starts, 1);
      await closeScanner(tester);
      expect(camera.disposals, 0);
      camera.startGate!.complete();
      await tester.pump();
      expect(camera.stops, 1);
      expect(camera.disposals, 1);
      expect(camera.captures.hasListener, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'denied camera permission offers settings and recovers on resume',
    (tester) async {
      permissionStatus = 4;
      await showScanner(tester);
      expect(camera.starts, 0);
      expect(find.text('Camera access needed'), findsOneWidget);
      expect(find.text(l10n.t('openAppSettings')), findsOneWidget);
      permissionStatus = 1;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(camera.starts, 1);
      await closeScanner(tester);
    },
  );

  testWidgets(
    'camera failures show a recovery action without raw native error',
    (tester) async {
      camera.startError = const MobileScannerException(
        errorCode: MobileScannerErrorCode.genericError,
        errorDetails: MobileScannerErrorDetails(message: 'Native internal NPE'),
      );
      await showScanner(tester);
      expect(find.text(l10n.t('cameraUnavailableTitle')), findsOneWidget);
      expect(find.textContaining('Native internal NPE'), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
      camera.startError = null;
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(camera.starts, 2);
      expect(find.text(l10n.t('cameraUnavailableTitle')), findsNothing);
      await closeScanner(tester);
      expect(camera.disposals, 2);
      expect(camera.captures.hasListener, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('malformed QR data reports an error and keeps scanning', (
    tester,
  ) async {
    await showScanner(tester);
    camera.captures.add(
      const BarcodeCapture(barcodes: [Barcode(rawValue: '[]')]),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('This is not a valid BShare QR code'), findsOneWidget);
    expect(camera.stops, 0);
    await closeScanner(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'valid QR wins over another code and duplicate detections are joined',
    (tester) async {
      const validInvite = '''{"type":"bshare.direct","version":1,
      "network":{"ssid":"BShare-test","password":"password123","securityType":"WPA2"},
      "device":{"id":"receiver","name":"Receiver","platform":"linux","ip":"192.168.49.1","port":53317}}''';
      const capture = BarcodeCapture(
        barcodes: [
          Barcode(rawValue: 'https://example.com'),
          Barcode(rawValue: validInvite),
        ],
      );
      await showScanner(tester);
      camera.captures.add(capture);
      camera.captures.add(capture);
      await tester.pump();
      await tester.pump();
      expect(find.text('This is not a valid BShare QR code'), findsNothing);
      expect(camera.stops, 1);
      // Host tests do not join Android Wi-Fi. They exercise the failed-join
      // recovery and then scan the same QR again, without duplicate suppression.
      expect(camera.starts, 2);
      camera.captures.add(capture);
      await tester.pump();
      await tester.pump();
      expect(camera.stops, 2);
      expect(camera.starts, 3);
      await closeScanner(tester);
      expect(camera.captures.hasListener, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
