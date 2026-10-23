import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/domain/entities/receive_progress.dart';
import 'package:bshare/src/domain/entities/selected_transfer_file.dart';
import 'package:bshare/src/domain/entities/transfer_progress_status.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/navigation/app_navigation.dart';
import 'package:bshare/src/presentation/navigation/subtle_page_transitions.dart';
import 'package:bshare/src/presentation/screens/android_app_picker_screen.dart';
import 'package:bshare/src/presentation/screens/android_storage_picker_screen.dart';
import 'package:bshare/src/presentation/screens/camera_share_screen.dart';
import 'package:bshare/src/presentation/screens/camera_broadcast_screen.dart';
import 'package:bshare/src/presentation/screens/camera_viewer_screen.dart';
import 'package:bshare/src/presentation/screens/device_discovery_screen.dart';
import 'package:bshare/src/presentation/screens/direct_qr_scanner_screen.dart';
import 'package:bshare/src/presentation/screens/history_screen.dart';
import 'package:bshare/src/presentation/screens/home_screen.dart';
import 'package:bshare/src/presentation/screens/media_picker_screen.dart';
import 'package:bshare/src/presentation/screens/receive_screen.dart';
import 'package:bshare/src/presentation/screens/screen_share_screen.dart';
import 'package:bshare/src/presentation/screens/screen_viewer_screen.dart';
import 'package:bshare/src/presentation/screens/send_files_screen.dart';
import 'package:bshare/src/presentation/screens/settings_screen.dart';
import 'package:bshare/src/presentation/screens/transfers_screen.dart';
import 'package:bshare/src/presentation/widgets/camera_display_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

GoRouter _createRouter(DeviceInfo? initialViewerDevice) => GoRouter(
  initialLocation: initialViewerDevice == null ? '/' : '/screen/viewer',
  initialExtra: initialViewerDevice,
  routes: [
    GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
    GoRoute(
      path: '/discover',
      builder: (context, state) => const DeviceDiscoveryScreen(),
    ),
    GoRoute(
      path: '/send',
      builder: (context, state) => const SendFilesScreen(),
    ),
    GoRoute(
      path: '/send/apps',
      builder: (context, state) => const AndroidAppPickerScreen(),
    ),
    GoRoute(
      path: '/send/media',
      builder: (context, state) => const MediaPickerScreen(),
    ),
    GoRoute(
      path: '/send/scan',
      builder: (context, state) => const DirectQrScannerScreen(),
    ),
    GoRoute(
      path: '/send/storage-files',
      builder: (context, state) => const AndroidStoragePickerScreen(
        mode: AndroidStoragePickerMode.files,
      ),
    ),
    GoRoute(
      path: '/send/storage-folder',
      builder: (context, state) => const AndroidStoragePickerScreen(
        mode: AndroidStoragePickerMode.folder,
      ),
    ),
    GoRoute(
      path: '/receive',
      builder: (context, state) => const ReceiveScreen(),
    ),
    GoRoute(
      path: '/transfers',
      builder: (context, state) => const TransfersScreen(),
    ),
    GoRoute(
      path: '/screen',
      builder: (context, state) => const ScreenShareScreen(),
    ),
    GoRoute(
      path: '/camera',
      builder: (context, state) => const CameraShareScreen(),
    ),
    GoRoute(
      path: '/camera/live',
      builder: (context, state) => const CameraBroadcastScreen(),
    ),
    GoRoute(
      path: '/camera/viewer',
      builder: (context, state) => CameraViewerScreen(
        device: state.extra is DeviceInfo ? state.extra as DeviceInfo : null,
      ),
    ),
    GoRoute(
      path: '/screen/viewer',
      builder: (context, state) => ScreenViewerScreen(
        device: state.extra is DeviceInfo ? state.extra as DeviceInfo : null,
      ),
    ),
    GoRoute(
      path: '/history',
      builder: (context, state) => const HistoryScreen(),
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsScreen(),
    ),
  ],
);

