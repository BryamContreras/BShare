import 'dart:io';

import 'package:bshare/src/infrastructure/services/android_platform_info_service.dart';
import 'package:bshare/src/infrastructure/services/permission_request_coordinator.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class AndroidStorageAccessDenied implements Exception {
  const AndroidStorageAccessDenied(this.path);

  final String path;

  @override
  String toString() => 'Storage permission is required for the selected path';
}

/// Guards raw shared-storage paths with the permission supported by this SDK.
/// App-owned directories need no broad storage grant. Grants are read again for
/// every operation so a revoked permission never survives in an application cache.
class AndroidStorageAccessService {
  AndroidStorageAccessService({
    AndroidPlatformInfoService? platformInfo,
    PermissionRequestCoordinator? permissionCoordinator,
    Future<PermissionStatus> Function(Permission)? readPermissionStatus,
    Future<List<String>> Function()? privateDirectoryPaths,
  }) : _platform = platformInfo ?? AndroidPlatformInfoService(),
       _permissions =
           permissionCoordinator ?? PermissionRequestCoordinator.instance,
       _readStatus =
           readPermissionStatus ?? ((permission) => permission.status),
       _readPrivatePaths = privateDirectoryPaths ?? _applicationDirectories;

  final AndroidPlatformInfoService _platform;
  final PermissionRequestCoordinator _permissions;
  final Future<PermissionStatus> Function(Permission) _readStatus;
  final Future<List<String>> Function() _readPrivatePaths;
  Future<List<String>>? _privatePaths;

  Future<bool> requestAccess(String path) => _access(path, request: true);

  /// Checks a grant without opening a permission dialog or system settings.
  Future<bool> hasAccess(String path) => _access(path, request: false);

  Future<void> ensureAccess(
    String path, {
    bool requestPermission = true,
  }) async {
    final allowed = requestPermission
        ? await requestAccess(path)
        : await hasAccess(path);
    if (!allowed) {
      throw AndroidStorageAccessDenied(path);
    }
  }

  Future<bool> _access(String path, {required bool request}) async {
    if (!_platform.isAndroid) return true;
    if (!p.posix.isAbsolute(path)) return false;
    if (await _isApplicationPath(path)) return true;
    final sdk = await _platform.sdkInt();
    final permission = sdk <= 29
        ? Permission.storage
        : Permission.manageExternalStorage;
    if ((await _readStatus(permission)).isGranted) return true;
    if (!request) return false;
    if (!(await _permissions.request(permission)).isGranted) return false;
    // Settings results and permission callbacks can race a revocation. The
    // current OS grant, rather than an optimistic callback, authorizes I/O.
    return (await _readStatus(permission)).isGranted;
  }

  Future<List<String>> _applicationPaths() {
    if (_privatePaths case final cached?) return cached;
    late final Future<List<String>> result;
    result = _readPrivatePaths()
        .then((paths) async {
          final resolved = <String>{};
          for (final path in paths) {
            if (!p.posix.isAbsolute(path)) continue;
            final canonical = await _canonicalPath(path);
            // Never accept a provider error that accidentally reports shared root.
            if (canonical != null &&
                canonical != '/' &&
                canonical != '/storage/emulated/0' &&
                canonical != '/storage') {
              resolved.add(canonical);
            }
          }
          return resolved.toList(growable: false);
        })
        .catchError((Object error, StackTrace stack) {
          if (_privatePaths == result) _privatePaths = null;
          Error.throwWithStackTrace(error, stack);
        });
    _privatePaths = result;
    return result;
  }

  Future<bool> _isApplicationPath(String path) async {
    final directories = await _applicationPaths();
    final canonical = await _canonicalPath(path);
    if (canonical == null) return false;
    return directories.any(
      (directory) =>
          canonical == directory || p.posix.isWithin(directory, canonical),
    );
  }

  /// Resolve an existing ancestor as well as the yet-to-be-created suffix.
  /// A symlink inside app storage that points to shared storage stays shared.
  static Future<String?> _canonicalPath(String path) async {
    var normalized = p.posix.normalize(path);
    for (final alias in ['/sdcard', '/storage/self/primary']) {
      if (normalized == alias || p.posix.isWithin(alias, normalized)) {
        normalized = '/storage/emulated/0${normalized.substring(alias.length)}';
        break;
      }
    }
    var ancestor = normalized;
    final suffix = <String>[];
    while (true) {
      try {
        if (await FileSystemEntity.type(ancestor, followLinks: false) !=
            FileSystemEntityType.notFound) {
          final resolved = await Directory(ancestor).resolveSymbolicLinks();
          return p.posix.normalize(
            p.posix.joinAll([resolved, ...suffix.reversed]),
          );
        }
      } on FileSystemException {
        return null;
      }
      final parent = p.posix.dirname(ancestor);
      if (parent == ancestor) return null;
      suffix.add(p.posix.basename(ancestor));
      ancestor = parent;
    }
  }

  static Future<List<String>> _applicationDirectories() async {
    final paths = <String>{};
    for (final read in <Future<Directory?> Function()>[
      getApplicationSupportDirectory,
      getApplicationDocumentsDirectory,
      getApplicationCacheDirectory,
      getTemporaryDirectory,
      getExternalStorageDirectory,
    ]) {
      try {
        final directory = await read();
        if (directory != null) paths.add(directory.path);
      } catch (_) {
        // Missing optional providers must not turn a shared path into private.
      }
    }
    return paths.toList(growable: false);
  }
}
