import 'dart:async';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/camera_connection_mode.dart';
import 'package:bshare/src/domain/entities/camera_device.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class CameraSessionState {
  const CameraSessionState({
    this.busy = false,
    this.connection,
    this.error,
    this.microphoneEnabled = false,
    this.torchEnabled = false,
    this.torchAvailable = false,
  });

  final bool busy;
  final CameraConnectionMode? connection;
  final bool microphoneEnabled;
  final bool torchEnabled;
  final bool torchAvailable;

  /// Localized by the presentation layer; never contains native error details.
  final String? error;
}

/// Coordinates receiver ownership, capture and display state in one session.
/// Navigation does not create additional captures or reset the dim timer.
class CameraSessionController extends Notifier<CameraSessionState> {
  Future<void>? _starting;
  Future<void>? _stopping;
  Future<void>? _switching;
  Future<void>? _updatingControl;
  String? _pendingControl;
  bool? _pendingControlValue;
  int _generation = 0;
  bool _receiverClaimed = false;
  bool _captureClaimed = false;

  @override
  CameraSessionState build() {
    final service = ref.read(screenShareServiceProvider);
    final server = ref.read(fileServerProvider);
    final receiver = ref.read(receiveControllerProvider.notifier);
    final display = ref.read(cameraDisplayServiceProvider);
    final logger = ref.read(loggerProvider);
    void updateControls() {
      if (!ref.mounted) return;
      state = _snapshot(
        busy: state.busy,
        connection: state.connection,
        error: state.error,
      );
    }

    service.state.addListener(updateControls);
    ref.onDispose(() {
      service.state.removeListener(updateControls);
      ++_generation;
      if (!_receiverClaimed && !_captureClaimed) return;
      unawaited(() async {
        try {
          if (_captureClaimed && service.source == VideoShareSource.camera) {
            await service.stop(server);
          }
          await display.stop();
          if (receiver.ref.mounted &&
              service.state.value.mode == ScreenShareMode.idle) {
            await receiver.stopIfScreenShareOnly();
          }
        } catch (error) {
          logger.warn('Camera controller cleanup failed: $error');
        }
      }());
    });
    return _snapshot();
  }

  CameraSessionState _snapshot({
    bool busy = false,
    CameraConnectionMode? connection,
    String? error,
  }) {
    final service = ref.read(screenShareServiceProvider);
    return CameraSessionState(
      busy: busy,
      connection: connection,
      error: error,
      microphoneEnabled: service.cameraMicrophoneEnabled,
      torchEnabled: service.cameraTorchEnabled,
      torchAvailable: service.cameraTorchAvailable,
    );
  }

  bool _current(int generation) => ref.mounted && generation == _generation;

  void _check(int generation) {
    if (!_current(generation)) throw StateError('Camera session was cancelled');
  }

  Future<void> start({
    required CameraConnectionMode connection,
    required CameraDevice camera,
  }) {
    if (_starting != null) return _starting!;
    if (_stopping != null || _switching != null || _updatingControl != null) {
      return Future.error(StateError('Camera operation is in progress'));
    }
    final service = ref.read(screenShareServiceProvider);
    if (service.state.value.mode != ScreenShareMode.idle) {
      if (service.source == VideoShareSource.camera &&
          service.state.value.mode == ScreenShareMode.sharing &&
          service.currentCamera?.id == camera.id &&
          state.connection == connection) {
        return Future.value();
      }
      return Future.error(StateError('A video session is already active'));
    }
    final generation = ++_generation;
    state = _snapshot(busy: true, connection: connection);
    return _starting = _start(connection, camera, generation).whenComplete(() {
      _starting = null;
      if (_current(generation)) {
        state = _snapshot(connection: connection, error: state.error);
      }
    });
  }

  Future<void> _start(
    CameraConnectionMode connection,
    CameraDevice camera,
    int generation,
  ) async {
    final service = ref.read(screenShareServiceProvider);
    final server = ref.read(fileServerProvider);
    final display = ref.read(cameraDisplayServiceProvider);
    final receiver = ref.read(receiveControllerProvider.notifier);
    var claimedReceiver = false;
    var errorKey = 'cameraFailed';
    try {
      if (service.state.value.mode != ScreenShareMode.idle) {
        throw StateError('A video session is already active');
      }
      final settings = await ref.read(settingsProvider.future);
      _check(generation);
      List<String>? localIps;
      List<String>? remoteSubnets;
      if (connection == CameraConnectionMode.usb) {
        errorKey = 'usbUnavailable';
        ref.invalidate(usbCameraNetworkProvider);
        final network = await ref.read(usbCameraNetworkProvider.future);
        _check(generation);
        if (network.addresses.isEmpty) {
          throw StateError('A wired USB network is required');
        }
        localIps = network.localIps;
        remoteSubnets = network.remoteSubnets;
      }
      errorKey = 'cameraFailed';
      claimedReceiver = true;
      _receiverClaimed = true;
      await receiver.startForVideoShare(
        ipOverride: localIps?.firstOrNull,
        advertise: connection == CameraConnectionMode.wifi,
      );
      _check(generation);
      final receive = ref.read(receiveControllerProvider).value;
      if (receive?.visible != true) {
        throw StateError('Camera receiver is unavailable');
      }
      final starting = service.startCameraSharing(
        server,
        camera: camera,
        settings: settings.cameraCapture.forCamera(
          frontFacing: camera.frontFacing,
        ),
        allowedLocalIps: localIps,
        allowedRemoteSubnets: remoteSubnets,
      );
      _captureClaimed =
          service.source == VideoShareSource.camera &&
          service.state.value.mode == ScreenShareMode.sharing;
      await starting;
      _check(generation);
      if (service.state.value.mode != ScreenShareMode.sharing ||
          service.source != VideoShareSource.camera) {
        throw StateError('Camera capture did not start');
      }
      await display.start();
      _check(generation);
    } catch (error) {
      try {
        if (_captureClaimed && service.source == VideoShareSource.camera) {
          await service.stop(server);
        }
      } finally {
        if (claimedReceiver &&
            receiver.ref.mounted &&
            service.state.value.mode == ScreenShareMode.idle) {
          await receiver.stopIfScreenShareOnly();
        }
        _receiverClaimed = false;
        _captureClaimed = false;
      }
      if (_current(generation)) {
        ref.read(loggerProvider).warn('Camera session could not start: $error');
        state = _snapshot(connection: connection, error: errorKey);
      }
      rethrow;
    }
  }

