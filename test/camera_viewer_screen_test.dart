import 'dart:async';
import 'dart:math' as math;

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/application/camera_media_provider.dart';
import 'package:bshare/src/domain/entities/camera_capture_controls.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/infrastructure/services/android_screen_share_execution_service.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/file_server.dart';
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

import 'support/fake_camera_media_service.dart';

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
  Object? controlError;
  Completer<void>? controlling;
  int remoteMicrophoneChanges = 0;
  int remoteSwitches = 0;
  int remoteStops = 0;
  bool? requestedMicrophone;
  final captureRequests = <MapEntry<String, Object>>[];
  CameraCaptureControls? confirmedCapture;
  String controlSession = 'viewer-1';
  bool deferCaptureRequests = false;
  final pendingCaptureRequests = <Completer<void>>[];
  int activeCaptureRequests = 0;
  int maximumCaptureRequests = 0;
  final previewChanges = <bool>[];
  bool previewFails = false;
  CameraCaptureControls Function(String name, Object value)? captureResponse;

  @override
  Future<void> setRemotePreviewEnabled(bool enabled) async {
    previewChanges.add(enabled);
    if (previewFails) throw StateError('private preview failure');
    remotePreviewEnabled.value = enabled;
  }

  @override
  String? get remoteCameraControlSessionId =>
      '$controlSession:${remoteCameraControls.value.capture.trackId}';

  Future<void> _captureChange(String name, Object value) async {
    captureRequests.add(MapEntry(name, value));
    final requestedSession = remoteCameraControlSessionId;
    final requestedCamera = remoteCameraControls.value.capture.cameraId;
    activeCaptureRequests++;
    maximumCaptureRequests = math.max(
      maximumCaptureRequests,
      activeCaptureRequests,
    );
    try {
      if (deferCaptureRequests) {
        final pending = Completer<void>();
        pendingCaptureRequests.add(pending);
        await pending.future;
      } else {
        await controlling?.future;
      }
      if (controlError case final error?) throw error;
      final capture = captureResponse?.call(name, value) ?? confirmedCapture;
      if (capture != null &&
          requestedSession == remoteCameraControlSessionId &&
          requestedCamera == remoteCameraControls.value.capture.cameraId) {
        remoteCameraControls.value = RemoteCameraControls(
          available: true,
          canSwitchCamera: true,
          capture: capture,
        );
      }
    } finally {
      activeCaptureRequests--;
    }
  }

  @override
  Future<void> setRemoteCameraZoom(double value) =>
      _captureChange('zoom', value);
  @override
  Future<void> setRemoteCameraWhiteBalance(String value) =>
      _captureChange('whiteBalance', value);
  @override
  Future<void> setRemoteCameraWhiteBalanceWarmth(double value) =>
      _captureChange('whiteBalanceWarmth', value);
  @override
  Future<void> setRemoteCameraExposure(double value) =>
      _captureChange('exposure', value);
  @override
  Future<void> setRemoteCameraBrightness(double value) =>
      _captureChange('brightness', value);
  @override
  Future<void> setRemoteCameraExposureMode(String value) =>
      _captureChange('exposureMode', value);
  @override
  Future<void> setRemoteCameraExposureTime(double value) =>
      _captureChange('exposureTimeMs', value);
  @override
  Future<void> setRemoteCameraIso(int value) => _captureChange('iso', value);
  @override
  Future<void> selectRemoteCamera(String value) =>
      _captureChange('cameraId', value);

  @override
  Future<void> setRemoteCameraMicrophoneEnabled(bool enabled) async {
    remoteMicrophoneChanges++;
    requestedMicrophone = enabled;
    await controlling?.future;
    if (controlError case final error?) throw error;
    remoteCameraControls.value = RemoteCameraControls(
      available: true,
      microphoneEnabled: enabled,
      canSwitchCamera: true,
    );
  }

  @override
  Future<void> switchRemoteCamera() async {
    remoteSwitches++;
    await controlling?.future;
    if (controlError case final error?) throw error;
  }

  @override
  Future<void> stopRemoteCameraSharing() async {
    remoteStops++;
    await controlling?.future;
    if (controlError case final error?) throw error;
    await stopWatching();
  }

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

CameraCaptureControls _capture({
  String cameraId = 'rear',
  double zoom = 1,
  double minimumZoom = .5,
  double maximumZoom = 10,
  String whiteBalance = 'auto',
  String exposureMode = 'auto',
  double shutter = 10,
  int iso = 100,
  bool independentBrightness = false,
  String? trackId,
  bool warmthSupported = false,
  String warmthMode = 'auto',
  double warmth = 0,
}) => CameraCaptureControls(
  available: true,
  cameraId: cameraId,
  trackId: trackId ?? 'track-$cameraId',
  zoom: CameraNumericControl(
    supported: true,
    min: minimumZoom,
    max: maximumZoom,
    step: .05,
    value: zoom,
  ),
  whiteBalance: CameraChoiceControl(
    supported: true,
    modes: const ['auto', 'daylight', 'cloudy-daylight'],
    value: whiteBalance,
  ),
  whiteBalanceWarmth: CameraWhiteBalanceWarmthControl(
    supported: warmthSupported,
    mode: warmthMode,
    value: warmth,
  ),
  exposure: const CameraNumericControl(
    supported: true,
    min: -2,
    max: 2,
    step: .5,
    value: 0,
  ),
  brightness: independentBrightness
      ? const CameraNumericControl(
          supported: true,
          min: 0,
          max: 255,
          step: 1,
          value: 128,
        )
      : const CameraNumericControl(),
  manualExposure: CameraManualExposureControl(
    supported: true,
    mode: exposureMode,
    timeMinMs: .1,
    timeMaxMs: 100,
    timeMs: shutter,
    isoMin: 100,
    isoMax: 1600,
    iso: iso,
  ),
  cameras: const [
    CameraControlDevice(id: 'rear', label: 'Rear wide', frontFacing: false),
    CameraControlDevice(
      id: 'tele',
      label: 'Rear telephoto',
      frontFacing: false,
    ),
    CameraControlDevice(id: 'front', label: 'Front camera', frontFacing: true),
  ],
);

