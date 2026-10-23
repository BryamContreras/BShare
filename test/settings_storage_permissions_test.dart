import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/infrastructure/services/android_storage_access_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Storage extends AndroidStorageAccessService {
  bool allowed = false;
  final requested = <String>[];
  @override
  Future<void> ensureAccess(
    String path, {
    bool requestPermission = true,
  }) async {
    requested.add(path);
    if (!allowed) throw AndroidStorageAccessDenied(path);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'denied folder changes preserve settings and a later grant recovers',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'bshare-settings-access-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final destination = '${directory.path}/chosen';
      SharedPreferences.setMockInitialValues({
        'deviceId': 'test',
        'deviceName': 'Phone',
        'downloadDirectory': directory.path,
        'autoAcceptDefaultMigrated': true,
      });
      final storage = _Storage();
      final container = ProviderContainer(
        overrides: [androidStorageAccessProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      await container.read(settingsProvider.future);
      final controller = container.read(settingsProvider.notifier);
      await expectLater(
        controller.saveChanges(
          (s) => s.copyWith(downloadDirectory: destination),
        ),
        throwsA(isA<AndroidStorageAccessDenied>()),
      );
      expect(await Directory(destination).exists(), isFalse);
      expect(
        container.read(settingsProvider).value!.downloadDirectory,
        directory.path,
      );
      expect(
        (await SharedPreferences.getInstance()).getString('downloadDirectory'),
        directory.path,
      );

      // Saving unrelated settings does not reopen storage permission dialogs.
      await controller.saveChanges((s) => s.copyWith(deviceName: 'Renamed'));
      expect(storage.requested, [destination]);
      storage.allowed = true;
      await controller.saveChanges(
        (s) => s.copyWith(downloadDirectory: destination),
      );
      expect(await Directory(destination).exists(), isTrue);
      expect(container.read(settingsProvider).value!.deviceName, 'Renamed');
      expect(
        container.read(settingsProvider).value!.downloadDirectory,
        destination,
      );
      expect(storage.requested, [destination, destination]);
    },
  );
}
