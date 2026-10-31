import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/infrastructure/services/usb_adb_transport_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/localization/usb_connection_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// ADB lists physical USB devices; Wi-Fi ADB and emulators are filtered by the
/// transport service. Only an authorized device can be selected for a stream.
class UsbDevicePicker extends ConsumerWidget {
  const UsbDevicePicker({
    super.key,
    required this.selectedSerial,
    required this.onSelected,
    this.enabled = true,
  });

  final String? selectedSerial;
  final ValueChanged<UsbAdbDevice> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(usbAdbDevicesProvider);
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.usbConnectionText('device'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton.filledTonal(
              key: const ValueKey('usb-device-refresh'),
              tooltip: l10n.usbConnectionText('refresh'),
              onPressed: enabled && !devices.isLoading
                  ? () => ref.invalidate(usbAdbDevicesProvider)
                  : null,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        devices.when(
          loading: () => Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text(l10n.usbConnectionText('loading')),
              ],
            ),
          ),
          error: (error, _) => Card(
            key: const ValueKey('usb-device-error'),
            child: ListTile(
              leading: const Icon(Icons.usb_off_rounded),
              title: Text(
                l10n.usbConnectionText(
                  error is UsbAdbTransportException &&
                          error.code == 'adb-not-found'
                      ? 'adbMissing'
                      : 'unavailable',
                ),
              ),
            ),
          ),
          data: (values) {
            if (values.isEmpty) {
              return Card(
                key: const ValueKey('usb-device-empty'),
                child: ListTile(
                  leading: const Icon(Icons.usb_rounded),
                  title: Text(l10n.usbConnectionText('empty')),
                ),
              );
            }
            return Column(
              children: [
                for (final device in values)
                  Card(
                    child: ListTile(
                      key: ValueKey('usb-device-${device.serial}'),
                      leading: const Icon(Icons.smartphone_rounded),
                      title: Text(device.label),
                      subtitle: Text(
                        l10n.usbConnectionText(switch (device.state) {
                          UsbAdbDeviceState.authorized => 'ready',
                          UsbAdbDeviceState.unauthorized => 'unauthorized',
                          UsbAdbDeviceState.offline => 'offline',
                        }),
                      ),
                      selected:
                          device.state == UsbAdbDeviceState.authorized &&
                          device.serial == selectedSerial,
                      trailing: Icon(
                        device.state != UsbAdbDeviceState.authorized
                            ? Icons.warning_amber_rounded
                            : device.serial == selectedSerial
                            ? Icons.check_circle_rounded
                            : Icons.circle_outlined,
                      ),
                      onTap:
                          enabled &&
                              device.state == UsbAdbDeviceState.authorized
                          ? () => onSelected(device)
                          : null,
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
