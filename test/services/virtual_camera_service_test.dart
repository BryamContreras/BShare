import 'dart:async';
import 'dart:io';

import 'package:bshare/src/infrastructure/services/virtual_camera_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reports installed Linux virtual camera without Windows support', () async {
    final service = VirtualCameraService(
      isWindows: false,
      isLinux: true,
      query: () async => {
        'supported': true,
        'sourceRegistered': true,
        'registered': true,
      },
    );
    addTearDown(service.dispose);
    await service.refresh();
    expect(service.availability.value, VirtualCameraAvailability.available);
  });

  test('only reports available when supported and registered', () async {
    var response = <String, dynamic>{'supported': true, 'registered': true};
    final service = VirtualCameraService(
      isWindows: true,
      query: () async => response,
    );
    addTearDown(service.dispose);
    await service.refresh();
    expect(service.availability.value, VirtualCameraAvailability.available);
    response = {'supported': true, 'registered': false};
    await service.refresh();
    expect(service.availability.value, VirtualCameraAvailability.notInstalled);
    response = {'supported': false, 'registered': false};
    await service.refresh();
    expect(service.availability.value, VirtualCameraAvailability.unsupported);
  });

  test(
    'missing helper and malformed status do not claim availability',
    () async {
      final missing = VirtualCameraService(
        isWindows: true,
        query: () async => throw const FileSystemException('not installed'),
      );
      final malformed = VirtualCameraService(
        isWindows: true,
        query: () async => {},
      );
      addTearDown(missing.dispose);
      addTearDown(malformed.dispose);
      await missing.refresh();
      await malformed.refresh();
      expect(
        missing.availability.value,
        VirtualCameraAvailability.notInstalled,
      );
      expect(
        malformed.availability.value,
        VirtualCameraAvailability.unavailable,
      );
    },
  );

  test('coalesces queries and ignores results after disposal', () async {
    final result = Completer<Map<String, dynamic>>();
    var calls = 0;
    final service = VirtualCameraService(
      isWindows: true,
      query: () {
        calls++;
        return result.future;
      },
    );
    final first = service.refresh();
    final second = service.refresh();
    expect(calls, 1);
    service.dispose();
    result.complete({'supported': true, 'registered': true});
    await Future.wait([first, second]);
    await service.refresh();
    expect(calls, 1);
  });

  test('unsupported systems do not spawn the Windows helper', () async {
    final service = VirtualCameraService(
      isWindows: false,
      isLinux: false,
      query: () async {
        fail('unsupported system must not query Windows camera');
      },
    );
    addTearDown(service.dispose);
    await service.refresh();
    expect(service.availability.value, VirtualCameraAvailability.unsupported);
  });
}
