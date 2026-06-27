import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/widgets/action_card.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    Future.microtask(_requestInitialAndroidPermissions);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _requestInitialAndroidPermissions() async {
    if (!Platform.isAndroid) return;

    final location = await Permission.locationWhenInUse.status;
    if (location.isDenied || location.isRestricted) {
      await Permission.locationWhenInUse.request();
    }

    final notifications = await Permission.notification.status;
    if (notifications.isDenied || notifications.isRestricted) {
      await Permission.notification.request();
    }

    ref.invalidate(networkProvider);
  }

  @override
  Widget build(BuildContext context) {
    final network = ref.watch(networkProvider);
    final settings = ref.watch(settingsProvider);
    final l10n = context.l10n;
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
                        onTap: () {
                          ref.read(discoveryProvider.notifier).start();
                          context.go('/send');
                        },
                      ),
                      ActionCard(
                        title: l10n.t('receive'),
                        subtitle: l10n.t('receiveSubtitle'),
                        icon: Icons.download_for_offline_rounded,
                        onTap: () => context.go('/receive'),
                      ),
                      ActionCard(
                        title: l10n.t('screen'),
                        subtitle: l10n.t('screenSubtitle'),
                        icon: Icons.screen_share_rounded,
                        onTap: () {
                          ref.read(discoveryProvider.notifier).start();
                          context.go('/screen');
                        },
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
                    final columns = constraints.maxWidth < 980 ? 2 : 3;
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