  Future<void> switchCamera(CameraDevice camera) {
    if (_switching != null) return _switching!;
    if (_starting != null || _stopping != null || _updatingControl != null) {
      return Future.error(StateError('Camera operation is in progress'));
    }
    final generation = ++_generation;
    final connection = state.connection;
    state = _snapshot(busy: true, connection: connection);
    return _switching = _switchCamera(camera, generation).whenComplete(() {
      _switching = null;
      if (_current(generation)) {
        state = _snapshot(connection: connection, error: state.error);
      }
    });
  }

  Future<void> _switchCamera(CameraDevice camera, int generation) async {
    try {
      final settings = await ref.read(settingsProvider.future);
      _check(generation);
      await ref
          .read(screenShareServiceProvider)
          .switchCamera(
            camera,
            settings: settings.cameraCapture.forCamera(
              frontFacing: camera.frontFacing,
            ),
          );
      _check(generation);
      await ref.read(cameraDisplayServiceProvider).wakeDisplay();
    } catch (error) {
      if (_current(generation)) {
        ref.read(loggerProvider).warn('Camera switch failed: $error');
        state = _snapshot(
          connection: state.connection,
          error: 'cameraSwitchFailed',
        );
      }
      rethrow;
    }
  }

  Future<void> setMicrophoneEnabled(bool enabled) => _setControl(
    'microphone',
    enabled,
    'cameraMicrophoneFailed',
    (service) => service.setCameraMicrophoneEnabled(enabled),
  );

  Future<void> setTorchEnabled(bool enabled) => _setControl(
    'torch',
    enabled,
    'cameraTorchFailed',
    (service) => service.setCameraTorchEnabled(enabled),
  );

  Future<void> _setControl(
    String control,
    bool enabled,
    String errorKey,
    Future<void> Function(ScreenShareService) apply,
  ) {
    final pending = _updatingControl;
    if (pending != null) {
      if (_pendingControl == control && _pendingControlValue == enabled) {
        return pending;
      }
      return Future.error(StateError('Camera operation is in progress'));
    }
    final service = ref.read(screenShareServiceProvider);
    if (_starting != null ||
        _switching != null ||
        _stopping != null ||
        service.source != VideoShareSource.camera ||
        service.state.value.mode != ScreenShareMode.sharing) {
      return Future.error(StateError('An active camera session is required'));
    }
    final generation = ++_generation;
    final connection = state.connection;
    _pendingControl = control;
    _pendingControlValue = enabled;
    state = _snapshot(busy: true, connection: connection);
    return _updatingControl = () async {
      try {
        await apply(service);
        _check(generation);
        await ref.read(cameraDisplayServiceProvider).wakeDisplay();
      } catch (error) {
        if (_current(generation)) {
          ref
              .read(loggerProvider)
              .warn('Camera $control update failed: $error');
          state = _snapshot(connection: connection, error: errorKey);
        }
        rethrow;
      } finally {
        _updatingControl = null;
        _pendingControl = null;
        _pendingControlValue = null;
        if (_current(generation)) {
          state = _snapshot(connection: connection, error: state.error);
        }
      }
    }();
  }

  Future<void> stop() {
    if (_stopping != null) return _stopping!;
    final generation = ++_generation;
    final connection = state.connection;
    state = _snapshot(busy: true, connection: connection);
    return _stopping = _stop().whenComplete(() {
      _stopping = null;
      if (_current(generation)) {
        state = _snapshot(connection: connection);
      }
    });
  }

  Future<void> _stop() async {
    final service = ref.read(screenShareServiceProvider);
    final receiver = ref.read(receiveControllerProvider.notifier);
    final display = ref.read(cameraDisplayServiceProvider);
    try {
      if (service.source == VideoShareSource.camera) {
        await service.stop(ref.read(fileServerProvider));
      }
      try {
        await _starting;
      } catch (_) {}
      try {
        await _switching;
      } catch (_) {}
      try {
        await _updatingControl;
      } catch (_) {}
      if (ref.mounted &&
          service.source == VideoShareSource.camera &&
          service.state.value.mode != ScreenShareMode.idle) {
        await service.stop(ref.read(fileServerProvider));
      }
    } finally {
      try {
        await display.stop();
      } finally {
        if (receiver.ref.mounted &&
            service.source == VideoShareSource.camera &&
            service.state.value.mode == ScreenShareMode.idle) {
          await receiver.stopIfScreenShareOnly();
        }
        _receiverClaimed = false;
        _captureClaimed = false;
      }
    }
  }
}
