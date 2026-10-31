import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/infrastructure/services/usb_adb_transport_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/widgets/usb_device_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const ready = UsbAdbDevice(
    serial: 'ready',
    label: 'Ready phone',
    state: UsbAdbDeviceState.authorized,
    transportId: 1,
  );
  const pending = UsbAdbDevice(
    serial: 'pending',
    label: 'Pending phone',
    state: UsbAdbDeviceState.unauthorized,
    transportId: 2,
  );
  const offline = UsbAdbDevice(
    serial: 'offline',
    label: 'Offline phone',
    state: UsbAdbDeviceState.offline,
    transportId: 3,
  );

  Future<void> mount(
    WidgetTester tester,
    ProviderContainer container, {
    required ValueChanged<UsbAdbDevice> onSelected,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(
            body: UsbDevicePicker(
              selectedSerial: 'ready',
              onSelected: onSelected,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('only authorized USB devices are selectable', (tester) async {
    final container = ProviderContainer(
      overrides: [
        usbAdbDevicesProvider.overrideWith(
          (_) async => [ready, pending, offline],
        ),
      ],
    );
    addTearDown(container.dispose);
    final selected = <String>[];
    await mount(
      tester,
      container,
      onSelected: (device) => selected.add(device.serial),
    );
    expect(
      tester
          .widget<ListTile>(find.byKey(const ValueKey('usb-device-pending')))
          .onTap,
      isNull,
    );
    expect(
      tester
          .widget<ListTile>(find.byKey(const ValueKey('usb-device-offline')))
          .onTap,
      isNull,
    );
    expect(
      tester
          .widget<ListTile>(find.byKey(const ValueKey('usb-device-ready')))
          .selected,
      isTrue,
    );
    expect(find.textContaining('allow USB debugging'), findsOneWidget);
    expect(find.textContaining('Reconnect the USB cable'), findsOneWidget);
    await tester.tap(find.text('Ready phone'));
    expect(selected, ['ready']);
  });

  testWidgets('missing ADB explains setup and refresh recovers with a device', (
    tester,
  ) async {
    var missing = true;
    var requests = 0;
    final container = ProviderContainer(
      overrides: [
        usbAdbDevicesProvider.overrideWith((_) async {
          requests++;
          if (missing) throw const UsbAdbTransportException('adb-not-found');
          return [ready];
        }),
      ],
    );
    addTearDown(container.dispose);
    await mount(tester, container, onSelected: (_) {});
    expect(find.textContaining('ADB was not found'), findsOneWidget);
    missing = false;
    await tester.tap(find.byKey(const ValueKey('usb-device-refresh')));
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(find.text('Ready phone'), findsOneWidget);
    expect(find.byKey(const ValueKey('usb-device-error')), findsNothing);
  });

  testWidgets('an empty USB list never asks for a network address', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [usbAdbDevicesProvider.overrideWith((_) async => [])],
    );
    addTearDown(container.dispose);
    await mount(tester, container, onSelected: (_) {});
    expect(find.byKey(const ValueKey('usb-device-empty')), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });
}
