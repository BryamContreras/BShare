import 'dart:async';

import 'package:bshare/src/infrastructure/services/permission_request_coordinator.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  test(
    'overlapping requests for the same permission share one native dialog',
    () async {
      final response = Completer<PermissionStatus>();
      var requests = 0;
      final coordinator = PermissionRequestCoordinator(
        readStatus: (_) async => PermissionStatus.denied,
        requestPermission: (_) {
          requests++;
          return response.future;
        },
      );
      final home = coordinator.request(Permission.locationWhenInUse);
      final network = coordinator.request(Permission.locationWhenInUse);
      expect(network, same(home));
      response.complete(PermissionStatus.granted);
      expect(await home, PermissionStatus.granted);
      expect(await network, PermissionStatus.granted);
      expect(requests, 1);
    },
  );

  test(
    'startup and feature requests never overlap native permission dialogs',
    () async {
      var activeDialogs = 0;
      var maximumActiveDialogs = 0;
      final requested = <Permission>[];
      final response = Completer<PermissionStatus>();
      final firstStarted = Completer<void>();
      final coordinator = PermissionRequestCoordinator(
        readStatus: (_) async => PermissionStatus.denied,
        requestPermission: (permission) async {
          activeDialogs++;
          if (activeDialogs > maximumActiveDialogs) {
            maximumActiveDialogs = activeDialogs;
          }
          if (activeDialogs > 1) {
            throw PlatformException(
              code: 'PermissionHandler.PermissionManager',
              message: 'A request for permissions is already running',
            );
          }
          requested.add(permission);
          if (permission == Permission.locationWhenInUse) {
            firstStarted.complete();
            await response.future;
          }
          activeDialogs--;
          return PermissionStatus.granted;
        },
      );
      final startup = coordinator.requestAll([
        Permission.locationWhenInUse,
        Permission.notification,
      ]);
      await firstStarted.future;
      final camera = coordinator.request(Permission.camera);
      final storage = coordinator.request(Permission.manageExternalStorage);
      expect(requested, [Permission.locationWhenInUse]);
      response.complete(PermissionStatus.granted);
      await Future.wait([startup, camera, storage]);
      expect(requested, [
        Permission.locationWhenInUse,
        Permission.notification,
        Permission.camera,
        Permission.manageExternalStorage,
      ]);
      expect(maximumActiveDialogs, 1);
      expect(activeDialogs, 0);
    },
  );

  test(
    'a failed dialog does not block subsequent requests or retries',
    () async {
      var requests = 0;
      final coordinator = PermissionRequestCoordinator(
        readStatus: (_) async => PermissionStatus.denied,
        requestPermission: (_) async {
          requests++;
          if (requests == 1) {
            throw PlatformException(code: 'activity-unavailable');
          }
          return PermissionStatus.granted;
        },
      );
      final failed = expectLater(
        coordinator.request(Permission.locationWhenInUse),
        throwsA(isA<PlatformException>()),
      );
      final notification = coordinator.request(Permission.notification);
      await failed;
      expect(await notification, PermissionStatus.granted);
      expect(
        await coordinator.request(Permission.locationWhenInUse),
        PermissionStatus.granted,
      );
      expect(requests, 3);
    },
  );

  test(
    'expired temporary access can request again when the plugin reports permanently denied',
    () async {
      var status = PermissionStatus.permanentlyDenied;
      var requests = 0;
      final response = Completer<PermissionStatus>();
      final requested = Completer<void>();
      final coordinator = PermissionRequestCoordinator(
        readStatus: (_) async => status,
        requestPermission: (permission) {
          expect(permission, Permission.camera);
          requests++;
          requested.complete();
          return response.future;
        },
      );
      final first = coordinator.request(Permission.camera);
      final overlapping = coordinator.request(Permission.camera);
      expect(overlapping, same(first));
      await requested.future;
      expect(requests, 1);
      status = PermissionStatus.granted;
      response.complete(status);
      expect(await first, PermissionStatus.granted);
      expect(await overlapping, PermissionStatus.granted);
      // A later action checks the current OS status instead of requesting again.
      expect(
        await coordinator.request(Permission.camera),
        PermissionStatus.granted,
      );
      expect(requests, 1);
    },
  );

  test(
    'a truly blocked permission returns once without an automatic retry',
    () async {
      var requests = 0;
      final response = Completer<PermissionStatus>();
      final requested = Completer<void>();
      final coordinator = PermissionRequestCoordinator(
        readStatus: (_) async => PermissionStatus.permanentlyDenied,
        requestPermission: (_) {
          requests++;
          requested.complete();
          return response.future;
        },
      );
      final first = coordinator.request(Permission.camera);
      final overlapping = coordinator.request(Permission.camera);
      expect(overlapping, same(first));
      await requested.future;
      expect(requests, 1);
      response.complete(PermissionStatus.permanentlyDenied);
      expect(await first, PermissionStatus.permanentlyDenied);
      expect(await overlapping, PermissionStatus.permanentlyDenied);
      await Future<void>.delayed(Duration.zero);
      expect(requests, 1);
    },
  );

  test(
    'granted or restricted statuses do not open a permission dialog',
    () async {
      final statuses = <Permission, PermissionStatus>{
        Permission.locationWhenInUse: PermissionStatus.granted,
        Permission.photos: PermissionStatus.limited,
        Permission.notification: PermissionStatus.provisional,
        Permission.contacts: PermissionStatus.restricted,
      };
      final coordinator = PermissionRequestCoordinator(
        readStatus: (permission) async => statuses[permission]!,
        requestPermission: (_) async =>
            throw StateError('No dialog should be requested'),
      );
      for (final entry in statuses.entries) {
        expect(await coordinator.request(entry.key), entry.value);
      }
    },
  );
}
