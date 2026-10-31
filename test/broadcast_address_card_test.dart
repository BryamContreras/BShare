import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/application/receive_controller.dart';
import 'package:bshare/src/infrastructure/services/network_service.dart';
import 'package:bshare/src/infrastructure/services/usb_camera_network_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/widgets/broadcast_address_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Receiver extends ReceiveController {
  _Receiver(this.initial);
  final ReceiveState initial;

  @override
  Future<ReceiveState> build() async => initial;
}

void main() {
  Future<ProviderContainer> mount(
    WidgetTester tester, {
    bool usb = false,
    bool overlay = false,
    double textScale = 1,
    ReceiveState receive = const ReceiveState(visible: true, port: 53319),
    Future<NetworkSnapshot> Function()? network,
    UsbCameraNetworkSnapshot wired = const UsbCameraNetworkSnapshot(),
  }) async {
    final container = ProviderContainer(
      overrides: [
        receiveControllerProvider.overrideWith(() => _Receiver(receive)),
        networkProvider.overrideWith(
          (_) =>
              network?.call() ??
              Future.value(const NetworkSnapshot(ip: '192.168.5.20')),
        ),
        usbCameraNetworkProvider.overrideWith((_) async => wired),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('es'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 288,
                child: BroadcastAddressCard(usb: usb, overlay: overlay),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('shows the bound port instead of the preferred default', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('IP y puerto'), findsOneWidget);
    expect(find.text('192.168.5.20:53319'), findsOneWidget);
    expect(find.textContaining('53317'), findsNothing);
  });

  testWidgets('copies the endpoint a viewer must enter', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = call.arguments['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await mount(tester);
    await tester.tap(find.byTooltip('Copiar IP y puerto'));
    await tester.pump();
    expect(copied, '192.168.5.20:53319');
    expect(find.text('Dirección copiada'), findsOneWidget);
  });

  testWidgets('updates the address after a network refresh', (tester) async {
    var ip = '192.168.5.20';
    final container = await mount(
      tester,
      network: () async => NetworkSnapshot(ip: ip),
    );
    ip = '192.168.5.21';
    container.invalidate(networkProvider);
    await tester.pumpAndSettle();
    expect(find.text('192.168.5.21:53319'), findsOneWidget);
    expect(find.text('192.168.5.20:53319'), findsNothing);
  });

  testWidgets(
    'lists eligible LAN addresses once and omits unbound address families',
    (tester) async {
      await mount(
        tester,
        network: () async => NetworkSnapshot(
          ip: '192.168.5.20',
          interfaces: [
            LanInterface(
              name: 'Ethernet',
              index: 1,
              addresses: [
                InternetAddress('192.168.5.20'),
                InternetAddress('fe80::1'),
              ],
            ),
            LanInterface(
              name: 'Wi-Fi',
              index: 2,
              addresses: [InternetAddress('192.168.6.20')],
            ),
          ],
        ),
      );
      expect(find.text('192.168.5.20:53319'), findsOneWidget);
      expect(find.text('192.168.6.20:53319'), findsOneWidget);
      expect(find.textContaining('fe80'), findsNothing);
    },
  );

  testWidgets('USB uses only its wired address', (tester) async {
    await mount(
      tester,
      usb: true,
      wired: const UsbCameraNetworkSnapshot(
        addresses: [
          UsbCameraAddress(
            ip: '192.168.42.129',
            prefixLength: 24,
            interfaceName: 'rndis0',
          ),
        ],
      ),
    );
    expect(find.text('192.168.42.129:53319'), findsOneWidget);
    expect(find.text('192.168.5.20:53319'), findsNothing);
  });

  testWidgets('missing USB does not substitute the Wi-Fi address', (
    tester,
  ) async {
    await mount(tester, usb: true);
    expect(
      find.text('No hay una dirección de transmisión disponible.'),
      findsOneWidget,
    );
    expect(find.text('192.168.5.20:53319'), findsNothing);
    expect(find.byIcon(Icons.copy_rounded), findsNothing);
  });

  testWidgets('a stopped receiver does not show a stale endpoint', (
    tester,
  ) async {
    await mount(
      tester,
      receive: const ReceiveState(visible: false, port: 53319),
    );
    expect(
      find.text('No hay una dirección de transmisión disponible.'),
      findsOneWidget,
    );
    expect(find.text('192.168.5.20:53319'), findsNothing);
  });

  testWidgets('overlay remains readable in a narrow layout with large text', (
    tester,
  ) async {
    await mount(tester, overlay: true, textScale: 3);
    expect(find.text('192.168.5.20:53319'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
