import 'dart:async';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/infrastructure/services/android_screen_share_execution_service.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:bshare/src/infrastructure/services/usb_adb_transport_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/screens/screen_share_screen.dart';
import 'package:bshare/src/presentation/screens/screen_viewer_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _phone = UsbAdbDevice(
  serial: 'usb-phone',
  label: 'Cable phone',
  state: UsbAdbDeviceState.authorized,
  transportId: 4,
);

class _Discovery extends DiscoveryController {
  @override
  List<DeviceInfo> build() => const [];
  @override
  Future<void> start({bool advertise = false, String? ipOverride}) async {}
}

class _Video extends ScreenShareService {
  _Video() : super(const AppLogger(), AndroidScreenShareExecutionService());
  int usbWatches = 0;
  int lanWatches = 0;
  int stops = 0;
  int? port;
  Completer<void>? connecting;
  bool fails = false;

  @override
  Future<void> watchUsb(
    UsbAdbDevice device, {
    VideoShareSource source = VideoShareSource.screen,
    int remotePort = 53317,
  }) async {
    expect(device.serial, _phone.serial);
    expect(source, VideoShareSource.screen);
    usbWatches++;
    port = remotePort;
    if (connecting != null) await connecting!.future;
    if (fails) throw const UsbAdbTransportException('adb-command-failed');
    state.value = const ScreenShareState(mode: ScreenShareMode.watching);
  }

  @override
  Future<void> watch(DeviceInfo device) async => lanWatches++;

  @override
  Future<void> stopWatching({String status = 'Idle'}) async {
    stops++;
    state.value = const ScreenShareState(mode: ScreenShareMode.idle);
  }
}

void main() {
  late _Video video;
  late ProviderContainer container;
  var devices = <UsbAdbDevice>[_phone];

  Future<void> mount(
    WidgetTester tester, {
    TargetPlatform platform = TargetPlatform.windows,
  }) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    devices = [_phone];
    video = _Video();
    container = ProviderContainer(
      overrides: [
        screenShareServiceProvider.overrideWithValue(video),
        discoveryProvider.overrideWith(_Discovery.new),
        usbAdbDevicesProvider.overrideWith((_) async => devices),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(video.dispose);
    container
        .read(discoveryStatusProvider.notifier)
        .set(const DiscoveryStatus(phase: DiscoveryPhase.listening));
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const ScreenShareScreen()),
      ],
    );
    addTearDown(router.dispose);
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

  Future<void> selectUsb(WidgetTester tester) async {
    await tester.tap(find.text('USB'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cable phone'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'desktop USB opens the existing ADB stream without a LAN connection',
    (tester) async {
      await mount(tester);
      await selectUsb(tester);
      expect(find.widgetWithText(FilledButton, 'Share screen'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('screen-usb-port')),
        '53320',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Watch'));
      await tester.pumpAndSettle();
      expect(video.usbWatches, 1);
      expect(video.port, 53320);
      expect(video.lanWatches, 0);
      expect(
        tester
            .widget<FocusedScreenViewer>(find.byType(FocusedScreenViewer))
            .device,
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(video.stops, 1);
    },
  );

  testWidgets(
    'device refresh invalidates selection when USB authorization is lost',
    (tester) async {
      await mount(tester);
      await selectUsb(tester);
      final watch = find.widgetWithText(OutlinedButton, 'Watch');
      expect(tester.widget<OutlinedButton>(watch).onPressed, isNotNull);
      devices = [
        const UsbAdbDevice(
          serial: 'usb-phone',
          label: 'Cable phone',
          state: UsbAdbDeviceState.unauthorized,
          transportId: 4,
        ),
      ];
      await tester.tap(find.byKey(const ValueKey('usb-device-refresh')));
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(watch).onPressed, isNull);
      expect(find.textContaining('allow USB debugging'), findsOneWidget);
      expect(video.usbWatches, 0);
    },
  );

  testWidgets(
    'a USB failure can retry without replacing the connection with LAN',
    (tester) async {
      await mount(tester);
      await selectUsb(tester);
      video.fails = true;
      await tester.tap(find.widgetWithText(OutlinedButton, 'Watch'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not connect over USB'), findsOneWidget);
      expect(find.byType(FocusedScreenViewer), findsNothing);
      video.fails = false;
      await tester.tap(find.widgetWithText(OutlinedButton, 'Watch'));
      await tester.pumpAndSettle();
      expect(video.usbWatches, 2);
      expect(video.lanWatches, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'leaving an in-flight USB connection releases it after completion',
    (tester) async {
      await mount(tester);
      await selectUsb(tester);
      video.connecting = Completer<void>();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Watch'));
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Watch'),
            )
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      video.connecting!.complete();
      await tester.pumpAndSettle();
      expect(video.stops, 1);
      expect(video.state.value.mode, ScreenShareMode.idle);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('iOS explains Android-only USB and disables the USB segment', (
    tester,
  ) async {
    await mount(tester, platform: TargetPlatform.iOS);
    final selector = tester.widget<SegmentedButton>(
      find.byKey(const ValueKey('screen-connection')),
    );
    expect(selector.segments.last.enabled, isFalse);
    expect(find.textContaining('Android phone'), findsOneWidget);
  });
}
