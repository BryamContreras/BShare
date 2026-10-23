import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Describes the current scan without hiding devices already discovered.
class DiscoveryStatusCard extends ConsumerWidget {
  const DiscoveryStatusCard({super.key, required this.deviceCount});

  final int deviceCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(discoveryStatusProvider);
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final searching = status.isSearching;
    final failed = status.phase == DiscoveryPhase.error;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final title = switch (status.phase) {
      DiscoveryPhase.idle => l10n.t('discoveryPreparing'),
      DiscoveryPhase.searching => l10n.t('searchingNearbyDevices'),
      DiscoveryPhase.error => l10n.t('discoveryFailed'),
      DiscoveryPhase.listening when deviceCount == 0 => l10n.t(
        'discoveryEmpty',
      ),
      DiscoveryPhase.listening =>
        l10n
            .t(deviceCount == 1 ? 'discoveryFoundOne' : 'discoveryFoundMany')
            .replaceAll('{count}', '$deviceCount'),
    };

    return Semantics(
      liveRegion: true,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox.square(
                dimension: 28,
                child: searching
                    ? Padding(
                        padding: const EdgeInsets.all(3),
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          value: reduceMotion ? 0.75 : null,
                          semanticsLabel: title,
                        ),
                      )
                    : Icon(
                        failed
                            ? Icons.wifi_off_rounded
                            : deviceCount > 0
                            ? Icons.devices_rounded
                            : Icons.radar_rounded,
                        color: failed ? scheme.error : scheme.primary,
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: failed ? scheme.error : null,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.t(
                        failed
                            ? 'discoveryFailedHelp'
                            : 'discoveryAutomaticHelp',
                      ),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
