import 'dart:async';
import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/direct_share_invite.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

enum _PendingDirectAction { enableWifi, joinNetwork }

class DirectQrScannerScreen extends ConsumerStatefulWidget {
  const DirectQrScannerScreen({super.key});

  @override
  ConsumerState<DirectQrScannerScreen> createState() =>
      _DirectQrScannerScreenState();
}

class _DirectQrScannerScreenState extends ConsumerState<DirectQrScannerScreen>
    with WidgetsBindingObserver {
  late final MobileScannerController _controller;
  var _cameraAllowed = false;
  var _checkingPermission = true;
  var _handlingCode = false;
  var _waitingForReceiver = false;
  DirectShareInvite? _pendingInvite;
  _PendingDirectAction? _pendingAction;
  String? _statusKey;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = MobileScannerController(
      formats: const [BarcodeFormat.qrCode],
      detectionSpeed: DetectionSpeed.noDuplicates,
    );
    Future.microtask(_requestCameraPermission);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final invite = _pendingInvite;
    if (state == AppLifecycleState.resumed && invite != null) {
      if (_pendingAction == _PendingDirectAction.enableWifi) {
        unawaited(_connectToInvite(invite, openPanelIfWifiOff: false));
      } else {
        unawaited(_waitForReceiver(invite));
      }
    }
  }

  Future<void> _requestCameraPermission() async {
    final status = await Permission.camera.request();
    if (!mounted) return;
    setState(() {
      _cameraAllowed = status.isGranted;
      _checkingPermission = false;
    });
  }

  Future<void> _handleDetect(BarcodeCapture capture) async {
    if (_handlingCode) return;
    String? value;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue?.trim();
      if (raw != null && raw.isNotEmpty) {
        value = raw;
        break;
      }
    }
    if (value == null) return;

    DirectShareInvite invite;
    try {
      invite = DirectShareInvite.decode(value);
    } catch (_) {
      setState(() {
        _error = context.l10n.t('invalidBShareQr');
        _statusKey = null;
      });
      return;
    }

    setState(() {
      _handlingCode = true;
      _statusKey = 'connectingDirectNetwork';
      _error = null;
    });
    await _controller.stop();

    await _connectToInvite(invite);
  }

  Future<void> _connectToInvite(
    DirectShareInvite invite, {
    bool openPanelIfWifiOff = true,
  }) async {
    final l10n = context.l10n;
    if (mounted) {
      setState(() {
        _handlingCode = true;
        _statusKey = 'connectingDirectNetwork';
        _error = null;
      });
    }
    try {
      if (!Platform.isAndroid) {
        throw UnsupportedError(
          'Direct QR connection is only supported on Android',
        );
      }
      final service = ref.read(directNetworkServiceProvider);
      final wifiReady = await service.ensureWifiReady();
      if (!wifiReady) {
        if (openPanelIfWifiOff) {
          await _openWifiPowerPanel(invite);
        } else {
          _showPendingError(invite, l10n.t('turnOnWifiToConnect'));
        }
        return;
      }
      await service.connectToWifi(invite.credentials);
      await _finishConnection(invite, verifyReachability: true);
    } catch (error) {
      if (!mounted) return;
      if (_shouldUseSystemWifiFallback(error)) {
        await _openWifiJoinSettings(invite);
        return;
      }
      setState(() {
        _handlingCode = false;
        _statusKey = null;
        _pendingInvite = null;
        _pendingAction = null;
        _error = error.toString();
      });
      await _controller.start();
    }
  }

  bool _shouldUseSystemWifiFallback(Object error) {
    return error is PlatformException &&
        error.code == 'wifi_connect_unavailable';
  }

  Future<void> _openWifiPowerPanel(DirectShareInvite invite) async {
    if (!mounted) return;
    setState(() {
      _pendingInvite = invite;
      _pendingAction = _PendingDirectAction.enableWifi;
      _handlingCode = true;
      _statusKey = 'turnOnWifiToConnect';
      _error = null;
    });
    try {
      await ref.read(directNetworkServiceProvider).openWifiPanel();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _handlingCode = false;
        _statusKey = null;
        _error = error.toString();
      });
    }
  }

  Future<void> _openWifiJoinSettings([DirectShareInvite? invite]) async {
    final target = invite ?? _pendingInvite;
    if (target == null) return;
    if (!mounted) return;
    setState(() {
      _pendingInvite = target;
      _pendingAction = _PendingDirectAction.joinNetwork;
      _handlingCode = true;
      _statusKey = 'openingWifiSettings';
      _error = null;
    });
    try {
      await ref
          .read(directNetworkServiceProvider)
          .openWifiJoinSettings(target.credentials);
      if (!mounted) return;
      setState(() {
        _statusKey = 'waitingForDirectNetwork';
      });
      unawaited(_waitForReceiver(target));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _handlingCode = false;
        _statusKey = null;
        _error = error.toString();
      });
    }
  }

  Future<void> _waitForReceiver(DirectShareInvite invite) async {
    if (!mounted || _pendingInvite != invite) return;
    if (_waitingForReceiver) return;
    _waitingForReceiver = true;
    setState(() {
      _handlingCode = true;
      _statusKey = 'waitingForDirectNetwork';
      _error = null;
    });

    try {
      for (var attempt = 0; attempt < 24; attempt++) {
        await ref
            .read(directNetworkServiceProvider)
            .bindToWifiForHost(
              host: invite.device.ip,
              port: invite.device.port,
            );
        ref.invalidate(networkProvider);
        if (await _canReachReceiver(invite)) {
          await _finishConnection(invite, verifyReachability: false);
          return;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
        if (!mounted || _pendingInvite != invite) return;
      }

      if (!mounted) return;
      setState(() {
        _handlingCode = false;
        _statusKey = null;
        _error = context.l10n.t('directWifiManualHelp');
      });
    } finally {
      _waitingForReceiver = false;
    }
  }

  Future<void> _finishConnection(
    DirectShareInvite invite, {
    required bool verifyReachability,
  }) async {
    await ref
        .read(directNetworkServiceProvider)
        .bindToWifiForHost(host: invite.device.ip, port: invite.device.port);
    ref.invalidate(networkProvider);
    if (verifyReachability && !await _canReachReceiver(invite)) {
      await _openWifiJoinSettings(invite);
      return;
    }
    ref
        .read(selectedDeviceProvider.notifier)
        .set(invite.device.copyWith(lastSeen: DateTime.now()));
    if (mounted) context.go('/send');
  }

  Future<bool> _canReachReceiver(DirectShareInvite invite) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client
          .getUrl(invite.device.baseUri.replace(path: '/api/ping'))
          .timeout(const Duration(seconds: 2));
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      await response.drain<void>();
      return response.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _retryScan() async {
    setState(() {
      _pendingInvite = null;
      _pendingAction = null;
      _handlingCode = false;
      _statusKey = null;
      _error = null;
    });
    await _controller.start();
  }

  void _showPendingError(DirectShareInvite invite, String message) {
    if (!mounted) return;
    setState(() {
      _pendingInvite = invite;
      _pendingAction = _PendingDirectAction.enableWifi;
      _handlingCode = false;
      _statusKey = null;
      _error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AppShell(
      title: l10n.t('scanQr'),
      backPath: '/send',
      child: _checkingPermission
          ? const Center(child: CircularProgressIndicator())
          : !_cameraAllowed
          ? _CameraPermissionView(onRetry: _requestCameraPermission)
          : Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(controller: _controller, onDetect: _handleDetect),
                const _ScanFrame(),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 24,
                  child: _ScannerStatus(
                    text: _statusKey == null
                        ? l10n.t('pointCameraAtQr')
                        : l10n.t(_statusKey!),
                    error: _error,
                    loading: _handlingCode,
                    primaryActionLabel: _pendingInvite != null && !_handlingCode
                        ? l10n.t('openWifi')
                        : null,
                    onPrimaryAction: _pendingInvite != null && !_handlingCode
                        ? () {
                            final invite = _pendingInvite;
                            if (invite == null) return;
                            if (_pendingAction ==
                                _PendingDirectAction.enableWifi) {
                              unawaited(_openWifiPowerPanel(invite));
                            } else {
                              unawaited(_openWifiJoinSettings(invite));
                            }
                          }
                        : null,
                    secondaryActionLabel:
                        _pendingInvite != null && !_handlingCode
                        ? l10n.t('retryScan')
                        : null,
                    onSecondaryAction: _pendingInvite != null && !_handlingCode
                        ? _retryScan
                        : null,
                  ),
                ),
              ],
            ),
    );
  }
}

