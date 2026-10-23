import 'dart:async';

import 'package:bshare/src/domain/entities/direct_share_invite.dart';
import 'package:bshare/src/infrastructure/services/android_platform_info_service.dart';
import 'package:bshare/src/infrastructure/services/direct_network_service.dart';
import 'package:bshare/src/infrastructure/services/permission_request_coordinator.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

class _Permissions {
  final statuses = <Permission, PermissionStatus>{};
  final responses = <Permission, PermissionStatus>{};
  final checked = <Permission>[];
  final requested = <Permission>[];
  final verified = <Permission>[];

  late final coordinator = PermissionRequestCoordinator(
    readStatus: (permission) async {
      checked.add(permission);
      return statuses[permission] ?? PermissionStatus.denied;
    },
    requestPermission: (permission) async {
      requested.add(permission);
      final result = responses[permission] ?? PermissionStatus.granted;
      statuses[permission] = result;
      return result;
    },
  );

  Future<PermissionStatus> verify(Permission permission) async {
    verified.add(permission);
    return statuses[permission] ?? PermissionStatus.denied;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('bshare/direct_network');
  const credentials = DirectNetworkCredentials(
    ssid: 'BShare-test',
    password: 'test-password',
    securityType: 'WPA2',
  );
  late List<MethodCall> nativeCalls;

  setUp(() {
    nativeCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          nativeCalls.add(call);
          return switch (call.method) {
            'startLocalOnlyHotspot' => credentials.toJson(),
            'ensureWifiReady' ||
            'bindToCurrentWifi' ||
            'bindToWifiForHost' => true,
            _ => null,
          };
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  DirectNetworkService serviceFor(int sdkInt, _Permissions permissions) {
    final service = DirectNetworkService(
      platformInfo: AndroidPlatformInfoService(
        isAndroid: true,
        readSdkInt: () async => sdkInt,
      ),
      permissionCoordinator: permissions.coordinator,
      readPermissionStatus: permissions.verify,
    );
    addTearDown(service.dispose);
    return service;
  }

  for (final sdkInt in [26, 28, 29, 32, 33, 34, 36]) {
    test(
      'hotspot requests only its required permission on API $sdkInt',
      () async {
        final permissions = _Permissions();
        final service = serviceFor(sdkInt, permissions);
        final result = await service.startLocalOnlyHotspot();
        final required = sdkInt >= 33
            ? Permission.nearbyWifiDevices
            : Permission.locationWhenInUse;
        expect(result.ssid, credentials.ssid);
        expect(permissions.checked, [required]);
        expect(permissions.requested, [required]);
        expect(permissions.verified, [required]);
        expect(nativeCalls.map((call) => call.method), [
          'startLocalOnlyHotspot',
        ]);
      },
    );
  }

  for (final sdkInt in [23, 25]) {
    test('unsupported API $sdkInt rejects hotspot without a dialog', () async {
      final permissions = _Permissions();
      final service = serviceFor(sdkInt, permissions);
      await expectLater(
        service.startLocalOnlyHotspot(),
        throwsA(isA<UnsupportedError>()),
      );
      expect(permissions.checked, isEmpty);
      expect(nativeCalls, isEmpty);
    });
  }

  for (final sdkInt in [32, 33, 36]) {
    test(
      'another granted permission cannot bypass hotspot denial on API $sdkInt',
      () async {
        final required = sdkInt >= 33
            ? Permission.nearbyWifiDevices
            : Permission.locationWhenInUse;
        final other = sdkInt >= 33
            ? Permission.locationWhenInUse
            : Permission.nearbyWifiDevices;
        final permissions = _Permissions()
          ..statuses[other] = PermissionStatus.granted
          ..responses[required] = PermissionStatus.denied;
        final service = serviceFor(sdkInt, permissions);
        await expectLater(service.startLocalOnlyHotspot(), throwsStateError);
        expect(permissions.checked, [required]);
        expect(nativeCalls, isEmpty);
      },
    );
  }

  for (final sdkInt in [23, 28, 29, 32, 33, 36]) {
    test(
      'connect uses permissions required by its native path on API $sdkInt',
      () async {
        final permissions = _Permissions();
        final service = serviceFor(sdkInt, permissions);
        await service.connectToWifi(credentials);
        expect(
          permissions.requested,
          sdkInt >= 29 ? [Permission.locationWhenInUse] : isEmpty,
        );
        expect(
          permissions.verified,
          sdkInt >= 29 ? [Permission.locationWhenInUse] : isEmpty,
        );
        expect(nativeCalls.single.method, 'connectToWifi');
        expect(nativeCalls.single.arguments, credentials.toJson());
      },
    );
  }

  test(
    'nearby access cannot bypass scan location denial on Android 13+',
    () async {
      final permissions = _Permissions()
        ..statuses[Permission.nearbyWifiDevices] = PermissionStatus.granted
        ..responses[Permission.locationWhenInUse] = PermissionStatus.denied;
      final service = serviceFor(33, permissions);
      await expectLater(service.connectToWifi(credentials), throwsStateError);
      expect(permissions.requested, [Permission.locationWhenInUse]);
      expect(nativeCalls, isEmpty);
    },
  );

  test('a coarse-only grant cannot reach the native scan or hotspot', () async {
    final checked = <Permission>[];
    final coordinator = PermissionRequestCoordinator(
      readStatus: (_) async => PermissionStatus.denied,
      requestPermission: (_) async => PermissionStatus.granted,
    );
    final service = DirectNetworkService(
      platformInfo: AndroidPlatformInfoService(
        isAndroid: true,
        readSdkInt: () async => 32,
      ),
      permissionCoordinator: coordinator,
      readPermissionStatus: (permission) async {
        checked.add(permission);
        return PermissionStatus.denied;
      },
    );
    addTearDown(service.dispose);
    await expectLater(service.connectToWifi(credentials), throwsStateError);
    await expectLater(service.startLocalOnlyHotspot(), throwsStateError);
    expect(checked, [
      Permission.locationWhenInUse,
      Permission.locationWhenInUse,
    ]);
    expect(nativeCalls, isEmpty);
  });

  test('explicit retry rechecks a denial instead of caching it', () async {
    final permissions = _Permissions()
      ..responses[Permission.nearbyWifiDevices] = PermissionStatus.denied;
    final service = serviceFor(33, permissions);
    await expectLater(service.startLocalOnlyHotspot(), throwsStateError);
    permissions.responses[Permission.nearbyWifiDevices] =
        PermissionStatus.granted;
    await service.startLocalOnlyHotspot();
    expect(permissions.checked, [
      Permission.nearbyWifiDevices,
      Permission.nearbyWifiDevices,
    ]);
    expect(nativeCalls.map((call) => call.method), ['startLocalOnlyHotspot']);
  });

  test('revoked grants block the next protected action', () async {
    final permissions = _Permissions();
    final service = serviceFor(34, permissions);
    await service.startLocalOnlyHotspot();
    await service.stopLocalOnlyHotspot();
    permissions.statuses[Permission.nearbyWifiDevices] =
        PermissionStatus.denied;
    permissions.responses[Permission.nearbyWifiDevices] =
        PermissionStatus.permanentlyDenied;
    await expectLater(service.startLocalOnlyHotspot(), throwsStateError);
    expect(permissions.checked, [
      Permission.nearbyWifiDevices,
      Permission.nearbyWifiDevices,
    ]);
    expect(
      nativeCalls.where((call) => call.method == 'startLocalOnlyHotspot'),
      hasLength(1),
    );
  });

  test(
    'system Wi-Fi UI, readiness and binding never request location or nearby',
    () async {
      final permissions = _Permissions();
      final service = serviceFor(36, permissions);
      await service.openWifiJoinSettings(credentials);
      await service.openWifiPanel();
      expect(await service.ensureWifiReady(), isTrue);
      expect(await service.bindToCurrentWifi(), isTrue);
      expect(
        await service.bindToWifiForHost(host: '192.168.1.3', port: 53317),
        isTrue,
      );
      expect(permissions.checked, isEmpty);
      expect(permissions.requested, isEmpty);
      expect(permissions.verified, isEmpty);
      expect(nativeCalls.map((call) => call.method), [
        'openWifiJoinSettings',
        'openWifiPanel',
        'ensureWifiReady',
        'bindToCurrentWifi',
        'bindToWifiForHost',
      ]);
    },
  );

  test(
    'overlapping hotspot starts share one permission request and native start',
    () async {
      final response = Completer<PermissionStatus>();
      final entered = Completer<void>();
      var requests = 0;
      final service = DirectNetworkService(
        platformInfo: AndroidPlatformInfoService(
          isAndroid: true,
          readSdkInt: () async => 33,
        ),
        permissionCoordinator: PermissionRequestCoordinator(
          readStatus: (_) async => PermissionStatus.denied,
          requestPermission: (_) {
            requests++;
            entered.complete();
            return response.future;
          },
        ),
        readPermissionStatus: (_) async => PermissionStatus.granted,
      );
      addTearDown(service.dispose);
      final first = service.startLocalOnlyHotspot();
      final second = service.startLocalOnlyHotspot();
      expect(second, same(first));
      await entered.future;
      expect(requests, 1);
      response.complete(PermissionStatus.granted);
      await Future.wait([first, second]);
      expect(nativeCalls.map((call) => call.method), ['startLocalOnlyHotspot']);
    },
  );

  for (final hotspot in [false, true]) {
    test(
      'dispose prevents late permission from starting ${hotspot ? 'hotspot' : 'connect'}',
      () async {
        final response = Completer<PermissionStatus>();
        final entered = Completer<void>();
        final service = DirectNetworkService(
          platformInfo: AndroidPlatformInfoService(
            isAndroid: true,
            readSdkInt: () async => 33,
          ),
          permissionCoordinator: PermissionRequestCoordinator(
            readStatus: (_) async => PermissionStatus.denied,
            requestPermission: (_) {
              entered.complete();
              return response.future;
            },
          ),
          readPermissionStatus: (_) async => PermissionStatus.granted,
        );
        final operation = hotspot
            ? service.startLocalOnlyHotspot()
            : service.connectToWifi(credentials);
        final failed = expectLater(operation, throwsStateError);
        await entered.future;
        final disposal = service.dispose();
        response.complete(PermissionStatus.granted);
        await failed;
        await disposal;
        expect(nativeCalls.map((call) => call.method), [
          'stopLocalOnlyHotspot',
          'disconnectWifi',
        ]);
        expect(service.dispose(), same(disposal));
        await expectLater(service.connectToWifi(credentials), throwsStateError);
        expect(nativeCalls, hasLength(2));
      },
    );
  }
}
