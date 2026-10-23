import 'dart:async';
import 'dart:io';

import 'package:bshare/src/infrastructure/services/android_platform_info_service.dart';
import 'package:bshare/src/infrastructure/services/android_storage_access_service.dart';
import 'package:bshare/src/infrastructure/services/permission_request_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  late Directory temporary;
  late Directory private;
  late Directory shared;
  late PermissionStatus status;
  late PermissionStatus response;
  late List<Permission> requests;
  late List<Permission> checks;
  late int sdkReads;
  late int privateReads;

  AndroidStorageAccessService service(int sdk, {bool isAndroid = true}) =>
      AndroidStorageAccessService(
        platformInfo: AndroidPlatformInfoService(
          isAndroid: isAndroid,
          readSdkInt: () async {
            sdkReads++;
            return sdk;
          },
        ),
        privateDirectoryPaths: () async {
          privateReads++;
          return [private.path];
        },
        readPermissionStatus: (permission) async {
          checks.add(permission);
          return status;
        },
        permissionCoordinator: PermissionRequestCoordinator(
          readStatus: (_) async => status,
          requestPermission: (permission) async {
            requests.add(permission);
            status = response;
            return response;
          },
        ),
      );

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('bshare-storage-access-');
    private = await Directory('${temporary.path}/private').create();
    shared = await Directory('${temporary.path}/shared').create();
    status = PermissionStatus.denied;
    response = PermissionStatus.granted;
    requests = [];
    checks = [];
    sdkReads = 0;
    privateReads = 0;
  });
  tearDown(() async => temporary.delete(recursive: true));

  for (final sdk in [24, 28, 29, 30, 31, 32, 33, 34, 35, 36]) {
    test(
      'API $sdk uses its supported permission and observes revocation',
      () async {
        final storage = service(sdk);
        final expected = sdk <= 29
            ? Permission.storage
            : Permission.manageExternalStorage;
        expect(await storage.hasAccess(shared.path), isFalse);
        expect(requests, isEmpty);
        expect(await storage.requestAccess(shared.path), isTrue);
        expect(requests, [expected]);
        expect(checks.every((permission) => permission == expected), isTrue);
        expect(await storage.hasAccess(shared.path), isTrue);
        status = PermissionStatus.denied;
        expect(await storage.hasAccess(shared.path), isFalse);
        await expectLater(
          storage.ensureAccess(shared.path, requestPermission: false),
          throwsA(isA<AndroidStorageAccessDenied>()),
        );
        expect(requests, [expected]);
        expect(sdkReads, 1);
        expect(privateReads, 1);
      },
    );

    test(
      'API $sdk needs no permission for existing or new app paths',
      () async {
        final storage = service(sdk);
        expect(await storage.requestAccess(private.path), isTrue);
        expect(
          await storage.hasAccess('${private.path}/new/downloads'),
          isTrue,
        );
        expect(requests, isEmpty);
        expect(checks, isEmpty);
        expect(sdkReads, 0);
      },
    );
  }

  for (final denied in [
    PermissionStatus.denied,
    PermissionStatus.permanentlyDenied,
    PermissionStatus.restricted,
    PermissionStatus.limited,
    PermissionStatus.provisional,
  ]) {
    test('$denied never grants broad raw-path access', () async {
      status = denied;
      response = denied;
      final storage = service(36);
      expect(await storage.requestAccess(shared.path), isFalse);
      await expectLater(
        storage.ensureAccess(shared.path),
        throwsA(isA<AndroidStorageAccessDenied>()),
      );
    });
  }

  test('similar prefixes and parent traversal are shared paths', () async {
    final storage = service(29);
    expect(await storage.hasAccess('${private.path}-other/file'), isFalse);
    expect(await storage.hasAccess('${private.path}/../shared/file'), isFalse);
    expect(checks, [Permission.storage, Permission.storage]);
    expect(requests, isEmpty);
  });

  test(
    'symlinks from app storage to shared storage do not bypass permission',
    () async {
      await Link('${private.path}/outside').create(shared.path);
      final storage = service(36);
      expect(
        await storage.hasAccess('${private.path}/outside/new/file'),
        isFalse,
      );
      expect(checks, [Permission.manageExternalStorage]);
    },
  );

  test(
    'Android shared-storage aliases preserve only the app-owned subtree',
    () async {
      final storage = AndroidStorageAccessService(
        platformInfo: AndroidPlatformInfoService(
          isAndroid: true,
          readSdkInt: () async => 36,
        ),
        privateDirectoryPaths: () async => [
          '/storage/emulated/0/Android/data/com.bshare.bshare.audit/files',
        ],
        readPermissionStatus: (_) async => PermissionStatus.denied,
      );
      expect(
        await storage.hasAccess(
          '/sdcard/Android/data/com.bshare.bshare.audit/files/x',
        ),
        isTrue,
      );
      expect(
        await storage.hasAccess(
          '/storage/self/primary/Android/data/com.bshare.bshare.audit/files/x',
        ),
        isTrue,
      );
      expect(await storage.hasAccess('/sdcard/Download/x'), isFalse);
      expect(
        await storage.hasAccess('/sdcard/Android/data/another.app/files/x'),
        isFalse,
      );
    },
  );

  test(
    'a private directory provider failure is retried and fails closed',
    () async {
      var attempts = 0;
      final storage = AndroidStorageAccessService(
        platformInfo: AndroidPlatformInfoService(isAndroid: true),
        privateDirectoryPaths: () async {
          if (++attempts == 1) throw StateError('Provider unavailable');
          return [private.path];
        },
      );
      await expectLater(storage.hasAccess(private.path), throwsStateError);
      expect(await storage.hasAccess(private.path), isTrue);
      expect(attempts, 2);
    },
  );

  test('overlapping access requests share one permission dialog', () async {
    final answer = Completer<PermissionStatus>();
    var dialogs = 0;
    var currentStatus = PermissionStatus.denied;
    final storage = AndroidStorageAccessService(
      platformInfo: AndroidPlatformInfoService(
        isAndroid: true,
        readSdkInt: () async => 30,
      ),
      privateDirectoryPaths: () async => [private.path],
      readPermissionStatus: (_) async => currentStatus,
      permissionCoordinator: PermissionRequestCoordinator(
        readStatus: (_) async => currentStatus,
        requestPermission: (_) async {
          dialogs++;
          currentStatus = await answer.future;
          return currentStatus;
        },
      ),
    );
    final accesses = List.generate(
      6,
      (_) => storage.requestAccess(shared.path),
    );
    while (dialogs == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(dialogs, 1);
    answer.complete(PermissionStatus.granted);
    expect(await Future.wait(accesses), everyElement(isTrue));
    expect(dialogs, 1);
  });

  test(
    'an optimistic granted callback does not override a current denial',
    () async {
      final storage = AndroidStorageAccessService(
        platformInfo: AndroidPlatformInfoService(
          isAndroid: true,
          readSdkInt: () async => 36,
        ),
        privateDirectoryPaths: () async => [private.path],
        readPermissionStatus: (_) async => PermissionStatus.denied,
        permissionCoordinator: PermissionRequestCoordinator(
          readStatus: (_) async => PermissionStatus.denied,
          requestPermission: (_) async => PermissionStatus.granted,
        ),
      );
      expect(await storage.requestAccess(shared.path), isFalse);
      await expectLater(
        storage.ensureAccess(shared.path),
        throwsA(isA<AndroidStorageAccessDenied>()),
      );
    },
  );

  test('relative Android paths fail without requesting a permission', () async {
    expect(await service(36).requestAccess('Download/file'), isFalse);
    expect(requests, isEmpty);
    expect(sdkReads, 0);
  });

  test(
    'other platforms bypass Android channels and permission requests',
    () async {
      expect(
        await service(0, isAndroid: false).requestAccess(shared.path),
        isTrue,
      );
      expect(sdkReads, 0);
      expect(privateReads, 0);
      expect(checks, isEmpty);
      expect(requests, isEmpty);
    },
  );
}
