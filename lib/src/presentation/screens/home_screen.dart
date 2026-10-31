import 'dart:async';
import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/infrastructure/services/permission_request_coordinator.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/localization/camera_localizations.dart';
import 'package:bshare/src/presentation/widgets/action_card.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key, this.permissionCoordinator});

  final PermissionRequestCoordinator? permissionCoordinator;

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _scrollController = ScrollController();
  late final _androidPlatformInfo = ref.read(androidPlatformInfoProvider);
  late final _permissionCoordinator =
      widget.permissionCoordinator ?? PermissionRequestCoordinator.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_requestInitialAndroidPermissions());
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _requestInitialAndroidPermissions() async {
    if (!mounted || !_androidPlatformInfo.isAndroid) return;
    try {
      final sdkInt = await _androidPlatformInfo.sdkInt();
      if (!mounted || sdkInt < 33) return;
      // LAN traffic and its IP address do not require location permission.
      // Request Wi-Fi access only from features that need it, and keep the
      // network snapshot independent of this notification-only dialog.
      await _permissionCoordinator.request(Permission.notification);
    } catch (error) {
      if (mounted) {
        ref
            .read(loggerProvider)
            .warn('Initial Android permissions failed: $error');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final network = ref.watch(networkProvider);
    final settings = ref.watch(settingsProvider);
    final l10n = context.l10n;
    final platform = Theme.of(context).platform;
    final mobile =
        platform == TargetPlatform.android || platform == TargetPlatform.iOS;
    return AppShell(
      scrollController: _scrollController,
      actions: [
        IconButton.filledTonal(
          tooltip: l10n.t('history'),
          onPressed: () => context.go('/history'),
          icon: const Icon(Icons.history_rounded),
        ),
        const SizedBox(width: 8),
      ],
      child: RefreshIndicator(
        onRefresh: () async => ref.invalidate(networkProvider),
        child: LayoutBuilder(
          builder: (context, outer) {
            final compact = outer.maxWidth < 420;
            final scheme = Theme.of(context).colorScheme;
            final padding = Platform.isAndroid
                ? 8.0
                : compact
                ? 12.0
                : 20.0;
            return ListView(
              controller: _scrollController,
              padding: EdgeInsets.all(padding),
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Color.lerp(
                          scheme.primaryContainer,
                          scheme.primary,
                          0.08,
                        )!,
                        Color.lerp(
                          scheme.primaryContainer,
                          scheme.secondaryContainer,
                          0.42,
                        )!,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                        color: scheme.primary.withValues(alpha: 0.12),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 680;
                      final info = Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          network.when(
                            data: (value) => Text(
                              value.isConnected
                                  ? l10n.t('connectedToLan')
                                  : l10n.t('noNetworkDetected'),
                              style: TextStyle(
                                color: scheme.onPrimaryContainer,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            loading: () => Text(
                              l10n.t('checkingLan'),
                              style: TextStyle(
                                color: scheme.onPrimaryContainer,
                                fontSize: 16,
                              ),
                            ),
                            error: (_, _) => Text(
                              l10n.t('networkUnavailable'),
                              style: TextStyle(
                                color: scheme.onPrimaryContainer,
                                fontSize: 16,
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            network.value?.wifiName ??
                                network.value?.ip ??
                                l10n.t('unknownNetwork'),
                            style: TextStyle(
                              color: scheme.onPrimaryContainer.withValues(
                                alpha: 0.86,
                              ),
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            settings.value?.deviceName ?? '',
                            style: TextStyle(
                              color: scheme.onPrimaryContainer.withValues(
                                alpha: 0.72,
                              ),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      );
                      final icon = Icon(
                        Icons.wifi_tethering_rounded,
                        color: scheme.onPrimaryContainer,
                        size: 54,
                      );
                      if (compact) {
                        return Row(
                          children: [
                            Expanded(child: info),
                            icon,
                          ],
                        );
                      }
                      return Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(child: info),
                          icon,
                        ],
                      );
                    },
                  ),
                ),
                SizedBox(height: compact ? 12 : 16),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final cards = [
                      ActionCard(
                        title: l10n.t('send'),
                        subtitle: l10n.t('sendSubtitle'),
                        icon: Icons.upload_file_rounded,
                        compactTypography: mobile,
                        onTap: () => context.go('/send'),
                      ),
                      ActionCard(
                        title: l10n.t('receive'),
                        subtitle: l10n.t('receiveSubtitle'),
                        icon: Icons.download_for_offline_rounded,
                        compactTypography: mobile,
                        onTap: () => context.go('/receive'),
                      ),
                      ActionCard(
                        title: l10n.t('shareScreen'),
                        subtitle: l10n.t('screenSubtitle'),
                        icon: Icons.screen_share_rounded,
                        compactTypography: mobile,
                        onTap: () => context.go('/screen'),
                      ),
                      ActionCard(
                        title: l10n.cameraText(
                          mobile ? 'deviceCamera' : 'viewDeviceCamera',
                        ),
                        subtitle: l10n.cameraText(
                          mobile ? 'deviceCameraHelp' : 'viewDeviceCameraHelp',
                        ),
                        icon: Icons.videocam_rounded,
                        compactTypography: mobile,
                        onTap: () => context.go('/camera'),
                      ),
                    ];
                    if (constraints.maxWidth < 720) {
                      return Column(
                        children: [
                          for (final card in cards) ...[
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: Platform.isAndroid
                                    ? 78
                                    : compact
                                    ? 86
                                    : 98,
                              ),
                              child: card,
                            ),
                            if (card != cards.last)
                              SizedBox(height: Platform.isAndroid ? 8 : 10),
                          ],
                        ],
                      );
                    }
                    const columns = 2;
                    final spacing = 16.0;
                    final cardWidth =
                        (constraints.maxWidth - spacing * (columns - 1)) /
                        columns;
                    return Wrap(
                      spacing: spacing,
                      runSpacing: spacing,
                      children: [
                        for (final card in cards)
                          SizedBox(
                            width: cardWidth,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(minHeight: 106),
                              child: card,
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
