import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/screens/send_files_screen.dart';
import 'package:bshare/src/presentation/screens/screen_share_screen.dart';
import 'package:bshare/src/infrastructure/services/android_screen_share_execution_service.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/network_service.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:bshare/src/presentation/widgets/discovery_status_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _delegates = <LocalizationsDelegate<dynamic>>[
  AppLocalizations.delegate,
  GlobalMaterialLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
];

Widget _card(
  ProviderContainer container, {
  int count = 0,
  bool reduceMotion = false,
}) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    locale: const Locale('es'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: _delegates,
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Scaffold(body: DiscoveryStatusCard(deviceCount: count)),
    ),
  ),
);

class _Discovery extends DiscoveryController {
  int starts = 0;
  int refreshes = 0;

  void forgetDevices() => state = const [];

  @override
  List<DeviceInfo> build() => [
    DeviceInfo(
      id: 'receiver',
      name: 'Mi computadora',
      platform: 'Linux',
      ip: '192.168.1.20',
      port: 53317,
      lastSeen: DateTime(2026),
    ),
  ];

  @override
  Future<void> start({bool advertise = false, String? ipOverride}) async {
    starts++;
  }

  @override
  Future<void> refresh() async {
    refreshes++;
    ref
        .read(discoveryStatusProvider.notifier)
        .set(const DiscoveryStatus(phase: DiscoveryPhase.searching));
  }
}

void main() {
  testWidgets(
    'Screen resumes discovery after capture cleanup and removes its listener',
    (tester) async {
      final discovery = _Discovery();
      final service = ScreenShareService(
        const AppLogger(),
        AndroidScreenShareExecutionService(),
      );
      final container = ProviderContainer(
        overrides: [
          discoveryProvider.overrideWith(() => discovery),
          screenShareServiceProvider.overrideWithValue(service),
          // The address card must not enumerate the host's interfaces in this
          // widget test of discovery resumption and listener cleanup.
          networkProvider.overrideWith(
            (_) async => const NetworkSnapshot(ip: '192.0.2.1'),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(service.dispose);
      final status = container.read(discoveryStatusProvider.notifier);
      status.set(const DiscoveryStatus(phase: DiscoveryPhase.listening));
      service.state.value = const ScreenShareState(
        mode: ScreenShareMode.sharing,
      );
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
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: _delegates,
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();
      expect(discovery.starts, 1);
      status.set(const DiscoveryStatus(phase: DiscoveryPhase.idle));
      service.state.value = const ScreenShareState(mode: ScreenShareMode.idle);
      await tester.pump();
      expect(discovery.starts, 2);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
      service.state.value = const ScreenShareState(
        mode: ScreenShareMode.idle,
        status: 'Detached',
      );
      expect(discovery.starts, 2);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
      service.state.value = const ScreenShareState(
        mode: ScreenShareMode.idle,
        status: 'Disposed screen',
      );
      expect(discovery.starts, 2);
    },
  );

  testWidgets('scan animates and stops when the finite scan finishes', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final status = container.read(discoveryStatusProvider.notifier);
    status.set(const DiscoveryStatus(phase: DiscoveryPhase.searching));
    await tester.pumpWidget(_card(container));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Buscando dispositivos cercanos'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isTrue);

    status.set(const DiscoveryStatus(phase: DiscoveryPhase.listening));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Aún no se encontraron dispositivos'), findsOneWidget);
    expect(find.textContaining('Abre Recibir'), findsOneWidget);
    expect(find.textContaining('Wi-Fi o Ethernet'), findsOneWidget);
    expect(find.textContaining('cada 3 segundos'), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('errors show recovery help without native error details', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(discoveryStatusProvider.notifier)
        .set(
          DiscoveryStatus(
            phase: DiscoveryPhase.error,
            error: StateError('native socket failure'),
          ),
        );
    await tester.pumpWidget(_card(container));
    expect(find.text('No se pudieron buscar dispositivos'), findsOneWidget);
    expect(
      find.textContaining('Revisa la conexión a la red local'),
      findsOneWidget,
    );
    expect(find.textContaining('Wi-Fi o Ethernet'), findsOneWidget);
    expect(find.textContaining('native socket'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('available counts use singular and plural messages', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(discoveryStatusProvider.notifier)
        .set(const DiscoveryStatus(phase: DiscoveryPhase.listening));
    await tester.pumpWidget(_card(container, count: 1));
    expect(find.text('1 dispositivo disponible'), findsOneWidget);
    await tester.pumpWidget(_card(container, count: 3));
    expect(find.text('3 dispositivos disponibles'), findsOneWidget);
  });

  testWidgets('reduced motion uses a static scan indicator', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(discoveryStatusProvider.notifier)
        .set(const DiscoveryStatus(phase: DiscoveryPhase.searching));
    await tester.pumpWidget(_card(container, reduceMotion: true));
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.byType(CircularProgressIndicator),
          )
          .value,
      0.75,
    );
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets(
    'Send starts once, retains devices and disables duplicate refresh',
    (tester) async {
      final discovery = _Discovery();
      final container = ProviderContainer(
        overrides: [discoveryProvider.overrideWith(() => discovery)],
      );
      addTearDown(container.dispose);
      container
          .read(discoveryStatusProvider.notifier)
          .set(const DiscoveryStatus(phase: DiscoveryPhase.searching));
      final router = GoRouter(
        initialLocation: '/send',
        routes: [
          GoRoute(path: '/send', builder: (_, _) => const SendFilesScreen()),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            locale: const Locale('es'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: _delegates,
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();
      expect(discovery.starts, 1);
      expect(find.text('Mi computadora'), findsOneWidget);
      final refresh = find.descendant(
        of: find.byTooltip('Actualizar dispositivos'),
        matching: find.byType(InkWell),
      );
      expect(tester.widget<InkWell>(refresh).onTap, isNull);
      container
          .read(discoveryStatusProvider.notifier)
          .set(const DiscoveryStatus(phase: DiscoveryPhase.listening));
      await tester.pump();
      expect(tester.widget<InkWell>(refresh).onTap, isNotNull);
      await tester.tap(refresh);
      await tester.pump();
      expect(discovery.refreshes, 1);
      expect(find.text('Mi computadora'), findsOneWidget);
      expect(tester.widget<InkWell>(refresh).onTap, isNull);
      container
          .read(selectedDeviceProvider.notifier)
          .set(container.read(discoveryProvider).single);
      discovery.forgetDevices();
      container
          .read(discoveryStatusProvider.notifier)
          .set(const DiscoveryStatus(phase: DiscoveryPhase.listening));
      await tester.pumpAndSettle();
      expect(find.text('Mi computadora'), findsOneWidget);
      expect(find.text('Aún no se encontraron dispositivos'), findsOneWidget);
      expect(find.textContaining('Destino guardado'), findsOneWidget);
      expect(find.text('1 dispositivo disponible'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
