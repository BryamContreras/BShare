import 'dart:async';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/app_settings.dart';
import 'package:bshare/src/domain/entities/camera_capture_settings.dart';
import 'package:bshare/src/domain/entities/camera_connection_mode.dart';
import 'package:bshare/src/domain/entities/camera_device.dart';
import 'package:bshare/src/domain/entities/screen_capture_settings.dart';
import 'package:bshare/src/infrastructure/services/android_screen_share_execution_service.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/camera_display_service.dart';
import 'package:bshare/src/infrastructure/services/file_server.dart';
import 'package:bshare/src/infrastructure/services/network_service.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:bshare/src/infrastructure/services/usb_camera_network_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _rear = CameraDevice(id: 'rear-wide', label: 'Rear', frontFacing: false);
const _front = CameraDevice(id: 'front', label: 'Front', frontFacing: true);

class _Settings extends SettingsController {
  @override
  Future<AppSettings> build() async => const AppSettings(
    deviceId: 'receiver',
    deviceName: 'Receiver',
    downloadDirectory: '/tmp',
    autoAccept: true,
    preferredPort: 53317,
    themeMode: 'dark',
    languageCode: 'en',
    screenCapture: ScreenCaptureSettings(resolution: 1440, frameRate: 24),
    cameraCapture: CameraCaptureSettings(
      front: ScreenCaptureSettings(resolution: 480, frameRate: 15),
      back: ScreenCaptureSettings(resolution: 1080, frameRate: 30),
      devices: {
        'rear-wide': ScreenCaptureSettings(resolution: 720, frameRate: 60),
        'front': ScreenCaptureSettings(resolution: 1440, frameRate: 24),
      },
    ),
  );
}

class _Discovery extends DiscoveryController {
  final advertisements = <bool>[];
  @override
  Future<void> start({bool advertise = false, String? ipOverride}) async {
    advertisements.add(advertise);
  }

  @override
  Future<void> stop() async {}
}

class _Server extends FileServer {
  _Server() : super(const AppLogger());

  Completer<void>? gate;
  final entered = Completer<void>();
  var starts = 0;
  var stops = 0;

  @override
  Future<int> start({
    required int preferredPort,
    required String downloadDirectory,
    required bool autoAccept,
    required IncomingTransferHandler onIncoming,
    required TransferSavedHandler onSaved,
    required ReceiveProgressHandler onProgress,
    required ReceiveQueueHandler onQueue,
    required ReceiveControlResolver resolveControl,
  }) async {
    starts++;
    if (!entered.isCompleted) entered.complete();
    await gate?.future;
    return 53317;
  }

  @override
  Future<void> stop() async => stops++;
}

class _Screen extends ScreenShareService {
  _Screen({required super.onSharingStopped})
    : super(const AppLogger(), AndroidScreenShareExecutionService());

  Completer<void>? gate;
  Completer<void>? switchGate;
  final entered = Completer<void>();
  final switchEntered = Completer<void>();
  var starts = 0;
  var stops = 0;
  var switches = 0;
  var microphoneChanges = 0;
  var torchChanges = 0;
  var microphone = false;
  var torch = false;
  var controlGeneration = 0;
  Completer<void>? controlGate;
  final controlEntered = Completer<void>();
  Object? microphoneFailure;
  VideoShareSource testSource = VideoShareSource.screen;
  CameraDevice? camera;
  final profiles = <ScreenCaptureSettings>[];
  List<String>? localIps;
  List<String>? remoteSubnets;

  @override
  VideoShareSource get source => testSource;
  @override
  CameraDevice? get currentCamera => camera;
  @override
  bool get cameraMicrophoneEnabled => microphone;
  @override
  bool get cameraTorchEnabled => torch;
  @override
  bool get cameraTorchAvailable => camera?.frontFacing == false;

  @override
  Future<void> startCameraSharing(
    FileServer server, {
    required CameraDevice camera,
    ScreenCaptureSettings settings = const ScreenCaptureSettings(),
    List<String>? allowedLocalIps,
    List<String>? allowedRemoteSubnets,
  }) async {
    starts++;
    testSource = VideoShareSource.camera;
    this.camera = camera;
    profiles.add(settings);
    localIps = allowedLocalIps;
    remoteSubnets = allowedRemoteSubnets;
    if (!entered.isCompleted) entered.complete();
    await gate?.future;
    state.value = const ScreenShareState(mode: ScreenShareMode.sharing);
  }

