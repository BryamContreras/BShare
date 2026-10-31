import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/application/receive_controller.dart';
import 'package:bshare/src/domain/entities/app_settings.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/domain/entities/screen_capture_settings.dart';
import 'package:bshare/src/infrastructure/services/android_platform_info_service.dart';
import 'package:bshare/src/infrastructure/services/android_screen_share_execution_service.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/file_server.dart';
import 'package:bshare/src/infrastructure/services/network_service.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/screens/screen_share_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _Settings extends SettingsController {
  @override
  Future<AppSettings> build() async => const AppSettings(
    deviceId: 'phone',
    deviceName: 'Phone',
    downloadDirectory: '/tmp',
    autoAccept: false,
    preferredPort: 53317,
    themeMode: 'system',
    languageCode: 'es',
  );
}

class _Discovery extends DiscoveryController {
  @override
  List<DeviceInfo> build() => const [];
  @override
  Future<void> start({bool advertise = false, String? ipOverride}) async {}
}

class _Receiver extends ReceiveController {
  bool? advertise;
  String? ipOverride;
  @override
  Future<ReceiveState> build() async => const ReceiveState(visible: false);
  @override
  Future<void> startForScreenShare() async {
    state = const AsyncData(ReceiveState(visible: true, port: 53319));
  }

  @override
  Future<void> startForVideoShare({
    String? ipOverride,
    bool advertise = true,
  }) async {
    this.ipOverride = ipOverride;
    this.advertise = advertise;
    state = const AsyncData(ReceiveState(visible: true, port: 53319));
  }
}

class _Video extends ScreenShareService {
  _Video(this.audioResult)
    : super(const AppLogger(), AndroidScreenShareExecutionService());
  final ScreenSystemAudioStatus audioResult;
  bool? requestedAudio;
  bool? requestedUsb;

  @override
  bool get usbOnly => requestedUsb ?? false;

  @override
  ScreenSystemAudioStatus get screenSystemAudioStatus =>
      requestedAudio == true ? audioResult : ScreenSystemAudioStatus.off;

  @override
  Future<void> startSharing(
    FileServer server, {
    ScreenCaptureSettings settings = const ScreenCaptureSettings(),
    bool includeSystemAudio = true,
    bool usbOnly = false,
  }) async {
    requestedAudio = includeSystemAudio;
    requestedUsb = usbOnly;
    state.value = const ScreenShareState(
      mode: ScreenShareMode.sharing,
      status: 'Sharing screen on LAN',
    );
  }
}

void main() {
  late _Receiver receiver;
  late GoRouter router;
  Future<_Video> mount(
    WidgetTester tester, {
    bool android = true,
    ScreenSystemAudioStatus result = ScreenSystemAudioStatus.active,
  }) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final video = _Video(result);
    receiver = _Receiver();
    final container = ProviderContainer(
      overrides: [
        screenShareServiceProvider.overrideWithValue(video),
        settingsProvider.overrideWith(_Settings.new),
        discoveryProvider.overrideWith(_Discovery.new),
        receiveControllerProvider.overrideWith(() => receiver),
        networkProvider.overrideWith(
          (_) async => const NetworkSnapshot(ip: '192.168.5.20'),
        ),
        androidPlatformInfoProvider.overrideWithValue(
          AndroidPlatformInfoService(isAndroid: android),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(video.dispose);
    router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const ScreenShareScreen()),
        GoRoute(
          path: '/other',
          builder: (_, _) => const Scaffold(body: Text('other')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: ThemeData(
            platform: android ? TargetPlatform.android : TargetPlatform.linux,
          ),
          locale: const Locale('es'),
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
    return video;
  }

  Future<void> share(WidgetTester tester) async {
    final button = find.widgetWithText(FilledButton, 'Compartir pantalla');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Android includes internal audio by default and shows the actual endpoint',
    (tester) async {
      final video = await mount(tester);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('screen-system-audio-toggle')),
            )
            .value,
        isTrue,
      );
      await share(tester);
      expect(video.requestedAudio, isTrue);
      expect(find.text('192.168.5.20:53319'), findsOneWidget);
      expect(find.text('Sonido interno activado'), findsOneWidget);
      expect(find.text('Compartir sonido del celular'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the audio option can be disabled before sharing', (
    tester,
  ) async {
    final video = await mount(tester);
    await tester.tap(find.byKey(const ValueKey('screen-system-audio-toggle')));
    await tester.pumpAndSettle();
    await share(tester);
    expect(video.requestedAudio, isFalse);
    expect(find.text('Sonido interno desactivado'), findsOneWidget);
  });

  testWidgets('Android screen USB binds loopback without LAN advertisement', (
    tester,
  ) async {
    final video = await mount(tester);
    await tester.tap(find.text('USB'));
    await tester.pumpAndSettle();
    expect(find.textContaining('depuración USB'), findsOneWidget);
    expect(find.text('Dispositivos disponibles'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'Ver'), findsNothing);
    await share(tester);
    expect(receiver.ipOverride, '127.0.0.1');
    expect(receiver.advertise, isFalse);
    expect(video.requestedUsb, isTrue);
    expect(video.requestedAudio, isTrue);
    expect(find.text('192.168.5.20:53319'), findsNothing);
    expect(
      find.byKey(const ValueKey('screen-usb-listening-port')),
      findsOneWidget,
    );
    expect(find.text('Puerto: 53319'), findsOneWidget);
  });

  testWidgets(
    'returning to an active USB broadcast retains its connection mode',
    (tester) async {
      final video = await mount(tester);
      await tester.tap(find.text('USB'));
      await tester.pumpAndSettle();
      await share(tester);
      router.go('/other');
      await tester.pumpAndSettle();
      router.go('/');
      await tester.pumpAndSettle();
      expect(video.requestedUsb, isTrue);
      expect(
        find.byKey(const ValueKey('screen-usb-listening-port')),
        findsOneWidget,
      );
      expect(find.text('192.168.5.20:53319'), findsNothing);
      expect(find.textContaining('depuración USB'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final entry in {
    ScreenSystemAudioStatus.permissionDenied:
        'No se concedió el permiso de audio',
    ScreenSystemAudioStatus.unsupported: 'Sonido interno no compatible',
    ScreenSystemAudioStatus.unavailable: 'No se pudo iniciar el sonido interno',
  }.entries) {
    testWidgets('video stays available when audio is ${entry.key.name}', (
      tester,
    ) async {
      final video = await mount(tester, result: entry.key);
      await share(tester);
      expect(video.state.value.mode, ScreenShareMode.sharing);
      expect(find.text(entry.value), findsOneWidget);
      expect(
        find.text('La pantalla continúa transmitiéndose sin sonido interno.'),
        findsOneWidget,
      );
      expect(find.text('192.168.5.20:53319'), findsOneWidget);
    });
  }

  testWidgets('other platforms do not request Android audio capture', (
    tester,
  ) async {
    final video = await mount(tester, android: false);
    expect(
      find.byKey(const ValueKey('screen-system-audio-toggle')),
      findsNothing,
    );
    await share(tester);
    expect(video.requestedAudio, isFalse);
    expect(find.text('192.168.5.20:53319'), findsOneWidget);
  });
}
