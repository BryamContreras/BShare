import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/incoming_transfer.dart';
import 'package:bshare/src/domain/entities/receive_progress.dart';
import 'package:bshare/src/domain/entities/send_progress.dart';
import 'package:bshare/src/domain/entities/transfer_progress_status.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:bshare/src/presentation/widgets/compact_transfer_buttons.dart';
import 'package:bshare/src/presentation/widgets/formatters.dart';
import 'package:bshare/src/presentation/widgets/gradient_action_button.dart';
import 'package:bshare/src/presentation/widgets/gradient_progress_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class TransfersScreen extends ConsumerWidget {
  const TransfersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final incoming = ref.watch(incomingTransfersProvider);
    final sent = ref.watch(sendProgressProvider);
    final received = ref.watch(receiveProgressProvider);
    final hasCompleted = [
      ...sent.map((item) => item.status),
      ...received.map((item) => item.status),
    ].any((status) => status.isTerminal);
    final l10n = context.l10n;

    return AppShell(
      title: l10n.t('transfers'),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 420;
          return ListView(
            padding: EdgeInsets.all(compact ? 8 : 16),
            children: [
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
                    onPressed: hasCompleted
                        ? () => _clearCompletedTransfers(ref)
                        : null,
                    icon: Icons.cleaning_services_rounded,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (incoming.isEmpty && sent.isEmpty && received.isEmpty)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.swap_horiz_rounded),
                    title: Text(l10n.t('noActiveTransfers')),
                  ),
                ),
              if (incoming.isNotEmpty) ...[
                _SectionTitle(label: l10n.t('pendingTransfers')),
                for (final request in incoming)
                  _IncomingTransferCard(request: request),
              ],
              if (sent.isNotEmpty) ...[
                _SectionTitle(label: l10n.t('outgoingTransfers')),
                for (final progress in sent)
                  _OutgoingTransferCard(progress: progress, compact: compact),
              ],
              if (received.isNotEmpty) ...[
                _SectionTitle(label: l10n.t('incomingTransfers')),
                for (final progress in received)
                  _IncomingTransferProgressCard(
                    progress: progress,
                    compact: compact,
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  void _clearCompletedTransfers(WidgetRef ref) {
    ref.read(sendProgressProvider.notifier).clearCompleted();
    ref.read(receiveProgressProvider.notifier).clearCompleted();
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _IncomingTransferCard extends ConsumerWidget {
  const _IncomingTransferCard({required this.request});

  final IncomingTransfer request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              request.fileName,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              '${l10n.t('from')} ${request.senderName} - ${formatBytes(request.size)}',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
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
    );
  }
}

class _OutgoingTransferCard extends ConsumerWidget {
  const _OutgoingTransferCard({required this.progress, required this.compact});

  final SendProgress progress;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final control = ref.watch(transferControlProvider)[progress.id];
    final size = compact ? 30.0 : 34.0;
    return Card(
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
                const Icon(Icons.upload_rounded),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    progress.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            SizedBox(height: compact ? 7 : 10),
            Row(
              children: [
                Expanded(child: GradientProgressBar(value: progress.fraction)),
                if (!progress.status.isTerminal && control != null) ...[
                  SizedBox(width: compact ? 5 : 6),
                  CompactTransferButton(
                    size: size,
                    tooltip: control.isPaused
                        ? l10n.t('resume')
                        : l10n.t('pause'),
                    onPressed: () {
                      final sender = ref.read(sendControllerProvider);
                      control.isPaused
                          ? sender.resume(progress.id)
                          : sender.pause(progress.id);
                    },
                    icon: control.isPaused
                        ? Icons.play_arrow_rounded
                        : Icons.pause_rounded,
                  ),
                  SizedBox(width: compact ? 2 : 4),
                  CompactTransferButton(
                    size: size,
                    tooltip: l10n.t('cancel'),
                    onPressed: () =>
                        ref.read(sendControllerProvider).cancel(progress.id),
                    icon: Icons.close_rounded,
                  ),
                ],
              ],
            ),
            SizedBox(height: compact ? 6 : 8),
            Text(
              '${(progress.fraction * 100).toStringAsFixed(0)}% - ${formatBytes(progress.sentBytes)} / ${formatBytes(progress.totalBytes)} - ${formatBytes(progress.bytesPerSecond)}/s - ${l10n.transferStatus(progress.status, message: progress.message)}',
            ),
          ],
        ),
      ),
    );
  }
}

class _IncomingTransferProgressCard extends ConsumerWidget {
  const _IncomingTransferProgressCard({
    required this.progress,
    required this.compact,
  });

  final ReceiveProgress progress;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final settings = ref.watch(settingsProvider).value;
    final control = ref.watch(receiveTransferControlProvider)[progress.id];
    final canPause = progress.status != TransferProgressStatus.queued;
    final size = compact ? 30.0 : 34.0;
    return Card(
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
                const Icon(Icons.download_rounded),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    progress.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (progress.status == TransferProgressStatus.completed)
                  IconButton.filledTonal(
                    tooltip: l10n.t('openBShareFolder'),
                    onPressed: () => ref
                        .read(openPathServiceProvider)
                        .open(
                          settings?.downloadDirectory ??
                              progress.savedPath ??
                              '',
                        ),
                    icon: const Icon(Icons.folder_open_rounded),
                  ),
              ],
            ),
            SizedBox(height: compact ? 7 : 10),
            Row(
              children: [
                Expanded(child: GradientProgressBar(value: progress.fraction)),
                if (!progress.status.isTerminal && control != null) ...[
                  SizedBox(width: compact ? 5 : 6),
                  if (canPause) ...[
                    CompactTransferButton(
                      size: size,
                      tooltip: control.isPaused
                          ? l10n.t('resume')
                          : l10n.t('pause'),
                      onPressed: () {
                        final receiver = ref.read(
                          receiveControllerProvider.notifier,
                        );
                        control.isPaused
                            ? receiver.resume(progress.id)
                            : receiver.pause(progress.id);
                      },
                      icon: control.isPaused
                          ? Icons.play_arrow_rounded
                          : Icons.pause_rounded,
                    ),
                    SizedBox(width: compact ? 2 : 4),
                  ],
                  CompactTransferButton(
                    size: size,
                    tooltip: l10n.t('cancel'),
                    onPressed: () => ref
                        .read(receiveControllerProvider.notifier)
                        .cancel(progress.id),
                    icon: Icons.close_rounded,
                  ),
                ],
              ],
            ),
            SizedBox(height: compact ? 6 : 8),
            Text(
              '${(progress.fraction * 100).toStringAsFixed(0)}% - ${formatBytes(progress.receivedBytes)} / ${formatBytes(progress.totalBytes)} - ${formatBytes(progress.bytesPerSecond)}/s - ${l10n.transferStatus(progress.status, message: progress.message)}',
            ),
          ],
        ),
      ),
    );
  }
}
