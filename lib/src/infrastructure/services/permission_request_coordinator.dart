import 'package:permission_handler/permission_handler.dart';

/// Android accepts only one pending permission dialog per activity. Share this
/// coordinator between screens and services, including overlapping requests for
/// the same permission while the user is still answering its first dialog.
class PermissionRequestCoordinator {
  PermissionRequestCoordinator({
    Future<PermissionStatus> Function(Permission)? readStatus,
    Future<PermissionStatus> Function(Permission)? requestPermission,
  }) : _readStatus = readStatus ?? ((permission) => permission.status),
       _requestPermission =
           requestPermission ?? ((permission) => permission.request());

  static final instance = PermissionRequestCoordinator();

  final Future<PermissionStatus> Function(Permission) _readStatus;
  final Future<PermissionStatus> Function(Permission) _requestPermission;
  final Map<Permission, Future<PermissionStatus>> _pending = {};
  Future<void> _operation = Future<void>.value();

  /// Read-only access for remote actions that must never open an OS dialog.
  Future<PermissionStatus> status(Permission permission) =>
      _readStatus(permission);

  Future<PermissionStatus> request(Permission permission) {
    final existing = _pending[permission];
    if (existing != null) return existing;

    late final Future<PermissionStatus> operation;
    operation = _operation
        .then((_) async {
          // Check inside the queue: a preceding dialog may have granted access.
          final status = await _readStatus(permission);
          if (status.isGranted ||
              status.isLimited ||
              status.isProvisional ||
              status.isRestricted) {
            return status;
          }
          // Android can report an expired one-time permission as permanently
          // denied from the plugin's stored denial history. Let the OS handle
          // this explicit request; a truly blocked permission simply returns
          // denied without opening a dialog. Never retry automatically.
          return _requestPermission(permission);
        })
        .whenComplete(() {
          _pending.remove(permission);
        });
    _pending[permission] = operation;
    _operation = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return operation;
  }

  Future<void> requestAll(Iterable<Permission> permissions) async {
    await Future.wait(permissions.map(request));
  }
}
