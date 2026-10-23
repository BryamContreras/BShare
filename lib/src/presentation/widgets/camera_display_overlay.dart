import 'dart:async';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/localization/camera_ui_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Covers the whole app while the camera display is dimmed, including routes
/// opened after capture started. The capture controller owns the idle timer.
class CameraDisplayOverlay extends ConsumerWidget {
  const CameraDisplayOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final display = ref.watch(cameraDisplayServiceProvider);
    final logger = ref.read(loggerProvider);
    void wake() {
      unawaited(
        display.wakeDisplay().catchError((Object error) {
          logger.warn('Could not restore camera display: $error');
        }),
      );
    }

    return ValueListenableBuilder<bool>(
      valueListenable: display.dimmed,
      builder: (context, dimmed, _) => Listener(
        onPointerDown: (_) {
          if (display.active && !dimmed) wake();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            ExcludeSemantics(excluding: dimmed, child: child),
            if (dimmed)
              Positioned.fill(
                child: Semantics(
                  container: true,
                  button: true,
                  label: context.l10n.cameraUiText('tapToWake'),
                  onTap: wake,
                  excludeSemantics: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: wake,
                    excludeFromSemantics: true,
                    child: ColoredBox(
                      color: Colors.black,
                      child: SafeArea(
                        minimum: const EdgeInsets.all(16),
                        child: Center(
                          child: SingleChildScrollView(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 280),
                              child: Text(
                                context.l10n.cameraUiText('tapToWake'),
                                key: const ValueKey('camera-dim-hint'),
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.bodySmall!
                                    .copyWith(
                                      inherit: false,
                                      color: Colors.white54,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w400,
                                      height: 1.45,
                                      letterSpacing: 0.15,
                                      decoration: TextDecoration.none,
                                    ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
