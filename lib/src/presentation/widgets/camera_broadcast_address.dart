import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/infrastructure/services/lan_interface.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/localization/broadcast_connection_localizations.dart';
import 'package:bshare/src/presentation/localization/camera_ui_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A camera broadcast's actual viewer endpoint, presented without actions.
class BroadcastAddressText extends ConsumerWidget {
  const BroadcastAddressText({super.key, this.usb = false});

  final bool usb;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final receive = ref.watch(receiveControllerProvider);
    if (usb) {
      final port = receive.asData?.value.port;
      return Text(
        port == null
            ? 'USB'
            : 'USB · ${context.l10n.cameraUiText('port')}: $port',
        key: const ValueKey('camera-broadcast-address'),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Colors.white70,
          fontFamily: 'monospace',
        ),
      );
    }
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
        });
    final endpoints = port != null && port > 0 && port <= 65535
        ? addresses.map((ip) => '$ip:$port').toList()
        : const <String>[];
    final loading =
        receive.isLoading ||
        (usb ? wired?.isLoading == true : network?.isLoading == true);
    final l10n = context.l10n;
    final text = endpoints.isEmpty
        ? l10n.broadcastConnectionText(loading ? 'loading' : 'unavailable')
        : endpoints.join('\n');

    return Text(
      text,
      key: const ValueKey('camera-broadcast-address'),
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: Colors.white70,
        fontFamily: 'monospace',
      ),
    );
  }
}
