import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/direct_share_invite.dart';
import 'package:bshare/src/domain/entities/receive_progress.dart';
import 'package:bshare/src/domain/entities/transfer_progress_status.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:bshare/src/presentation/widgets/compact_transfer_buttons.dart';
import 'package:bshare/src/presentation/widgets/formatters.dart';
import 'package:bshare/src/presentation/widgets/gradient_action_button.dart';
import 'package:bshare/src/presentation/widgets/gradient_progress_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

class ReceiveScreen extends ConsumerStatefulWidget {
  const ReceiveScreen({super.key});

  @override
  ConsumerState<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends ConsumerState<ReceiveScreen> {
  final _scrollController = ScrollController();
  final _removingProgress = <String>{};
  Set<String> _knownProgressIds = <String>{};
  Set<String> _knownIncomingIds = <String>{};
  bool _autoScrollQueued = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _clearCompletedTransfers(List<ReceiveProgress> progress) async {
    final ids = progress
        .where((item) => item.status.isTerminal)
        .map((item) => item.id)
        .toList();
    if (ids.isEmpty || _removingProgress.isNotEmpty) return;
    setState(() => _removingProgress.addAll(ids));
    await Future<void>.delayed(const Duration(milliseconds: 190));
    if (!mounted) return;
    ref.read(receiveProgressProvider.notifier).clearCompleted();
    setState(() => _removingProgress.clear());
  }

  void _autoScrollForNewItems({
    required Set<String> progressIds,
    required Set<String> incomingIds,
  }) {
    final hasNewProgress = progressIds.difference(_knownProgressIds).isNotEmpty;
    final hasNewIncoming = incomingIds.difference(_knownIncomingIds).isNotEmpty;
    _knownProgressIds = progressIds;
    _knownIncomingIds = incomingIds;
    if (hasNewProgress || hasNewIncoming) {
      _scheduleAutoScrollDown();
    }
  }

  void _scheduleAutoScrollDown() {
    if (_autoScrollQueued) return;
    _autoScrollQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _autoScrollQueued = false;
      if (!_scrollController.hasClients) return;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!_scrollController.hasClients) return;
      await _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final receive = ref.watch(receiveControllerProvider);
    final incoming = ref.watch(incomingTransfersProvider);
    final progress = ref.watch(receiveProgressProvider);
    final controls = ref.watch(receiveTransferControlProvider);
    final settings = ref.watch(settingsProvider);
    final compact = MediaQuery.sizeOf(context).width < 420;
    final visible = receive.value?.visible == true;
    final directInvite = receive.value?.directInvite;
    final l10n = context.l10n;
    _autoScrollForNewItems(
      progressIds: progress.map((item) => item.id).toSet(),
      incomingIds: incoming.map((item) => item.id).toSet(),
    );
    return AppShell(
      title: l10n.t('receive'),
      scrollController: _scrollController,
      child: ListView(
        controller: _scrollController,
        padding: EdgeInsets.all(Platform.isAndroid ? 8 : 20),
        children: [
          Card(
            child: Padding(
              padding: EdgeInsets.all(Platform.isAndroid ? 12 : 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        receive.value?.visible == true
                            ? Icons.visibility_rounded
                            : Icons.visibility_off_rounded,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        receive.value?.visible == true
                            ? l10n.t('deviceVisible')
                            : l10n.t('receiverStopped'),
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${l10n.t('port')}: ${receive.value?.port ?? settings.value?.preferredPort ?? '-'}',
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${l10n.t('savingTo')}: ${settings.value?.downloadDirectory ?? '-'}',
                  ),
                  if (receive.value?.error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      receive.value!.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 10,
                    children: [
                      GradientActionButton(
                        onPressed: receive.isLoading || visible
                            ? null
                            : () => ref
                                  .read(receiveControllerProvider.notifier)
                                  .start(),
                        icon: Icons.power_settings_new_rounded,
                        label: l10n.t('startReceiver'),
                      ),
                      GradientActionButton(
                        onPressed: receive.isLoading || !visible
                            ? null
                            : () => ref
                                  .read(receiveControllerProvider.notifier)
                                  .stop(),
                        icon: Icons.stop_rounded,
                        label: l10n.t('stop'),
                      ),
                    ],
                  ),
                  if (directInvite != null) ...[
                    const SizedBox(height: 18),
                    _DirectInvitePanel(invite: directInvite, compact: compact),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.t('transferProgress'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              GradientIconButton(
                tooltip: l10n.t('clearCompletedTransfers'),
                onPressed: progress.any((item) => item.status.isTerminal)
                    ? () => _clearCompletedTransfers(progress)
                    : null,
                icon: Icons.cleaning_services_rounded,
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (progress.isEmpty)
            Card(
              child: ListTile(
                leading: const Icon(Icons.downloading_rounded),
                title: Text(l10n.t('noActiveTransfers')),
              ),
            )
          else
            for (final item in progress)
              _SlideAway(
                active: _removingProgress.contains(item.id),
                child: Card(
                  margin: EdgeInsets.symmetric(vertical: compact ? 3 : 4),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 10 : 12,
                      vertical: compact ? 8 : 12,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.downloading_rounded),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                item.fileName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (item.status == TransferProgressStatus.completed)
                              IconButton.filledTonal(
                                tooltip: l10n.t('openBShareFolder'),
                                onPressed: () async => ref
                                    .read(openPathServiceProvider)
                                    .open(
                                      settings.value?.downloadDirectory ??
                                          item.savedPath ??
                                          '',
                                    ),
                                icon: const Icon(Icons.folder_open_rounded),
                              ),
                          ],
                        ),
                        SizedBox(height: compact ? 7 : 10),
                        Row(
                          children: [
                            Expanded(
                              child: GradientProgressBar(value: item.fraction),
                            ),
                            if (item.status !=
                                TransferProgressStatus.completed) ...[
                              SizedBox(width: compact ? 5 : 6),
                              _ReceiveTransferActions(
                                id: item.id,
                                status: item.status,
                                isPaused: controls[item.id]?.isPaused == true,
                                compact: compact,
                              ),
                            ],
                          ],
                        ),
                        SizedBox(height: compact ? 6 : 8),
                        Text(
                          '${(item.fraction * 100).toStringAsFixed(0)}% - ${formatBytes(item.receivedBytes)} / ${formatBytes(item.totalBytes)} - ${formatBytes(item.bytesPerSecond)}/s - ${l10n.transferStatus(item.status, message: item.message)}',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          if (incoming.isNotEmpty) ...[
            const SizedBox(height: 20),
            for (final request in incoming)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        request.fileName,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${l10n.t('from')} ${request.senderName} - ${formatBytes(request.size)}',
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 10,
                        children: [
                          FilledButton.icon(
                            onPressed: () => ref
                                .read(incomingTransfersProvider.notifier)
                                .decide(request.id, true),
                            icon: const Icon(Icons.check_rounded),
                            label: Text(l10n.t('accept')),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => ref
                                .read(incomingTransfersProvider.notifier)
                                .decide(request.id, false),
                            icon: const Icon(Icons.close_rounded),
                            label: Text(l10n.t('reject')),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _DirectInvitePanel extends StatelessWidget {
  const _DirectInvitePanel({required this.invite, required this.compact});

  final DirectShareInvite invite;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final qrSize = compact ? 190.0 : 230.0;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: EdgeInsets.all(compact ? 12 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.qr_code_2_rounded),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.t('directNetworkReady'),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(l10n.t('scanToSendDirect')),
            const SizedBox(height: 14),
            Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: QrImageView(
                    data: invite.encode(),
                    version: QrVersions.auto,
                    size: qrSize,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            _InfoLine(
              icon: Icons.wifi_rounded,
              label: l10n.t('temporaryNetwork'),
              value: invite.credentials.ssid,
            ),
            if (invite.credentials.password.isNotEmpty)
              _InfoLine(
                icon: Icons.key_rounded,
                label: l10n.t('password'),
                value: invite.credentials.password,
              ),
          ],
        ),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(icon, size: 19),
          const SizedBox(width: 8),
          Text('$label: ', style: const TextStyle(fontWeight: FontWeight.w800)),
          Expanded(child: SelectableText(value, maxLines: 1)),
        ],
      ),
    );
  }
}

class _SlideAway extends StatelessWidget {
  const _SlideAway({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      offset: active ? const Offset(0.08, 0) : Offset.zero,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: active ? 0 : 1,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        child: child,
      ),
    );
  }
}

class _ReceiveTransferActions extends ConsumerWidget {
  const _ReceiveTransferActions({
    required this.id,
    required this.status,
    required this.isPaused,
    required this.compact,
  });

  final String id;
  final TransferProgressStatus status;
  final bool isPaused;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final done = status.isTerminal;
    if (done) return const SizedBox.shrink();

    final controller = ref.read(receiveControllerProvider.notifier);
    final canPause = status != TransferProgressStatus.queued;
    final size = compact ? 30.0 : 34.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canPause)
          Padding(
            padding: EdgeInsets.only(right: compact ? 2 : 4),
            child: CompactTransferButton(
              size: size,
              tooltip: isPaused ? l10n.t('resume') : l10n.t('pause'),
              onPressed: () =>
                  isPaused ? controller.resume(id) : controller.pause(id),
              icon: isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
            ),
          ),
        CompactTransferButton(
          size: size,
          tooltip: l10n.t('cancel'),
          onPressed: () => controller.cancel(id),
          icon: Icons.close_rounded,
        ),
      ],
    );
  }
}