class BShareApp extends ConsumerStatefulWidget {
  const BShareApp({super.key, this.initialViewerDevice});

  final DeviceInfo? initialViewerDevice;

  @override
  ConsumerState<BShareApp> createState() => _BShareAppState();
}

class _BShareAppState extends ConsumerState<BShareApp> {
  late final GoRouter _router;
  late final AppNavigation _navigation;
  StreamSubscription<List<SelectedTransferFile>>? _sharedFilesSubscription;

  @override
  void initState() {
    super.initState();
    _router = _createRouter(widget.initialViewerDevice);
    _navigation = AppNavigation(_router);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_listenForSharedFiles());
    });
    ref.listenManual(incomingTransfersProvider, (_, incoming) {
      if (incoming.isNotEmpty) _openTransfersForIncomingFile();
    });
    ref.listenManual(receiveProgressProvider, _handleReceiveProgress);
  }

  @override
  void dispose() {
    final sharedFilesSubscription = _sharedFilesSubscription;
    if (sharedFilesSubscription != null) {
      unawaited(sharedFilesSubscription.cancel());
    }
    _navigation.dispose();
    _router.dispose();
    super.dispose();
  }

  Future<void> _listenForSharedFiles() async {
    if (!mounted || _sharedFilesSubscription != null) return;
    final service = ref.read(androidShareServiceProvider);
    _sharedFilesSubscription = service.sharedFiles.listen(_openSharedFiles);
    try {
      final initialFiles = await service.takeInitialSharedFiles();
      if (initialFiles.isNotEmpty) _openSharedFiles(initialFiles);
    } catch (error) {
      if (mounted) {
        ref.read(loggerProvider).warn('Could not read shared files: $error');
      }
    }
  }

  void _openSharedFiles(List<SelectedTransferFile> files) {
    if (!mounted || files.isEmpty) return;
    ref.read(pickedFilesProvider.notifier).set(files);
    _router.go('/send');
  }

  void _handleReceiveProgress(
    List<ReceiveProgress>? previous,
    List<ReceiveProgress> current,
  ) {
    final knownIds = previous?.map((item) => item.id).toSet() ?? const {};
    final hasNewIncomingTransfer = current.any(
      (item) => !item.status.isTerminal && !knownIds.contains(item.id),
    );
    if (hasNewIncomingTransfer) _openTransfersForIncomingFile();
  }

  void _openTransfersForIncomingFile() {
    if (!mounted) return;
    _router.go('/transfers');
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider).value;
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final mode = switch (settings?.themeMode) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1389D8),
      brightness: Brightness.light,
    );
    final darkScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF52C7FF),
      brightness: Brightness.dark,
    );
    return MaterialApp.router(
      title: 'BShare',
      debugShowCheckedModeBanner: false,
      themeAnimationDuration: disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 140),
      themeAnimationCurve: Curves.easeOut,
      locale: Locale(settings?.languageCode ?? 'en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: ThemeData(
        pageTransitionsTheme: subtlePageTransitions,
        colorScheme: scheme.copyWith(
          surface: const Color(0xFFDCE7ED),
          surfaceContainerHighest: const Color(0xFFC9D8E0),
          surfaceContainer: const Color(0xFFD2E0E7),
          surfaceContainerLow: const Color(0xFFE1EBF0),
          primaryContainer: const Color(0xFFC5DDF0),
          secondaryContainer: const Color(0xFFD3E2EB),
          outlineVariant: const Color(0xFFB8CBD5),
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFD4E1E8),
        cardTheme: CardThemeData(
          elevation: 0,
          color: const Color(0xFFE2EBF0),
          shadowColor: const Color(0x241389D8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Color(0xFFBBCDD6)),
          ),
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          backgroundColor: Colors.transparent,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            backgroundColor: const Color(0xFFBFD8EA),
            foregroundColor: const Color(0xFF22323C),
            disabledBackgroundColor: const Color(0xFFB8C6CD),
            disabledForegroundColor: const Color(0xFF6E7C84),
          ),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            backgroundColor: const Color(0xFFC7DBE8),
            foregroundColor: const Color(0xFF263946),
            disabledBackgroundColor: const Color(0xFFB8C6CD),
            disabledForegroundColor: const Color(0xFF7A878E),
          ),
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Color(0xFFD9E6EC),
          indicatorColor: Color(0xFFBFD8EA),
        ),
        navigationRailTheme: const NavigationRailThemeData(
          backgroundColor: Color(0xFFD9E6EC),
          indicatorColor: Color(0xFFBFD8EA),
        ),
      ),
      darkTheme: ThemeData(
        pageTransitionsTheme: subtlePageTransitions,
        colorScheme: darkScheme.copyWith(
          surface: const Color(0xFF111A21),
          surfaceContainer: const Color(0xFF17222B),
          surfaceContainerLow: const Color(0xFF121C24),
          surfaceContainerHighest: const Color(0xFF22303A),
          primaryContainer: const Color(0xFF1B4058),
          secondaryContainer: const Color(0xFF223542),
          outlineVariant: const Color(0xFF344854),
          onSurface: const Color(0xFFE5EEF3),
          onSurfaceVariant: const Color(0xFFABC0CB),
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0E151B),
        cardTheme: CardThemeData(
          elevation: 0,
          color: const Color(0xFF151F27),
          shadowColor: Colors.black54,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Color(0xFF2C3F4B)),
          ),
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          backgroundColor: Colors.transparent,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            backgroundColor: const Color(0xFF1E4D69),
            foregroundColor: const Color(0xFFEAF6FC),
            disabledBackgroundColor: const Color(0xFF26343D),
            disabledForegroundColor: const Color(0xFF758A95),
          ),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            backgroundColor: const Color(0xFF203B4B),
            foregroundColor: const Color(0xFFE6F5FC),
            disabledBackgroundColor: const Color(0xFF24313A),
            disabledForegroundColor: const Color(0xFF748791),
          ),
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Color(0xFF101920),
          indicatorColor: Color(0xFF203B4B),
        ),
        navigationRailTheme: const NavigationRailThemeData(
          backgroundColor: Color(0xFF101920),
          indicatorColor: Color(0xFF203B4B),
        ),
      ),
      themeMode: mode,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: media.textScaler.clamp(
              minScaleFactor: 0.9,
              maxScaleFactor: 1.18,
            ),
          ),
          child: AppNavigationScope(
            navigation: _navigation,
            child: CameraDisplayOverlay(
              child: _RuntimeCleanupObserver(
                child: child ?? const SizedBox.shrink(),
              ),
            ),
          ),
        );
      },
      routerConfig: _router,
    );
  }
}

