import 'dart:io';

import 'package:bshare/src/application/virtual_camera_provider.dart';
import 'package:bshare/src/infrastructure/services/virtual_camera_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A read-only device status: the registered camera is always selectable and
/// displays its own waiting image whenever there is no received video.
class VirtualCameraStatus extends ConsumerWidget {
  const VirtualCameraStatus({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!Platform.isWindows) return const SizedBox.shrink();
    final service = ref.watch(virtualCameraServiceProvider);
    final spanish = context.l10n.locale.languageCode == 'es';
    return ValueListenableBuilder<VirtualCameraAvailability>(
      valueListenable: service.availability,
      builder: (context, status, _) {
        final detail = switch (status) {
          VirtualCameraAvailability.checking =>
            spanish
                ? 'Comprobando cámara virtual…'
                : 'Checking virtual camera…',
          VirtualCameraAvailability.available =>
            spanish
                ? 'Disponible. Muestra una imagen de espera sin transmisión.'
                : 'Available. Shows a waiting image without a broadcast.',
          VirtualCameraAvailability.unsupported =>
            spanish
                ? 'La cámara virtual requiere Windows 11.'
                : 'Virtual camera requires Windows 11.',
          VirtualCameraAvailability.notInstalled =>
            spanish
                ? 'Instala el componente de cámara virtual de BShare.'
                : 'Install the BShare virtual camera component.',
          VirtualCameraAvailability.unavailable =>
            spanish
                ? 'No se pudo comprobar la cámara virtual.'
                : 'Could not check the virtual camera.',
        };
        return Semantics(
          liveRegion: true,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.videocam_outlined),
            title: const Text('BShare (Windows Virtual Camera)'),
            subtitle: Text(detail),
            isThreeLine: true,
          ),
        );
      },
    );
  }
}
