import 'dart:async';
import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/direct_share_invite.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/localization/camera_ui_localizations.dart';
import 'package:bshare/src/presentation/navigation/app_navigation.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:bshare/src/infrastructure/services/permission_request_coordinator.dart';
import 'package:permission_handler/permission_handler.dart';

enum _PendingDirectAction { enableWifi, joinNetwork }

class DirectQrScannerScreen extends ConsumerWidget {
  const DirectQrScannerScreen({
    super.key,
    this.permissionCoordinator,
    this.controllerFactory,
  });

  final PermissionRequestCoordinator? permissionCoordinator;
  final MobileScannerController Function()? controllerFactory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(screenShareServiceProvider);
    final cameraBusy = ref.watch(
      cameraSessionProvider.select((session) => session.busy),
    );
    return ValueListenableBuilder<ScreenShareState>(
      valueListenable: service.state,
      builder: (context, state, _) {
        final cameraSharing =
            service.source == VideoShareSource.camera &&
            state.mode == ScreenShareMode.sharing;
        if (cameraBusy || cameraSharing) return const _SharedCameraInUseView();
        return _DirectQrScannerContent(
          permissionCoordinator: permissionCoordinator,
          controllerFactory: controllerFactory,
        );
      },
    );
  }
}

class _DirectQrScannerContent extends ConsumerStatefulWidget {
  const _DirectQrScannerContent({
    this.permissionCoordinator,
    this.controllerFactory,
  });

  final PermissionRequestCoordinator? permissionCoordinator;
  final MobileScannerController Function()? controllerFactory;

  @override
  ConsumerState<_DirectQrScannerContent> createState() =>
      _DirectQrScannerScreenState();
}

