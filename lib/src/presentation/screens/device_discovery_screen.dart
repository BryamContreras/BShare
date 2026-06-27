import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DeviceDiscoveryScreen extends ConsumerStatefulWidget {
  const DeviceDiscoveryScreen({super.key});

  @override
  ConsumerState<DeviceDiscoveryScreen> createState() =>
      _DeviceDiscoveryScreenState();
}

class _DeviceDiscoveryScreenState extends ConsumerState<DeviceDiscoveryScreen> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(discoveryProvider.notifier).start());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(discoveryProvider);
    final l10n = context.l10n;
    return AppShell(
      title: l10n.t('devices'),
      scrollController: _scrollController,
      child: ListView(
        controller: _scrollController,
        padding: EdgeInsets.all(Platform.isAndroid ? 8 : 20),
        children: [
          Row(
            children: [
              Text(
                l10n.t('availableDevices'),
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              IconButton.filledTonal(
                tooltip: l10n.t('refresh'),
                onPressed: () => ref.read(discoveryProvider.notifier).refresh(),
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const LinearProgressIndicator(minHeight: 3),
          const SizedBox(height: 16),
          if (devices.isEmpty)
            const _EmptyDevices()
          else
            for (final device in devices)
              Card(
                child: ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.devices_rounded),
                  ),
                  title: Text(device.name),
                  subtitle: Text(
                    '${device.platform} - ${device.ip}:${device.port}',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () =>
                      ref.read(selectedDeviceProvider.notifier).set(device),
                ),
              ),
        ],
      ),
    );
  }
}

class _EmptyDevices extends StatelessWidget {
  const _EmptyDevices();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        children: [
          const Icon(Icons.radar_rounded, size: 48),
          const SizedBox(height: 12),
          Text(context.l10n.t('searchingLocalNetwork')),
        ],
      ),
    );
  }
}
