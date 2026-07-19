import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/direct_share_invite.dart';
import 'package:bshare/src/domain/entities/transfer_progress_status.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:bshare/src/presentation/widgets/gradient_action_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

class ReceiveScreen extends ConsumerWidget {
  const ReceiveScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final receive = ref.watch(receiveControllerProvider);
    final incoming = ref.watch(incomingTransfersProvider);
    final progress = ref.watch(receiveProgressProvider);
    final settings = ref.watch(settingsProvider);
    final compact = MediaQuery.sizeOf(context).width < 420;
    final visible = receive.value?.visible == true;
    final directInvite = receive.value?.directInvite;
    final deviceName = settings.value?.deviceName.trim() ?? '';
    final receiverBusy =
        incoming.isNotEmpty || progress.any((item) => !item.status.isTerminal);
    final l10n = context.l10n;

    return AppShell(
      title: l10n.t('receive'),
      child: ListView(
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
                        visible
                            ? Icons.visibility_rounded
                            : Icons.visibility_off_rounded,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        visible
                            ? l10n.t('deviceVisible')
                            : l10n.t('receiverStopped'),
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  if (visible && deviceName.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      deviceName,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
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
                  if (visible && receiverBusy) ...[
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(l10n.t('receiverBusy'))),
                      ],
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
                        onPressed: receive.isLoading || !visible || receiverBusy
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