class _DirectQrScannerScreenState extends ConsumerState<_DirectQrScannerContent>
    with WidgetsBindingObserver {
  late MobileScannerController _controller;
  var _cameraAllowed = false;
  var _checkingPermission = true;
  var _appActive = true;
  var _closing = false;
  Future<void> _cameraOperation = Future<void>.value();
  Future<void>? _permissionOperation;
  Future<void>? _connectionOperation;
  var _handlingCode = false;
  var _waitingForReceiver = false;
  DirectShareInvite? _activeInvite;
  HttpClient? _probeClient;
  Timer? _retryTimer;
  Completer<void>? _retryDelay;
  DirectShareInvite? _pendingInvite;
  _PendingDirectAction? _pendingAction;
  String? _statusKey;
  String? _error;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _appActive = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _controller = _createController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_requestCameraPermission());
    });
  }

  MobileScannerController _createController() =>
      widget.controllerFactory?.call() ??
      MobileScannerController(
        autoStart: false,
        formats: const [BarcodeFormat.qrCode],
        // Duplicate callbacks are guarded while connecting. Allow the same QR
        // again after a failed connection without making the user move it away.
        detectionSpeed: DetectionSpeed.normal,
      );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _closing = true;
    _activeInvite = null;
    _cancelReceiverWait();
    unawaited(_disposeCamera());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    unawaited(_syncCamera());
    final invite = _pendingInvite;
    if (state == AppLifecycleState.resumed && invite != null) {
      if (_pendingAction == _PendingDirectAction.enableWifi) {
        unawaited(_connectToInvite(invite, openPanelIfWifiOff: false));
      } else {
        unawaited(_waitForReceiver(invite));
      }
    } else if (state == AppLifecycleState.resumed && !_cameraAllowed) {
      unawaited(_requestCameraPermission());
    }
  }

  Future<void> _requestCameraPermission() {
    return _permissionOperation ??= _checkCameraPermission().whenComplete(() {
      _permissionOperation = null;
    });
  }

  Future<void> _checkCameraPermission() async {
    try {
      final status =
          await (widget.permissionCoordinator ??
                  PermissionRequestCoordinator.instance)
              .request(Permission.camera);
      if (!mounted || _closing) return;
      setState(() {
        _cameraAllowed = status.isGranted;
        _checkingPermission = false;
      });
      // The scanner must be attached before start(), including after returning
      // from the system permission settings.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_closing) unawaited(_syncCamera());
      });
    } catch (error, stack) {
      debugPrint('QR camera permission failed: $error\n$stack');
      if (!mounted || _closing) return;
      setState(() {
        _checkingPermission = false;
        _cameraAllowed = false;
      });
    }
  }

  Future<void> _syncCamera() {
    final operation = _cameraOperation.then((_) async {
      if (_closing) return;
      try {
        if (_shouldRunCamera) {
          if (_controller.value.error != null) {
            // A failed start still owns native event subscriptions. Dispose it
            // before retrying, rather than stacking listeners on the same one.
            await _controller.dispose();
            if (!_shouldRunCamera) return;
            setState(() {
              _controller = _createController();
            });
            await WidgetsBinding.instance.endOfFrame;
            if (!_shouldRunCamera) return;
          }
          await _controller.start();
        } else {
          await _controller.stop();
        }
      } catch (error, stack) {
        debugPrint('QR camera operation failed: $error\n$stack');
        if (!mounted || _closing) return;
        setState(() {
          _error = context.l10n.t('cameraUnavailableHelp');
        });
      }
    });
    _cameraOperation = operation;
    return operation;
  }

  bool get _shouldRunCamera =>
      mounted && !_closing && _appActive && _cameraAllowed && !_handlingCode;

  Future<void> _disposeCamera() async {
    await _cameraOperation;
    try {
      try {
        await _controller.stop();
      } finally {
        await _controller.dispose();
      }
    } catch (error, stack) {
      debugPrint('QR camera cleanup failed: $error\n$stack');
    }
  }

  bool _isCurrent(DirectShareInvite invite) =>
      mounted && !_closing && identical(_activeInvite, invite);

  void _cancelReceiverWait() {
    _probeClient?.close(force: true);
    _probeClient = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    final delay = _retryDelay;
    _retryDelay = null;
    if (delay != null && !delay.isCompleted) delay.complete();
  }

  Future<void> _receiverRetryDelay() {
    final delay = Completer<void>();
    _retryDelay = delay;
    _retryTimer = Timer(const Duration(seconds: 1), () {
      _retryTimer = null;
      _retryDelay = null;
      delay.complete();
    });
    return delay.future;
  }

  Future<void> _handleDetect(BarcodeCapture capture) async {
    if (!mounted ||
        _closing ||
        !_appActive ||
        _handlingCode ||
        _connectionOperation != null) {
      return;
    }
    DirectShareInvite? invite;
    var foundValue = false;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue?.trim();
      if (raw != null && raw.isNotEmpty) {
        foundValue = true;
        try {
          invite = DirectShareInvite.decode(raw);
          break;
        } on FormatException {
          // A frame can contain several QR codes; a different QR must not hide
          // a valid BShare invitation in the same camera frame.
        }
      }
    }
    if (invite == null) {
      if (!foundValue) return;
      setState(() {
        _error = context.l10n.t('invalidBShareQr');
        _statusKey = null;
      });
      return;
    }

    setState(() {
      _activeInvite = invite;
      _handlingCode = true;
      _statusKey = 'connectingDirectNetwork';
      _error = null;
    });
    await _syncCamera();

    if (!_isCurrent(invite)) return;
    await _connectToInvite(invite);
  }

  Future<void> _connectToInvite(
    DirectShareInvite invite, {
    bool openPanelIfWifiOff = true,
  }) {
    return _connectionOperation ??=
        _connectToInviteOnce(
          invite,
          openPanelIfWifiOff: openPanelIfWifiOff,
        ).whenComplete(() {
          _connectionOperation = null;
        });
  }

  Future<void> _connectToInviteOnce(
    DirectShareInvite invite, {
    bool openPanelIfWifiOff = true,
  }) async {
    if (!_isCurrent(invite)) return;
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
      if (!_isCurrent(invite)) return;
      if (!wifiReady) {
        if (openPanelIfWifiOff) {
          await _openWifiPowerPanel(invite);
        } else {
          _showPendingError(invite, l10n.t('turnOnWifiToConnect'));
        }
        return;
      }
      await service.connectToWifi(invite.credentials);
      if (!_isCurrent(invite)) return;
      await _finishConnection(invite, verifyReachability: true);
    } catch (error) {
      if (!_isCurrent(invite)) return;
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
      await _syncCamera();
    }
  }

  bool _shouldUseSystemWifiFallback(Object error) {
    return error is PlatformException &&
        error.code == 'wifi_connect_unavailable';
  }

  Future<void> _openWifiPowerPanel(DirectShareInvite invite) async {
    if (!_isCurrent(invite)) return;
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
      if (!_isCurrent(invite)) return;
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
    if (!_isCurrent(target)) return;
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
      if (!_isCurrent(target)) return;
      setState(() {
        _statusKey = 'waitingForDirectNetwork';
      });
      unawaited(_waitForReceiver(target));
    } catch (error) {
      if (!_isCurrent(target)) return;
      setState(() {
        _handlingCode = false;
        _statusKey = null;
        _error = error.toString();
      });
    }
  }

  Future<void> _waitForReceiver(DirectShareInvite invite) async {
    if (!_isCurrent(invite) || _pendingInvite != invite) return;
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
        if (!_isCurrent(invite)) return;
        ref.invalidate(networkProvider);
        if (await _canReachReceiver(invite)) {
          if (!_isCurrent(invite)) return;
          await _finishConnection(invite, verifyReachability: false);
          return;
        }
        if (!_isCurrent(invite)) return;
        await _receiverRetryDelay();
        if (!_isCurrent(invite) || _pendingInvite != invite) return;
      }

      if (!_isCurrent(invite)) return;
      setState(() {
        _handlingCode = false;
        _statusKey = null;
        _error = context.l10n.t('directWifiManualHelp');
      });
    } catch (error, stack) {
      debugPrint('QR receiver connection failed: $error\n$stack');
      if (!_isCurrent(invite)) return;
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
    if (!_isCurrent(invite)) return;
    await ref
        .read(directNetworkServiceProvider)
        .bindToWifiForHost(host: invite.device.ip, port: invite.device.port);
    if (!_isCurrent(invite)) return;
    ref.invalidate(networkProvider);
    if (verifyReachability) {
      final reachable = await _canReachReceiver(invite);
      if (!_isCurrent(invite)) return;
      if (!reachable) {
        await _openWifiJoinSettings(invite);
        return;
      }
    }
    ref
        .read(selectedDeviceProvider.notifier)
        .set(invite.device.copyWith(lastSeen: DateTime.now()));
    if (mounted) AppNavigationScope.back(context, fallback: '/send');
  }

  Future<bool> _canReachReceiver(DirectShareInvite invite) async {
    if (!_isCurrent(invite)) return false;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    _probeClient = client;
    try {
      final request = await client
          .getUrl(invite.device.baseUri.replace(path: '/api/ping'))
          .timeout(const Duration(seconds: 2));
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      await response.drain<void>().timeout(const Duration(seconds: 2));
      return response.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
      if (identical(_probeClient, client)) _probeClient = null;
    }
  }

  Future<void> _retryScan() async {
    _activeInvite = null;
    _cancelReceiverWait();
    setState(() {
      _pendingInvite = null;
      _pendingAction = null;
      _handlingCode = false;
      _statusKey = null;
      _error = null;
    });
    await _syncCamera();
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
                MobileScanner(
                  key: ObjectKey(_controller),
                  controller: _controller,
                  onDetect: _handleDetect,
                  onDetectError: (error, stack) {
                    debugPrint('QR detection failed: $error\n$stack');
                    if (!mounted || _closing) return;
                    setState(() {
                      _error = context.l10n.t('cameraUnavailableHelp');
                    });
                  },
                  useAppLifecycleState: false,
                  tapToFocus: true,
                  placeholderBuilder: (_) => const ColoredBox(
                    color: Colors.black,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  errorBuilder: (context, error) {
                    debugPrint('QR camera start failed: $error');
                    return _CameraPermissionView(
                      onRetry: () => unawaited(_requestCameraPermission()),
                      unavailable:
                          error.errorCode !=
                          MobileScannerErrorCode.permissionDenied,
                    );
                  },
                ),
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
                    secondaryActionLabel: _error != null && !_handlingCode
                        ? l10n.t('retryScan')
                        : null,
                    onSecondaryAction: _error != null && !_handlingCode
                        ? _retryScan
                        : null,
                  ),
                ),
              ],
            ),
    );
  }
}

class _SharedCameraInUseView extends StatelessWidget {
  const _SharedCameraInUseView();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AppShell(
      title: l10n.t('scanQr'),
      backPath: '/send',
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_rounded, size: 44),
              const SizedBox(height: 12),
              Text(
                l10n.cameraUiText('qrCameraBusyTitle'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                l10n.cameraUiText('qrCameraBusyHelp'),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => context.go('/camera'),
                icon: const Icon(Icons.videocam_rounded),
                label: Text(l10n.cameraUiText('openCamera')),
                style: FilledButton.styleFrom(shape: const StadiumBorder()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CameraPermissionView extends StatelessWidget {
  const _CameraPermissionView({
    required this.onRetry,
    this.unavailable = false,
  });

  final VoidCallback onRetry;
  final bool unavailable;

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
              l10n.t(
                unavailable
                    ? 'cameraUnavailableTitle'
                    : 'cameraPermissionTitle',
              ),
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(l10n.t('cameraUnavailableHelp'), textAlign: TextAlign.center),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(l10n.t('retry')),
            ),
            TextButton(
              onPressed: () => unawaited(openAppSettings()),
              child: Text(l10n.t('openAppSettings')),
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