class _CameraPermissionView extends StatelessWidget {
  const _CameraPermissionView({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.photo_camera_rounded, size: 44),
            const SizedBox(height: 12),
            Text(
              l10n.t('cameraPermissionTitle'),
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(l10n.t('retry')),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanFrame extends StatelessWidget {
  const _ScanFrame();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: Container(
          width: 260,
          height: 260,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white, width: 3),
          ),
        ),
      ),
    );
  }
}

class _ScannerStatus extends StatelessWidget {
  const _ScannerStatus({
    required this.text,
    required this.loading,
    this.error,
    this.primaryActionLabel,
    this.onPrimaryAction,
    this.secondaryActionLabel,
    this.onSecondaryAction,
  });

  final String text;
  final bool loading;
  final String? error;
  final String? primaryActionLabel;
  final VoidCallback? onPrimaryAction;
  final String? secondaryActionLabel;
  final VoidCallback? onSecondaryAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (loading)
                  const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  const Icon(Icons.qr_code_scanner_rounded),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    error ?? text,
                    style: TextStyle(
                      color: error == null ? null : scheme.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            if (primaryActionLabel != null || secondaryActionLabel != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  if (secondaryActionLabel != null)
                    Expanded(
                      child: OutlinedButton(
                        onPressed: onSecondaryAction,
                        child: Text(secondaryActionLabel!),
                      ),
                    ),
                  if (secondaryActionLabel != null &&
                      primaryActionLabel != null)
                    const SizedBox(width: 10),
                  if (primaryActionLabel != null)
                    Expanded(
                      child: FilledButton(
                        onPressed: onPrimaryAction,
                        child: Text(primaryActionLabel!),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
