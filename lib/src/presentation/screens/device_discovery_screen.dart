import 'dart:async';
import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:bshare/src/presentation/widgets/discovery_status_card.dart';
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(discoveryProvider.notifier).start());
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(discoveryProvider);
    final discovery = ref.watch(discoveryStatusProvider);
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
              Expanded(
                child: Text(
                  l10n.t('availableDevices'),
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton.filledTonal(
                tooltip: l10n.t('refresh'),
                onPressed: discovery.isSearching
                    ? null
                    : () => ref.read(discoveryProvider.notifier).refresh(),
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DiscoveryStatusCard(deviceCount: devices.length),
          const SizedBox(height: 8),
          for (final device in devices)
            Card(
              child: ListTile(
                leading: const CircleAvatar(child: Icon(Icons.devices_rounded)),
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
