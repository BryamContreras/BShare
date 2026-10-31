import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/infrastructure/services/lan_interface.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/localization/broadcast_connection_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The running HTTP listener's address, which viewers use to join the stream.
/// USB broadcasts never advertise an unrelated Wi-Fi or Ethernet endpoint.
class BroadcastAddressCard extends ConsumerWidget {
  const BroadcastAddressCard({
    super.key,
    this.usb = false,
    this.overlay = false,
  });

  final bool usb;
  final bool overlay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final receive = ref.watch(receiveControllerProvider);
    final network = usb ? null : ref.watch(networkProvider);
    final wired = usb ? ref.watch(usbCameraNetworkProvider) : null;
    final snapshot = network?.asData?.value;
    final port = receive.asData?.value.visible == true
        ? receive.asData?.value.port
        : null;
    final addresses =
        <String>{
          if (usb) ...?wired?.asData?.value.localIps,
          if (!usb) ...[
            if (snapshot?.ip != null) snapshot!.ip!,
            for (final link in snapshot?.interfaces ?? const [])
              for (final address in link.addresses) address.address,
          ],
        }.where((value) {
          final address = InternetAddress.tryParse(value);
          return address != null && isUsableLanAddress(address);
        }).toList();
    final endpoints = port != null && port > 0 && port <= 65535
        ? addresses.map((ip) => '$ip:$port').toList()
        : const <String>[];
    final loading =
        receive.isLoading ||
        (usb ? wired?.isLoading == true : network?.isLoading == true);
    final l10n = context.l10n;
    final foreground = overlay ? Colors.white : null;

    return Card(
      key: const ValueKey('broadcast-address-card'),
      margin: EdgeInsets.zero,
      color: overlay ? Colors.black.withValues(alpha: .72) : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.broadcastConnectionText('address'),
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: foreground,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (endpoints.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  l10n.broadcastConnectionText(
                    loading ? 'loading' : 'unavailable',
                  ),
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: foreground),
                ),
              ),
            for (final endpoint in endpoints)
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      endpoint,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: foreground,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.broadcastConnectionText('copy'),
                    color: foreground,
                    icon: const Icon(Icons.copy_rounded, size: 20),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: endpoint));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(l10n.broadcastConnectionText('copied')),
                        ),
                      );
                    },
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
