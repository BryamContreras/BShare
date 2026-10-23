import 'dart:async';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/screen_capture_settings.dart';
import 'package:bshare/src/infrastructure/repositories/settings_repository.dart';
import 'package:bshare/src/domain/entities/app_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Repository extends SettingsRepository {
  _Repository(super.prefs);
  final entered = Completer<void>();
  final release = Completer<void>();
  var saves = 0;
  var active = 0;
  var maximumActive = 0;

  @override
  Future<void> save(AppSettings settings) async {
    active++;
    if (active > maximumActive) maximumActive = active;
    if (saves++ == 0) {
      entered.complete();
      await release.future;
    }
    try {
      await super.save(settings);
    } finally {
      active--;
    }
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
    'resolution caps preserve orientation, proportions and avoid upscaling',
    () {
      const options = ScreenCaptureSettings(resolution: 720, frameRate: 24);
      expect(options.scaleFor(1080, 2316), 1.5);
      expect(options.scaleFor(2316, 1080), 1.5);
      expect(options.scaleFor(640, 360), 1);
      expect(options.scaleFor(double.nan, 1080), 1);
      expect(
        const ScreenCaptureSettings(resolution: 0).scaleFor(1440, 3088),
        1,
      );
      expect(
        options.maxBitrate,
        lessThan(const ScreenCaptureSettings().maxBitrate),
      );
    },
  );

  test(
    'old and invalid preferences load supported defaults; choices persist',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final repository = SettingsRepository(prefs);
      final legacy = await repository.load();
      expect(legacy.screenCapture.resolution, 1080);
      expect(legacy.screenCapture.frameRate, 30);
      await prefs.setInt('screenResolution', -1);
      await prefs.setInt('screenFrameRate', 999);
      final invalid = await repository.load();
      expect(invalid.screenCapture.resolution, 1080);
      expect(invalid.screenCapture.frameRate, 30);
      await repository.save(
        legacy.copyWith(
          screenCapture: const ScreenCaptureSettings(
            resolution: 720,
            frameRate: 60,
          ),
        ),
      );
      final loaded = await repository.load();
      expect(loaded.screenCapture.resolution, 720);
      expect(loaded.screenCapture.frameRate, 60);
    },
  );

  test(
    'overlapping setting changes preserve both choices without parallel writes',
    () async {
      final repository = _Repository(await SharedPreferences.getInstance());
      final container = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWith((ref) async => repository),
        ],
      );
      addTearDown(container.dispose);
      await container.read(settingsProvider.future);
      final controller = container.read(settingsProvider.notifier);
      final first = controller.saveChanges(
        (current) => current.copyWith(
          screenCapture: current.screenCapture.copyWith(resolution: 720),
        ),
      );
      await repository.entered.future;
      final second = controller.saveChanges(
        (current) => current.copyWith(
          screenCapture: current.screenCapture.copyWith(frameRate: 60),
        ),
      );
      repository.release.complete();
      await Future.wait([first, second]);
      expect(repository.maximumActive, 1);
      expect(
        container.read(settingsProvider).value!.screenCapture.resolution,
        720,
      );
      expect(
        container.read(settingsProvider).value!.screenCapture.frameRate,
        60,
      );
      expect((await repository.load()).screenCapture.frameRate, 60);
    },
  );

  test(
    'loading legacy preferences preserves a disabled automatic receive choice',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('autoAcceptDefaultMigrated');
      await prefs.setBool('autoAccept', false);
      final settings = await SettingsRepository(prefs).load();
      expect(settings.autoAccept, isFalse);
    },
  );
}