void main() {
  Future<void> mount(
    WidgetTester tester,
    _CameraVideo video, {
    DeviceInfo? device,
    List<String>? allowedLocalIps,
    Future<void> Function()? onClose,
    Locale locale = const Locale('en'),
    TargetPlatform platform = TargetPlatform.android,
    TextScaler? textScaler,
    FakeCameraMediaService? media,
    bool disableAnimations = false,
  }) async {
    final localMedia = media ?? FakeCameraMediaService(source: video);
    addTearDown(() async {
      final closing = localMedia.dispose();
      await tester.pump();
      await closing;
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          screenShareServiceProvider.overrideWithValue(video),
          cameraMediaServiceProvider.overrideWithValue(localMedia),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: platform),
          builder: textScaler == null && !disableAnimations
              ? null
              : (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: textScaler,
                    disableAnimations: disableAnimations,
                  ),
                  child: child!,
                ),
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

  testWidgets('desktop controls stay to the right without covering video', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final video = _CameraVideo();
    addTearDown(video.dispose);
    video.remoteCameraControls.value = const RemoteCameraControls(
      available: true,
      canSwitchCamera: true,
    );
    await mount(
      tester,
      video,
      device: _phone,
      platform: TargetPlatform.windows,
    );
    final panel = find.byKey(const ValueKey('camera-viewer-menu'));
    final image = find.byKey(const ValueKey('camera-viewer-video'));
    expect(tester.getRect(image).right, tester.getRect(panel).left);
    expect(
      tester
          .getRect(panel)
          .contains(
            tester.getCenter(
              find.byKey(const ValueKey('camera-viewer-microphone')),
            ),
          ),
      isTrue,
    );
    expect(find.byKey(const ValueKey('camera-viewer-stop')), findsNothing);
    expect(find.textContaining('Windows Virtual Camera'), findsNothing);
    await tester.pump(const Duration(seconds: 10));
    expect(panel, findsOneWidget);
    expect(
      find.byKey(const ValueKey('camera-viewer-stop-sharing')),
      findsOneWidget,
    );
    expect(video.watches, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('desktop microphone follows confirmed phone state', (
    tester,
  ) async {
    final video = _CameraVideo()..controlling = Completer<void>();
    addTearDown(video.dispose);
    video.remoteCameraControls.value = const RemoteCameraControls(
      available: true,
      canSwitchCamera: true,
    );
    await mount(
      tester,
      video,
      device: _phone,
      platform: TargetPlatform.windows,
    );
    final microphone = find.byKey(const ValueKey('camera-viewer-microphone'));
    await tester.tap(microphone);
    await tester.pump();
    expect(video.remoteMicrophoneChanges, 1);
    expect(video.requestedMicrophone, isTrue);
    expect(tester.widget<SwitchListTile>(microphone).value, isFalse);
    expect(tester.widget<SwitchListTile>(microphone).onChanged, isNull);
    video.controlling!.complete();
    await tester.pump();
    expect(tester.widget<SwitchListTile>(microphone).value, isTrue);
    video.remoteCameraControls.value = const RemoteCameraControls(
      available: true,
      microphoneEnabled: false,
      canSwitchCamera: true,
    );
    await tester.pump();
    expect(tester.widget<SwitchListTile>(microphone).value, isFalse);
    await tester.tap(find.byKey(const ValueKey('camera-viewer-switch')));
    await tester.pump();
    expect(video.remoteSwitches, 1);
    expect(video.stops, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'desktop mirror flips only the image without controlling the phone',
    (tester) async {
      final video = _CameraVideo();
      addTearDown(video.dispose);
      video.remoteCameraControls.value = RemoteCameraControls(
        available: true,
        canSwitchCamera: true,
        capture: _capture(),
      );
      await mount(
        tester,
        video,
        device: _phone,
        platform: TargetPlatform.windows,
        locale: const Locale('es'),
      );
      final mirror = find.byKey(const ValueKey('camera-viewer-mirror'));
      final transform = find.byKey(
        const ValueKey('camera-viewer-video-mirror'),
      );
      final switchCamera = find.byKey(const ValueKey('camera-viewer-switch'));
      final zoom = find.byKey(const ValueKey('camera-viewer-zoom'));
      expect(
        tester.getTopLeft(switchCamera).dy,
        lessThan(tester.getTopLeft(mirror).dy),
      );
      expect(
        tester.getBottomLeft(mirror).dy,
        lessThan(tester.getTopLeft(zoom).dy),
      );
      expect(find.text('Espejo'), findsOneWidget);
      expect(
        find.byTooltip('Voltear horizontalmente la vista'),
        findsOneWidget,
      );
      expect(tester.widget<Transform>(transform).transform.entry(0, 0), 1);
      final videoRect = tester.getRect(
        find.byKey(const ValueKey('camera-viewer-video')),
      );
      final menuRect = tester.getRect(
        find.byKey(const ValueKey('camera-viewer-menu')),
      );
      await tester.tap(mirror);
      await tester.pump();
      expect(tester.widget<SwitchListTile>(mirror).value, isTrue);
      expect(tester.widget<Transform>(transform).transform.entry(0, 0), -1);
      expect(tester.widget<Transform>(transform).transform.entry(1, 1), 1);
      expect(
        find.descendant(
          of: transform,
          matching: find.byType(OrientationAwareVideoView),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: transform,
          matching: find.byKey(const ValueKey('camera-viewer-menu')),
        ),
        findsNothing,
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('camera-viewer-video'))),
        videoRect,
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('camera-viewer-menu'))),
        menuRect,
      );
      expect(video.captureRequests, isEmpty);
      expect(video.remoteSwitches, 0);
      expect(video.watches, 1);
      await tester.tap(mirror);
      await tester.pump();
      expect(tester.widget<Transform>(transform).transform.entry(0, 0), 1);
      expect(video.captureRequests, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'desktop shows a localized control failure without ending video',
    (tester) async {
      final video = _CameraVideo()
        ..controlError = StateError('private native error');
      addTearDown(video.dispose);
      video.remoteCameraControls.value = const RemoteCameraControls(
        available: true,
        canSwitchCamera: true,
      );
      await mount(
        tester,
        video,
        device: _phone,
        platform: TargetPlatform.windows,
        locale: const Locale('es'),
      );
      await tester.tap(find.byKey(const ValueKey('camera-viewer-microphone')));
      await tester.pump();
      expect(
        find.textContaining('Revisa el permiso de micrófono'),
        findsOneWidget,
      );
      expect(find.textContaining('private native error'), findsNothing);
      expect(video.state.value.mode, ScreenShareMode.watching);
      expect(video.stops, 0);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('camera-viewer-microphone')),
            )
            .value,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('desktop remote stop ends sharing once and returns', (
    tester,
  ) async {
    final video = _CameraVideo();
    addTearDown(video.dispose);
    video.remoteCameraControls.value = const RemoteCameraControls(
      available: true,
      canSwitchCamera: true,
    );
    var returned = 0;
    await mount(
      tester,
      video,
      device: _phone,
      platform: TargetPlatform.windows,
      onClose: () async => returned++,
    );
    await tester.tap(find.byKey(const ValueKey('camera-viewer-stop-sharing')));
    await tester.pump();
    await tester.pump();
    expect(video.remoteStops, 1);
    expect(video.stops, 1);
    expect(returned, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(video.stops, 1);
  });

  testWidgets('desktop explains when phone microphone permission is needed', (
    tester,
  ) async {
    final video = _CameraVideo()
      ..controlError = const CameraControlException(
        'camera-microphone-permission-denied',
      );
    addTearDown(video.dispose);
    video.remoteCameraControls.value = const RemoteCameraControls(
      available: true,
      canSwitchCamera: true,
    );
    await mount(
      tester,
      video,
      device: _phone,
      platform: TargetPlatform.windows,
      locale: const Locale('es'),
    );
    await tester.tap(find.byKey(const ValueKey('camera-viewer-microphone')));
    await tester.pump();
    expect(
      find.textContaining('Activa el micrófono una vez en el teléfono'),
      findsOneWidget,
    );
    expect(video.stops, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('desktop closing viewer leaves phone transmission running', (
    tester,
  ) async {
    final video = _CameraVideo();
    addTearDown(video.dispose);
    video.remoteCameraControls.value = const RemoteCameraControls(
      available: true,
      canSwitchCamera: true,
    );
    await mount(
      tester,
      video,
      device: _phone,
      platform: TargetPlatform.windows,
    );
    await tester.tap(find.byKey(const ValueKey('camera-viewer-close')));
    await tester.pump();
    expect(video.remoteStops, 0);
    expect(video.stops, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('desktop controls disable for old phone and after disconnect', (
    tester,
  ) async {
    final video = _CameraVideo();
    addTearDown(video.dispose);
    await mount(
      tester,
      video,
      device: _phone,
      platform: TargetPlatform.windows,
    );
    expect(find.textContaining('Update BShare on the phone'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('camera-viewer-microphone')),
          )
          .onChanged,
      isNull,
    );
    video.remoteCameraControls.value = const RemoteCameraControls(
      available: true,
      canSwitchCamera: true,
    );
    video.state.value = const ScreenShareState(mode: ScreenShareMode.idle);
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('camera-viewer-stop-sharing')),
          )
          .onPressed,
      isNull,
    );
    expect(find.text('Camera transmission ended'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'switch camera is the first camera action and zoom uses reported range',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final video = _CameraVideo()
        ..controlling = Completer<void>()
        ..captureResponse = (name, value) => _capture(zoom: value as double);
      addTearDown(video.dispose);
      video.remoteCameraControls.value = RemoteCameraControls(
        available: true,
        canSwitchCamera: true,
        capture: _capture(),
      );
      await mount(
        tester,
        video,
        device: _phone,
        platform: TargetPlatform.windows,
      );
      final switchCamera = find.byKey(const ValueKey('camera-viewer-switch'));
      final zoomFinder = find.byKey(const ValueKey('camera-viewer-zoom'));
      expect(
        tester.getTopLeft(switchCamera).dy,
        lessThan(tester.getTopLeft(zoomFinder).dy),
      );
      expect(
        tester.getTopLeft(switchCamera).dy,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(const ValueKey('camera-viewer-microphone')),
              )
              .dy,
        ),
      );
      var slider = tester.widget<Slider>(zoomFinder);
      expect(slider.min, .5);
      expect(slider.max, 10);
      expect(slider.value, 1);
      slider.onChanged!(2.13);
      await tester.pump();
      expect(video.captureRequests.length, 1);
      expect(video.captureRequests.single.value, closeTo(2.15, .00001));
      slider = tester.widget<Slider>(zoomFinder);
      expect(slider.value, closeTo(2.15, .00001));
      slider.onChangeEnd!(2.23);
      await tester.pump();
      expect(video.captureRequests.length, 1);
      expect(video.captureRequests.single.key, 'zoom');
      expect(tester.widget<Slider>(zoomFinder).value, closeTo(2.25, .00001));
      expect(tester.widget<Slider>(zoomFinder).onChanged, isNotNull);
      video.controlling!.complete();
      await tester.pump();
      expect(video.captureRequests.length, 2);
      expect(video.captureRequests.last.value, closeTo(2.25, .00001));
      expect(tester.widget<Slider>(zoomFinder).value, 2.25);
      video.remoteCameraControls.value = RemoteCameraControls(
        available: true,
        canSwitchCamera: true,
        capture: _capture(cameraId: 'tele', minimumZoom: 1, maximumZoom: 4),
      );
      await tester.pump();
      expect(tester.widget<Slider>(zoomFinder).min, 1);
      expect(tester.widget<Slider>(zoomFinder).max, 4);
      expect(tester.widget<Slider>(zoomFinder).value, 1);
      expect(video.captureRequests.length, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'live zoom throttles drag traffic and flushes only the latest value',
    (tester) async {
      final video = _CameraVideo()
        ..captureResponse = (name, value) => _capture(zoom: value as double);
      addTearDown(video.dispose);
      video.remoteCameraControls.value = RemoteCameraControls(
        available: true,
        canSwitchCamera: true,
        capture: _capture(),
      );
      await mount(
        tester,
        video,
        device: _phone,
        platform: TargetPlatform.windows,
      );
      final finder = find.byKey(const ValueKey('camera-viewer-zoom'));
      tester.widget<Slider>(finder).onChanged!(2);
      await tester.pump();
      expect(video.captureRequests.map((request) => request.value), [2]);
      tester.widget<Slider>(finder).onChanged!(3);
      tester.widget<Slider>(finder).onChanged!(4);
      tester.widget<Slider>(finder).onChanged!(5);
      await tester.pump();
      expect(video.captureRequests.length, 1);
      expect(tester.widget<Slider>(finder).value, 5);
      await tester.pump(const Duration(milliseconds: 119));
      expect(video.captureRequests.length, 1);
      await tester.pump(const Duration(milliseconds: 1));
      expect(video.captureRequests.map((request) => request.value), [2, 5]);
      tester.widget<Slider>(finder).onChanged!(6);
      tester.widget<Slider>(finder).onChanged!(7);
      tester.widget<Slider>(finder).onChanged!(8);
      tester.widget<Slider>(finder).onChangeEnd!(8);
      await tester.pump();
      expect(video.captureRequests.map((request) => request.value), [2, 5, 8]);
      expect(video.maximumCaptureRequests, 1);
      expect(tester.widget<Slider>(finder).value, 8);
      await tester.pump(const Duration(seconds: 1));
      expect(video.captureRequests.length, 3);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('live zoom discards pending drafts on viewer or lens changes', (
    tester,
  ) async {
    final video = _CameraVideo()
      ..deferCaptureRequests = true
      ..captureResponse = (name, value) => _capture(zoom: value as double);
    addTearDown(video.dispose);
    video.remoteCameraControls.value = RemoteCameraControls(
      available: true,
      canSwitchCamera: true,
      capture: _capture(),
    );
    await mount(
      tester,
      video,
      device: _phone,
      platform: TargetPlatform.windows,
    );
    final finder = find.byKey(const ValueKey('camera-viewer-zoom'));
    var oldSlider = tester.widget<Slider>(finder);
    oldSlider.onChanged!(2);
    await tester.pump();
    tester.widget<Slider>(finder).onChanged!(5);
    video.controlSession = 'viewer-2';
    video.remoteCameraControls.value = RemoteCameraControls(
      available: true,
      canSwitchCamera: true,
      capture: _capture(trackId: 'rear-new-session'),
    );
    await tester.pump();
    oldSlider.onChangeEnd!(6);
    video.pendingCaptureRequests[0].complete();
    await tester.pump();
    expect(video.captureRequests.map((request) => request.value), [2]);
    expect(tester.widget<Slider>(finder).value, 1);
    video.captureResponse = (name, value) =>
        _capture(zoom: value as double, trackId: 'rear-new-session');
    tester.widget<Slider>(finder).onChanged!(3);
    await tester.pump();
    tester.widget<Slider>(finder).onChangeEnd!(3);
    video.pendingCaptureRequests[1].complete();
    await tester.pump();
    expect(tester.widget<Slider>(finder).value, 3);
    oldSlider = tester.widget<Slider>(finder);
    oldSlider.onChanged!(3.5);
    await tester.pump();
    tester.widget<Slider>(finder).onChanged!(4);
    video.remoteCameraControls.value = RemoteCameraControls(
      available: true,
      canSwitchCamera: true,
      capture: _capture(cameraId: 'tele', minimumZoom: 1, maximumZoom: 4),
    );
    await tester.pump();
    oldSlider.onChangeEnd!(4);
    video.pendingCaptureRequests[2].complete();
    await tester.pump(const Duration(seconds: 1));
    expect(video.captureRequests.map((request) => request.value), [2, 3, 3.5]);
    expect(video.maximumCaptureRequests, 1);
    expect(tester.widget<Slider>(finder).min, 1);
    expect(tester.widget<Slider>(finder).max, 4);
    expect(tester.widget<Slider>(finder).value, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('live zoom can recover after a failed native request', (
    tester,
  ) async {
    final video = _CameraVideo()
      ..controlError = StateError('private camera failure');
    addTearDown(video.dispose);
    video.remoteCameraControls.value = RemoteCameraControls(
      available: true,
      canSwitchCamera: true,
      capture: _capture(),
    );
    await mount(
      tester,
      video,
      device: _phone,
      platform: TargetPlatform.windows,
    );
    final finder = find.byKey(const ValueKey('camera-viewer-zoom'));
    tester.widget<Slider>(finder).onChanged!(2);
    await tester.pump();
    tester.widget<Slider>(finder).onChangeEnd!(2);
    await tester.pump();
    expect(tester.widget<Slider>(finder).value, 1);
    expect(tester.widget<Slider>(finder).onChanged, isNotNull);
    expect(
      find.text('Could not adjust the camera. Please try again.'),
      findsOneWidget,
    );
    expect(find.textContaining('private camera failure'), findsNothing);
    video.controlError = null;
    video.captureResponse = (name, value) => _capture(zoom: value as double);
    tester.widget<Slider>(finder).onChanged!(3);
    tester.widget<Slider>(finder).onChangeEnd!(3);
    await tester.pump();
    expect(tester.widget<Slider>(finder).value, 3);
    expect(
      find.text('Could not adjust the camera. Please try again.'),
      findsNothing,
    );
    expect(video.maximumCaptureRequests, 1);
    expect(video.state.value.mode, ScreenShareMode.watching);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'white balance warmth is live, serial and stable when auto becomes manual',
    (tester) async {
      final video = _CameraVideo()
        ..deferCaptureRequests = true
        ..captureResponse = (name, value) => name == 'whiteBalanceWarmth'
            ? _capture(
                warmthSupported: true,
                warmthMode: 'manual',
                warmth: value as double,
                whiteBalance: 'off',
              )
            : _capture(warmthSupported: true);
      addTearDown(video.dispose);
      video.remoteCameraControls.value = RemoteCameraControls(
        available: true,
        canSwitchCamera: true,
        capture: _capture(warmthSupported: true),
      );
      await mount(
        tester,
        video,
        device: _phone,
        platform: TargetPlatform.windows,
      );
      final warmthFinder = find.byKey(
        const ValueKey('camera-viewer-white-balance-warmth'),
      );
      final autoFinder = find.byKey(
        const ValueKey('camera-viewer-white-balance-auto'),
      );
      expect(
        find.byKey(const ValueKey('camera-viewer-white-balance')),
        findsNothing,
      );
      expect(find.text('Cool'), findsOneWidget);
      expect(find.text('Warm'), findsOneWidget);
      expect(find.textContaining('Kelvin'), findsNothing);
      expect(tester.widget<SwitchListTile>(autoFinder).value, isTrue);
      tester.widget<Slider>(warmthFinder).onChanged!(.4);
      await tester.pump();
      expect(video.captureRequests.single.key, 'whiteBalanceWarmth');
      expect(video.captureRequests.single.value, .4);
      expect(tester.widget<Slider>(warmthFinder).onChanged, isNotNull);
      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('camera-viewer-zoom')))
            .onChanged,
        isNull,
      );
      tester.widget<Slider>(warmthFinder).onChanged!(-.7);
      tester.widget<Slider>(warmthFinder).onChangeEnd!(-.7);
      video.pendingCaptureRequests[0].complete();
      await tester.pump();
      expect(video.captureRequests.length, 2);
      expect(video.captureRequests.last.value, -.7);
      expect(tester.widget<SwitchListTile>(autoFinder).value, isFalse);
      expect(tester.widget<Slider>(warmthFinder).value, -.7);
      video.pendingCaptureRequests[1].complete();
      await tester.pump();
      expect(tester.widget<Slider>(warmthFinder).value, -.7);
      tester.widget<SwitchListTile>(autoFinder).onChanged!(true);
      await tester.pump();
      expect(video.captureRequests.last.key, 'whiteBalance');
      expect(video.captureRequests.last.value, 'auto');
      video.pendingCaptureRequests[2].complete();
      await tester.pump();
      expect(tester.widget<SwitchListTile>(autoFinder).value, isTrue);
      expect(tester.widget<Slider>(warmthFinder).value, 0);
      expect(video.maximumCaptureRequests, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'lens selector contains only advertised cameras on the current side',
    (tester) async {
      final video = _CameraVideo();
      addTearDown(video.dispose);
      video.remoteCameraControls.value = RemoteCameraControls(
        available: true,
        canSwitchCamera: true,
        capture: _capture(),
      );
      await mount(
        tester,
        video,
        device: _phone,
        platform: TargetPlatform.windows,
      );
      final finder = find.byKey(const ValueKey('camera-viewer-lens'));
      final lens = tester.widget<DropdownButton<String>>(finder);
      expect(lens.value, 'rear');
      expect(lens.items!.map((item) => item.value), ['rear', 'tele']);
      lens.onChanged!('tele');
      await tester.pump();
      expect(video.captureRequests.single.key, 'cameraId');
      expect(video.captureRequests.single.value, 'tele');
      expect(tester.widget<DropdownButton<String>>(finder).value, 'rear');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'white balance waits for the phone and keeps its value on failure',
    (tester) async {
      final video = _CameraVideo()
        ..controlling = Completer<void>()
        ..controlError = StateError('private driver message');
      addTearDown(video.dispose);
      video.remoteCameraControls.value = RemoteCameraControls(
        available: true,
        canSwitchCamera: true,
        capture: _capture(),
      );
      await mount(
        tester,
        video,
        device: _phone,
        platform: TargetPlatform.windows,
        locale: const Locale('es'),
      );
      final finder = find.byKey(const ValueKey('camera-viewer-white-balance'));
      final field = tester.widget<DropdownButton<String>>(finder);
      expect(field.items!.map((item) => item.value), [
        'auto',
        'daylight',
        'cloudy-daylight',
      ]);
      field.onChanged!('daylight');
      await tester.pump();
      expect(video.captureRequests.single.key, 'whiteBalance');
      expect(tester.widget<DropdownButton<String>>(finder).value, 'auto');
      expect(tester.widget<DropdownButton<String>>(finder).onChanged, isNull);
      video.controlling!.complete();
      await tester.pump();
      expect(tester.widget<DropdownButton<String>>(finder).value, 'auto');
      expect(
        find.text('No se pudo ajustar la cámara. Inténtalo de nuevo.'),
        findsOneWidget,
      );
      expect(find.textContaining('private driver message'), findsNothing);
      expect(video.state.value.mode, ScreenShareMode.watching);
      expect(video.stops, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'manual exposure exposes real shutter and ISO and disables EV compensation',
    (tester) async {
      final video = _CameraVideo();
      addTearDown(video.dispose);
      video.remoteCameraControls.value = RemoteCameraControls(
        available: true,
        canSwitchCamera: true,
        capture: _capture(),
      );
      await mount(
        tester,
        video,
        device: _phone,
        platform: TargetPlatform.windows,
      );
      final exposure = find.byKey(
        const ValueKey('camera-viewer-exposure-mode'),
      );
      expect(tester.widget<DropdownButton<String>>(exposure).value, 'auto');
      expect(find.byKey(const ValueKey('camera-viewer-shutter')), findsNothing);
      final brightness = find.byKey(const ValueKey('camera-viewer-brightness'));
      expect(find.text('Brightness (EV compensation)'), findsOneWidget);
      tester.widget<Slider>(brightness).onChangeEnd!(1.2);
      await tester.pump();
      expect(video.captureRequests.single.key, 'exposure');
      expect(video.captureRequests.single.value, 1);
      video.confirmedCapture = _capture(exposureMode: 'manual');
      tester.widget<DropdownButton<String>>(exposure).onChanged!('manual');
      await tester.pump();
      expect(video.captureRequests.last.key, 'exposureMode');
      expect(video.captureRequests.last.value, 'manual');
      expect(tester.widget<Slider>(brightness).onChanged, isNull);
      final shutterFinder = find.byKey(const ValueKey('camera-viewer-shutter'));
      final shutter = tester.widget<Slider>(shutterFinder);
      expect(shutter.min, closeTo(math.log(.1), .00001));
      expect(shutter.max, closeTo(math.log(100), .00001));
      video.confirmedCapture = _capture(exposureMode: 'manual', shutter: 25);
      shutter.onChangeEnd!(math.log(25));
      await tester.pump();
      expect(video.captureRequests.last.key, 'exposureTimeMs');
      expect(video.captureRequests.last.value, closeTo(25, .00001));
      final isoFinder = find.byKey(const ValueKey('camera-viewer-iso'));
      expect(tester.widget<Slider>(isoFinder).min, 100);
      expect(tester.widget<Slider>(isoFinder).max, 1600);
      tester.widget<Slider>(isoFinder).onChangeEnd!(420.5);
      await tester.pump();
      expect(video.captureRequests.last.key, 'iso');
      expect(video.captureRequests.last.value, 421);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('independent device brightness uses its own native command', (
    tester,
  ) async {
    final video = _CameraVideo();
    addTearDown(video.dispose);
    video.remoteCameraControls.value = RemoteCameraControls(
      available: true,
      canSwitchCamera: true,
      capture: _capture(independentBrightness: true, exposureMode: 'manual'),
    );
    await mount(
      tester,
      video,
      device: _phone,
      platform: TargetPlatform.windows,
    );
    final field = tester.widget<Slider>(
      find.byKey(const ValueKey('camera-viewer-brightness')),
    );
    expect(field.min, 0);
    expect(field.max, 255);
    expect(field.onChanged, isNotNull);
    field.onChangeEnd!(180);
    await tester.pump();
    expect(video.captureRequests.single.key, 'brightness');
    expect(video.captureRequests.single.value, 180);
    expect(find.text('Brightness (EV compensation)'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'known unsupported camera adjustments do not become image controls',
    (tester) async {
      final video = _CameraVideo();
      addTearDown(video.dispose);
      video.remoteCameraControls.value = const RemoteCameraControls(
        available: true,
        canSwitchCamera: true,
        capture: CameraCaptureControls(
          available: true,
          cameraId: 'unsupported',
        ),
      );
      await mount(
        tester,
        video,
        device: _phone,
        platform: TargetPlatform.windows,
      );
      expect(find.byType(Slider), findsNothing);
      expect(
        find.text('This camera does not expose adjustable zoom.'),
        findsOneWidget,
      );
      expect(
        find.text('This camera does not expose white balance controls.'),
        findsOneWidget,
      );
      expect(
        find.text(
          'This camera does not expose manual shutter and ISO controls.',
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('camera-viewer-adjustments-unavailable')),
        findsNothing,
      );
      expect(video.captureRequests, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'full manual controls scroll in a short desktop with enlarged text',
    (tester) async {
      tester.view.physicalSize = const Size(600, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final video = _CameraVideo();
      addTearDown(video.dispose);
      video.remoteCameraControls.value = RemoteCameraControls(
        available: true,
        canSwitchCamera: true,
        torchAvailable: true,
        capture: _capture(exposureMode: 'manual'),
      );
      await mount(
        tester,
        video,
        device: _phone,
        platform: TargetPlatform.windows,
        textScaler: const TextScaler.linear(1.5),
      );
      final stop = find.byKey(const ValueKey('camera-viewer-stop-sharing'));
      expect(stop.hitTestable(), findsOneWidget);
      expect(tester.getRect(stop).bottom, lessThanOrEqualTo(360));
      await tester.drag(
        find.byKey(const ValueKey('camera-viewer-menu-scroll')),
        const Offset(0, -1400),
      );
      await tester.pump();
      expect(stop.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(video.captureRequests, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('short desktop menu scrolls while Stop remains reachable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 260);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final video = _CameraVideo();
    addTearDown(video.dispose);
    video.remoteCameraControls.value = const RemoteCameraControls(
      available: true,
      canSwitchCamera: true,
      torchAvailable: true,
    );
    await mount(
      tester,
      video,
      device: _phone,
      platform: TargetPlatform.windows,
    );
    final stop = find.byKey(const ValueKey('camera-viewer-stop-sharing'));
    expect(tester.getRect(stop).bottom, lessThanOrEqualTo(260));
    expect(stop.hitTestable(), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('camera-viewer-menu-scroll')),
      const Offset(0, -160),
    );
    await tester.pump();
    expect(stop.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'left preview hides only the renderer while local recording and snapshots continue',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final video = _CameraVideo();
      addTearDown(video.dispose);
      final media = FakeCameraMediaService(source: video);
      media.state.value = media.state.value.copyWith(recording: true);
      await mount(
        tester,
        video,
        device: _phone,
        platform: TargetPlatform.windows,
        media: media,
      );
      final left = tester.getRect(
        find.byKey(const ValueKey('camera-viewer-actions')),
      );
      final image = tester.getRect(
        find.byKey(const ValueKey('camera-viewer-video')),
      );
      final right = tester.getRect(
        find.byKey(const ValueKey('camera-viewer-menu')),
      );
      expect(left.right, image.left);
      expect(image.right, right.left);
      final preview = find.byKey(const ValueKey('camera-viewer-preview'));
      await tester.tap(preview);
      await tester.pump();
      expect(video.previewChanges, [false]);
      expect(find.byType(OrientationAwareVideoView), findsNothing);
      expect(
        find.byKey(const ValueKey('camera-viewer-preview-hidden')),
        findsOneWidget,
      );
      expect(media.state.value.recording, isTrue);
      await tester.tap(find.byKey(const ValueKey('camera-take-photo')));
      await tester.pump();
      expect(media.photos, 1);
      await tester.pump(const Duration(milliseconds: 70));
      expect(find.byKey(const ValueKey('camera-photo-flash')), findsNothing);
      expect(find.textContaining('photo-1.jpg'), findsOneWidget);
      expect(video.captureRequests, isEmpty);
      expect(video.remoteStops, 0);
      expect(video.stops, 0);
      expect(video.watches, 1);
      await tester.tap(preview);
      await tester.pump();
      expect(video.previewChanges, [false, true]);
      expect(
        tester
            .widget<OrientationAwareVideoView>(
              find.byType(OrientationAwareVideoView),
            )
            .renderer,
        same(video.remoteRenderer),
      );
      expect(video.watches, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'local recording confirms start and stop without blocking phone controls',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final video = _CameraVideo();
      addTearDown(video.dispose);
      video.remoteCameraControls.value = const RemoteCameraControls(
        available: true,
        canSwitchCamera: true,
      );
      final media = FakeCameraMediaService(source: video)
        ..action = Completer<void>();
      await mount(
        tester,
        video,
        device: _phone,
        platform: TargetPlatform.windows,
        media: media,
      );
      final record = find.byKey(const ValueKey('camera-record-video'));
      await tester.tap(record);
      await tester.pump();
      expect(media.starts, 1);
      expect(find.text('Starting recording…'), findsOneWidget);
      expect(tester.widget<FilledButton>(record).onPressed, isNull);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('camera-viewer-microphone')),
            )
            .onChanged,
        isNotNull,
      );
      media.action!.complete();
      await tester.pump();
      media.state.value = media.state.value.copyWith(
        elapsed: const Duration(seconds: 70),
      );
      await tester.pump();
      expect(find.text('Stop recording'), findsOneWidget);
      expect(find.text('Recording · 01:10'), findsOneWidget);
      await tester.tap(record);
      await tester.pump();
      expect(media.stops, 1);
      expect(find.textContaining('video.mp4'), findsOneWidget);
      expect(video.state.value.mode, ScreenShareMode.watching);
      expect(video.remoteStops, 0);
      expect(video.captureRequests, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a local capture error is localized and a retry can save', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final video = _CameraVideo();
    addTearDown(video.dispose);
    final media = FakeCameraMediaService(source: video)..fail = true;
    await mount(
      tester,
      video,
      device: _phone,
      platform: TargetPlatform.windows,
      media: media,
      locale: const Locale('es'),
    );
    final photo = find.byKey(const ValueKey('camera-take-photo'));
    await tester.tap(photo);
    await tester.pump();
    expect(find.textContaining('No se pudo guardar la foto'), findsOneWidget);
    expect(find.textContaining('private'), findsNothing);
    await tester.pump(const Duration(milliseconds: 70));
    expect(find.byKey(const ValueKey('camera-photo-flash')), findsNothing);
    media.fail = false;
    await tester.tap(photo);
    await tester.pump();
    expect(media.photos, 2);
    expect(find.textContaining('photo-2.jpg'), findsOneWidget);
    expect(find.byKey(const ValueKey('camera-media-error')), findsNothing);
    expect(video.stops, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a saved photo briefly flashes only the active video preview', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final video = _CameraVideo();
    addTearDown(video.dispose);
    final media = FakeCameraMediaService(source: video)
      ..action = Completer<void>();
    await mount(
      tester,
      video,
      device: _phone,
      platform: TargetPlatform.windows,
      media: media,
    );
    final flash = find.byKey(const ValueKey('camera-photo-flash'));
    await tester.tap(find.byKey(const ValueKey('camera-take-photo')));
    await tester.pump(const Duration(milliseconds: 70));
    expect(flash, findsNothing);
    media.action!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    expect(flash, findsOneWidget);
    expect(tester.widget<ColoredBox>(flash).color.a, inExclusiveRange(0, .2));
    expect(
      tester.getRect(flash),
      tester.getRect(find.byKey(const ValueKey('camera-viewer-video'))),
    );
    expect(video.captureRequests, isEmpty);
    expect(video.stops, 0);
    await tester.pump(const Duration(milliseconds: 300));
    expect(flash, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('photo feedback respects reduced animation preferences', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final video = _CameraVideo();
    addTearDown(video.dispose);
    await mount(
      tester,
      video,
      device: _phone,
      platform: TargetPlatform.windows,
      disableAnimations: true,
    );
    await tester.tap(find.byKey(const ValueKey('camera-take-photo')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    expect(find.textContaining('photo-1.jpg'), findsOneWidget);
    expect(find.byKey(const ValueKey('camera-photo-flash')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a failed preview change preserves its confirmed switch and video',
    (tester) async {
      final video = _CameraVideo()..previewFails = true;
      addTearDown(video.dispose);
      await mount(
        tester,
        video,
        device: _phone,
        platform: TargetPlatform.windows,
      );
      final preview = find.byKey(const ValueKey('camera-viewer-preview'));
      await tester.tap(preview);
      await tester.pump();
      expect(tester.widget<SwitchListTile>(preview).value, isTrue);
      expect(find.byType(OrientationAwareVideoView), findsOneWidget);
      expect(
        find.textContaining('Could not change the preview'),
        findsOneWidget,
      );
      video.previewFails = false;
      await tester.tap(preview);
      await tester.pump();
      expect(tester.widget<SwitchListTile>(preview).value, isFalse);
      expect(find.byType(OrientationAwareVideoView), findsNothing);
      expect(video.watches, 1);
      expect(video.stops, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
