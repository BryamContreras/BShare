import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/transfer_record.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:bshare/src/presentation/widgets/formatters.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final records = ref.watch(historyProvider);
    final l10n = context.l10n;
    return AppShell(
      title: l10n.t('history'),
      scrollController: _scrollController,
      child: ListView(
        controller: _scrollController,
        padding: EdgeInsets.all(Platform.isAndroid ? 8 : 20),
        children: [
          Row(
            children: [
              Text(
                l10n.t('transferHistory'),
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              IconButton.filledTonal(
                tooltip: l10n.t('clearHistory'),
                onPressed: records.isEmpty
                    ? null
                    : () => ref.read(historyProvider.notifier).clear(),
                icon: const Icon(Icons.delete_sweep_rounded),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (records.isEmpty)
            Card(
              child: ListTile(
                leading: const Icon(Icons.history_rounded),
                title: Text(l10n.t('noTransfersYet')),
              ),
            )
          else
            for (final record in records)
              Card(
                child: ListTile(
                  leading: Icon(
                    record.direction == TransferDirection.sent
                        ? Icons.north_east_rounded
                        : Icons.south_west_rounded,
                  ),
                  title: Text(record.fileName),
                  subtitle: Text(
                    '${record.remoteDevice} - ${formatBytes(record.size)} - ${record.createdAt.toLocal()}',
                  ),
                  trailing: Text(record.status.name),
                ),
              ),
        ],
      ),
    );
  }
}