  @override
  Future<void> switchCamera(
    CameraDevice camera, {
    required ScreenCaptureSettings settings,
  }) async {
    switches++;
    profiles.add(settings);
    if (!switchEntered.isCompleted) switchEntered.complete();
    await switchGate?.future;
    this.camera = camera;
    torch = false;
    state.value = const ScreenShareState(mode: ScreenShareMode.sharing);
  }

  @override
  Future<void> setCameraMicrophoneEnabled(bool enabled) async {
    microphoneChanges++;
    final generation = controlGeneration;
    if (!controlEntered.isCompleted) controlEntered.complete();
    await controlGate?.future;
    if (generation != controlGeneration) throw StateError('Stopped');
    if (microphoneFailure case final error?) throw error;
    microphone = enabled;
    state.value = const ScreenShareState(mode: ScreenShareMode.sharing);
  }

  @override
  Future<void> setCameraTorchEnabled(bool enabled) async {
    torchChanges++;
    torch = enabled;
    state.value = const ScreenShareState(mode: ScreenShareMode.sharing);
  }

  @override
  Future<void> stop(FileServer server, {String status = 'Idle'}) async {
    stops++;
    controlGeneration++;
    microphone = false;
    torch = false;
    camera = null;
    state.value = const ScreenShareState(mode: ScreenShareMode.idle);
    await onSharingStopped?.call();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Server server;
  late _Screen screen;
  late CameraDisplayService display;
  late _Discovery discovery;
  late ProviderContainer container;
  late List<Object?> usbAddresses;
  var networkReads = 0;

  setUp(() {
    server = _Server();
    discovery = _Discovery();
    usbAddresses = [];
    networkReads = 0;
    display = CameraDisplayService(applyState: (_, _) async {});
    screen = _Screen(
      onSharingStopped: () async {
        await display.stop();
        await container
            .read(receiveControllerProvider.notifier)
            .stopIfScreenShareOnly();
      },
    );
    container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        networkProvider.overrideWith((ref) async {
          networkReads++;
          return const NetworkSnapshot(ip: '127.0.0.1');
        }),
        fileServerProvider.overrideWithValue(server),
        discoveryProvider.overrideWith(() => discovery),
        screenShareServiceProvider.overrideWithValue(screen),
        cameraDisplayServiceProvider.overrideWithValue(display),
        usbCameraNetworkServiceProvider.overrideWithValue(
          UsbCameraNetworkService(readAddresses: () async => usbAddresses),
        ),
      ],
    );
  });

  tearDown(() async {
    if (server.gate?.isCompleted == false) server.gate!.complete();
    if (screen.gate?.isCompleted == false) screen.gate!.complete();
    if (screen.switchGate?.isCompleted == false) screen.switchGate!.complete();
    if (screen.controlGate?.isCompleted == false) {
      screen.controlGate!.complete();
    }
    await Future<void>.delayed(Duration.zero);
    await container.read(cameraSessionProvider.notifier).stop();
    await container.read(receiveControllerProvider.notifier).stop(force: true);
    await display.dispose();
    await screen.dispose();
    container.dispose();
  });

  test(
    'duplicate microphone requests share one operation and block camera switching',
    () async {
      final controller = container.read(cameraSessionProvider.notifier);
      await controller.start(
        connection: CameraConnectionMode.wifi,
        camera: _rear,
      );
      screen.controlGate = Completer<void>();
      final first = controller.setMicrophoneEnabled(true);
      final second = controller.setMicrophoneEnabled(true);
      expect(identical(first, second), isTrue);
      await screen.controlEntered.future;
      expect(container.read(cameraSessionProvider).busy, isTrue);
      await expectLater(controller.switchCamera(_front), throwsStateError);
      expect(screen.switches, 0);
      screen.controlGate!.complete();
      await first;
      expect(screen.microphoneChanges, 1);
      expect(screen.starts, 1);
      expect(container.read(cameraSessionProvider).microphoneEnabled, isTrue);
      expect(container.read(cameraSessionProvider).busy, isFalse);
      await controller.setTorchEnabled(true);
      expect(container.read(cameraSessionProvider).torchEnabled, isTrue);
      await controller.switchCamera(_front);
      final state = container.read(cameraSessionProvider);
      expect(state.microphoneEnabled, isTrue);
      expect(state.torchEnabled, isFalse);
      expect(state.torchAvailable, isFalse);
    },
  );

  test(
    'failed microphone request retains video and reports a localized error key',
    () async {
      final controller = container.read(cameraSessionProvider.notifier);
      await controller.start(
        connection: CameraConnectionMode.wifi,
        camera: _rear,
      );
      screen.microphoneFailure = StateError('Permission denied');
      await expectLater(
        controller.setMicrophoneEnabled(true),
        throwsStateError,
      );
      final state = container.read(cameraSessionProvider);
      expect(state.error, 'cameraMicrophoneFailed');
      expect(state.microphoneEnabled, isFalse);
      expect(state.busy, isFalse);
      expect(screen.state.value.mode, ScreenShareMode.sharing);
      expect(display.active, isTrue);
      expect(server.stops, 0);
    },
  );

  test(
    'stop waits for a pending control and prevents its late state from restoring capture',
    () async {
      final controller = container.read(cameraSessionProvider.notifier);
      await controller.start(
        connection: CameraConnectionMode.wifi,
        camera: _rear,
      );
      screen.controlGate = Completer<void>();
      final enabling = controller.setMicrophoneEnabled(true);
      final cancelled = expectLater(enabling, throwsStateError);
      await screen.controlEntered.future;
      final stopping = controller.stop();
      screen.controlGate!.complete();
      await cancelled;
      await stopping;
      final state = container.read(cameraSessionProvider);
      expect(state.microphoneEnabled, isFalse);
      expect(state.torchEnabled, isFalse);
      expect(state.busy, isFalse);
      expect(state.error, isNull);
      expect(screen.state.value.mode, ScreenShareMode.idle);
      expect(display.active, isFalse);
      expect(container.read(receiveControllerProvider).value!.visible, isFalse);
    },
  );

  test(
    'concurrent camera starts share one receiver, capture and display session',
    () async {
      final controller = container.read(cameraSessionProvider.notifier);
      screen.gate = Completer<void>();
      final first = controller.start(
        connection: CameraConnectionMode.wifi,
        camera: _rear,
      );
      final second = controller.start(
        connection: CameraConnectionMode.wifi,
        camera: _rear,
      );
      expect(identical(first, second), isTrue);
      await screen.entered.future;
      expect(server.starts, 1);
      expect(screen.starts, 1);
      expect(container.read(cameraSessionProvider).busy, isTrue);
      screen.gate!.complete();
      await Future.wait([first, second]);
      expect(display.active, isTrue);
      expect(container.read(cameraSessionProvider).busy, isFalse);
      await controller.stop();
      expect(display.active, isFalse);
      expect(container.read(receiveControllerProvider).value!.visible, isFalse);
    },
  );

  test(
    'stop during receiver startup cancels capture and releases owned receiver',
    () async {
      final controller = container.read(cameraSessionProvider.notifier);
      server.gate = Completer<void>();
      final starting = controller.start(
        connection: CameraConnectionMode.wifi,
        camera: _rear,
      );
      final cancelled = expectLater(starting, throwsStateError);
      await server.entered.future;
      final firstStop = controller.stop();
      final secondStop = controller.stop();
      expect(identical(firstStop, secondStop), isTrue);
      server.gate!.complete();
      await cancelled;
      await Future.wait([firstStop, secondStop]);
      expect(screen.starts, 0);
      expect(server.stops, 1);
      expect(display.active, isFalse);
      expect(container.read(receiveControllerProvider).value!.visible, isFalse);
      expect(container.read(cameraSessionProvider).busy, isFalse);
    },
  );

  test(
    'stop during native camera startup also cleans a late successful capture',
    () async {
      final controller = container.read(cameraSessionProvider.notifier);
      screen.gate = Completer<void>();
      final starting = controller.start(
        connection: CameraConnectionMode.wifi,
        camera: _rear,
      );
      final cancelled = expectLater(starting, throwsStateError);
      await screen.entered.future;
      final stopping = controller.stop();
      screen.gate!.complete();
      await cancelled;
      await stopping;
      expect(screen.state.value.mode, ScreenShareMode.idle);
      expect(display.active, isFalse);
      expect(container.read(receiveControllerProvider).value!.visible, isFalse);
    },
  );

  test(
    'capture and switching use front and rear profiles instead of legacy lens overrides',
    () async {
      final controller = container.read(cameraSessionProvider.notifier);
      await controller.start(
        connection: CameraConnectionMode.wifi,
        camera: _rear,
      );
      await controller.switchCamera(_front);
      expect(screen.profiles[0].resolution, 1080);
      expect(screen.profiles[0].frameRate, 30);
      expect(screen.profiles[1].resolution, 480);
      expect(screen.profiles[1].frameRate, 15);
      expect(screen.camera!.id, _front.id);
      expect(display.active, isTrue);
      expect(
        (await container.read(
          settingsProvider.future,
        )).screenCapture.resolution,
        1440,
      );
    },
  );

  test(
    'manual file receiver remains active when camera sharing stops',
    () async {
      final receiver = container.read(receiveControllerProvider.notifier);
      await container.read(receiveControllerProvider.future);
      await receiver.start();
      final controller = container.read(cameraSessionProvider.notifier);
      await controller.start(
        connection: CameraConnectionMode.wifi,
        camera: _rear,
      );
      await controller.stop();
      expect(server.starts, 1);
      expect(server.stops, 0);
      expect(container.read(receiveControllerProvider).value!.visible, isTrue);
      expect(display.active, isFalse);
    },
  );

  test(
    'USB with no wired link fails before receiver or Wi-Fi fallback starts',
    () async {
      final controller = container.read(cameraSessionProvider.notifier);
      await expectLater(
        controller.start(connection: CameraConnectionMode.usb, camera: _rear),
        throwsStateError,
      );
      expect(container.read(cameraSessionProvider).error, 'usbUnavailable');
      expect(server.starts, 0);
      expect(screen.starts, 0);
      expect(networkReads, 0);
      expect(display.active, isFalse);
    },
  );

  test(
    'USB passes exact interface IP and prefix without advertising over Wi-Fi',
    () async {
      usbAddresses = [
        {'ip': '192.168.42.129', 'prefixLength': 25, 'interfaceName': 'rndis0'},
      ];
      final controller = container.read(cameraSessionProvider.notifier);
      await controller.start(
        connection: CameraConnectionMode.usb,
        camera: _rear,
      );
      expect(screen.localIps, ['192.168.42.129']);
      expect(screen.remoteSubnets, ['192.168.42.129/25']);
      expect(networkReads, 0);
      expect(discovery.advertisements, isEmpty);
    },
  );

  test(
    'a repeated start never tears down an already active camera session',
    () async {
      final controller = container.read(cameraSessionProvider.notifier);
      await controller.start(
        connection: CameraConnectionMode.wifi,
        camera: _rear,
      );
      try {
        await controller.start(
          connection: CameraConnectionMode.wifi,
          camera: _rear,
        );
      } catch (_) {
        // A rejected duplicate is allowed; stopping the existing session is not.
      }
      expect(screen.starts, 1);
      expect(screen.stops, 0);
      expect(screen.state.value.mode, ScreenShareMode.sharing);
      expect(display.active, isTrue);
      expect(container.read(receiveControllerProvider).value!.visible, isTrue);
    },
  );

  test(
    'invalidating controller during receiver startup releases its claim',
    () async {
      final controller = container.read(cameraSessionProvider.notifier);
      server.gate = Completer<void>();
      final starting = controller.start(
        connection: CameraConnectionMode.wifi,
        camera: _rear,
      );
      final cancelled = expectLater(starting, throwsStateError);
      await server.entered.future;
      container.invalidate(cameraSessionProvider);
      container.read(cameraSessionProvider);
      await container.pump();
      server.gate!.complete();
      await cancelled;
      expect(screen.starts, 0);
      expect(container.read(receiveControllerProvider).value!.visible, isFalse);
      expect(server.stops, 1);
    },
  );
}