class _RuntimeCleanupObserver extends ConsumerStatefulWidget {
  const _RuntimeCleanupObserver({required this.child});

  final Widget child;

  @override
  ConsumerState<_RuntimeCleanupObserver> createState() =>
      _RuntimeCleanupObserverState();
}

class _RuntimeCleanupObserverState
    extends ConsumerState<_RuntimeCleanupObserver>
    with WidgetsBindingObserver {
  Future<void>? _cleanupFuture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(_cleanup());
    }
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    // Desktop engines request exit before destroying the window. A detached
    // notification comes too late to await peer, texture and transfer cleanup.
    await _cleanup();
    return AppExitResponse.exit;
  }

  Future<void> _cleanup() {
    // Keep the completed future as well: repeated close requests and the final
    // detached event belong to the same shutdown and must not start new work.
    return _cleanupFuture ??= _cleanupResources();
  }

  Future<void> _cleanupResources() async {
    final cleanup = ref.read(runtimeCleanupProvider);
    final logger = ref.read(loggerProvider);
    try {
      // RuntimeCleanup attempts every resource even if an individual stop fails.
      await cleanup.cleanupNetworking(cleanupSelectedFiles: true);
    } catch (error) {
      // Also handle an unexpected coordinator failure in the detached fallback.
      logger.warn('Could not finish application cleanup: $error');
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
