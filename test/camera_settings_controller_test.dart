import 'dart:async';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/app_settings.dart';
import 'package:bshare/src/infrastructure/repositories/settings_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _BlockingRepository extends SettingsRepository {
  _BlockingRepository(super.prefs);

  final entered = Completer<void>();
  final release = Completer<void>();
  var saves = 0;

  @override
  Future<void> save(AppSettings settings) async {
    if (saves++ == 0) {
      entered.complete();
      await release.future;
    }
    await super.save(settings);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'deviceId': 'test-device',
      'deviceName': 'Test device',
      'downloadDirectory': '/tmp',
      'autoAcceptDefaultMigrated': true,
    }),
  );

  test(
    'queued camera changes preserve concurrent front, rear and screen edits',
    () async {
      final repository = _BlockingRepository(
        await SharedPreferences.getInstance(),
      );
      final container = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWith((ref) async => repository),
        ],
      );
      addTearDown(container.dispose);
      await container.read(settingsProvider.future);
      final controller = container.read(settingsProvider.notifier);
      final front = controller.saveChanges(
        (current) => current.copyWith(
          cameraCapture: current.cameraCapture.copyWith(
            front: current.cameraCapture.front.copyWith(resolution: 480),
          ),
        ),
      );
      await repository.entered.future;
      final back = controller.saveChanges(
        (current) => current.copyWith(
          cameraCapture: current.cameraCapture.copyWith(
            back: current.cameraCapture.back.copyWith(frameRate: 60),
          ),
        ),
      );
      final screen = controller.saveChanges(
        (current) => current.copyWith(
          screenCapture: current.screenCapture.copyWith(resolution: 720),
        ),
      );
      repository.release.complete();
      await Future.wait([front, back, screen]);
      final persisted = await repository.load();
      expect(persisted.cameraCapture.front.resolution, 480);
      expect(persisted.cameraCapture.back.frameRate, 60);
      expect(persisted.screenCapture.resolution, 720);
    },
  );
}
