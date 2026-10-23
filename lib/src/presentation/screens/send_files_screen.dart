import 'dart:async';
import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:bshare/src/presentation/widgets/discovery_status_card.dart';
import 'package:bshare/src/presentation/widgets/formatters.dart';
import 'package:bshare/src/presentation/widgets/gradient_action_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class SendFilesScreen extends ConsumerStatefulWidget {
  const SendFilesScreen({super.key});

  @override
  ConsumerState<SendFilesScreen> createState() => _SendFilesScreenState();
}

class _SendFilesScreenState extends ConsumerState<SendFilesScreen> {
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

  Future<void> _sendAndOpenTransfers() async {
    await ref.read(sendControllerProvider).send();
    if (mounted) context.go('/transfers');
  }

  @override
  Widget build(BuildContext context) {
    final files = ref.watch(pickedFilesProvider);
    final outgoing = ref.watch(sendProgressProvider);
    final selectedPaths = files.map((file) => file.path).toSet();
    final isSelectedFileTransferring = outgoing.any(
      (progress) => !progress.isDone && selectedPaths.contains(progress.id),
    );
    final discoveredDevices = ref.watch(discoveryProvider);
    final discovery = ref.watch(discoveryStatusProvider);
    final selected = ref.watch(selectedDeviceProvider);
    final discoveredIds = discoveredDevices.map((device) => device.id).toSet();
    final devices = [...discoveredDevices];
    if (selected != null &&
        !devices.any((device) => device.id == selected.id)) {
      devices.insert(0, selected);
    }
    final isMobile = Platform.isAndroid || Platform.isIOS;
    final l10n = context.l10n;

    return AppShell(
      title: l10n.t('send'),
      scrollController: _scrollController,
      child: LayoutBuilder(
        builder: (context, outer) {
          final compact = outer.maxWidth < 420;
          return ListView(
            controller: _scrollController,
            padding: EdgeInsets.all(compact ? 8 : 16),
            children: [
              _PickActions(isMobile: isMobile),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.t('targetDevice'),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (Platform.isAndroid) ...[
                    GradientIconButton(
                      tooltip: l10n.t('scanDirectQr'),
                      onPressed: () => context.go('/send/scan'),
                      icon: Icons.qr_code_scanner_rounded,
                    ),
                    const SizedBox(width: 8),
                  ],
                  GradientIconButton(
                    tooltip: l10n.t('refreshDevices'),
                    onPressed: discovery.isSearching
                        ? null
                        : () => ref.read(discoveryProvider.notifier).refresh(),
                    icon: Icons.refresh_rounded,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              DiscoveryStatusCard(deviceCount: discoveredDevices.length),
              for (final device in devices)
                Card(
                  child: ListTile(
                    leading: const CircleAvatar(
                      child: Icon(Icons.devices_rounded),
                    ),
                    title: Text(device.name),
                    subtitle: Text(
                      '${device.platform} - ${device.ip}:${device.port}'
                      '${discoveredIds.contains(device.id) ? '' : '\n${l10n.t('savedDeviceNotDetected')}'}',
                    ),
                    trailing: Icon(
                      selected?.id == device.id
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      color: selected?.id == device.id
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    onTap: () =>
                        ref.read(selectedDeviceProvider.notifier).set(device),
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: GradientActionButton(
                      onPressed:
                          selected == null ||
                              files.isEmpty ||
                              isSelectedFileTransferring
                          ? null
                          : _sendAndOpenTransfers,
                      icon: Icons.send_rounded,
                      label: l10n.t('send'),
                      expand: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.t('files'),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  GradientIconButton(
                    tooltip: l10n.t('clearSelectedFiles'),
                    onPressed: files.isEmpty
                        ? null
                        : () => ref.read(sendControllerProvider).clearFiles(),
                    icon: Icons.clear_all_rounded,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (files.isEmpty)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.folder_open_rounded),
                    title: Text(l10n.t('noFilesSelected')),
                  ),
                )
              else
                for (final file in files)
                  Card(
                    child: ListTile(
                      dense: true,
                      leading: const Icon(Icons.insert_drive_file_rounded),
                      title: Text(
                        file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        file.relativePath == null
                            ? formatBytes(file.size)
                            : '${file.relativePath} - ${formatBytes(file.size)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: l10n.t('removeFile'),
                        onPressed: () => ref
                            .read(sendControllerProvider)
                            .removeFile(file.path),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

class _PickActions extends ConsumerWidget {
  const _PickActions({required this.isMobile});

  final bool isMobile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(sendControllerProvider);
    final l10n = context.l10n;
    final actions = isMobile
        ? [
            _PickAction(
              l10n.t('app'),
              Icons.apps_rounded,
              () => Platform.isAndroid
                  ? context.go('/send/apps')
                  : ref.read(sendControllerProvider).pickAppPackage(),
            ),
            _PickAction(
              l10n.t('file'),
              Icons.insert_drive_file_rounded,
              () => Platform.isAndroid
                  ? context.go('/send/storage-files')
                  : controller.pickFiles(),
            ),
            _PickAction(
              l10n.t('media'),
              Icons.perm_media_rounded,
              () => Platform.isAndroid || Platform.isIOS
                  ? context.go('/send/media')
                  : controller.pickMedia(),
            ),
            _PickAction(
              l10n.t('folder'),
              Icons.folder_rounded,
              () => Platform.isAndroid
                  ? context.go('/send/storage-folder')
                  : controller.pickFolder(),
            ),
          ]
        : [
            _PickAction(
              l10n.t('file'),
              Icons.insert_drive_file_rounded,
              controller.pickFiles,
            ),
            _PickAction(
              l10n.t('folder'),
              Icons.folder_rounded,
              controller.pickFolder,
            ),
          ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = isMobile
            ? constraints.maxWidth < 300
                  ? 2
                  : actions.length
            : constraints.maxWidth < 420
            ? 2
            : actions.length;
        const spacing = 8.0;
        final tileWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final action in actions)
              SizedBox(
                width: tileWidth,
                height: isMobile ? 64 : 72,
                child: _PickActionTile(action: action, compact: isMobile),
              ),
          ],
        );
      },
    );
  }
}

class _PickActionTile extends StatelessWidget {
  const _PickActionTile({required this.action, required this.compact});

  final _PickAction action;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer.withValues(alpha: 0.78),
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: action.onPressed,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 6 : 10,
            vertical: compact ? 7 : 9,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                action.icon,
                size: compact ? 22 : 24,
                color: scheme.onPrimaryContainer,
              ),
              const SizedBox(height: 5),
              Text(
                action.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                  fontSize: compact ? 12 : 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PickAction {
  const _PickAction(this.label, this.icon, this.onPressed);

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
}
