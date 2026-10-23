import 'dart:convert';

import 'package:bshare/src/domain/entities/camera_capture_settings.dart';
import 'package:bshare/src/domain/entities/screen_capture_settings.dart';
import 'package:bshare/src/infrastructure/repositories/settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  test('front, rear and physical camera settings are independent', () {
    final config = const CameraCaptureSettings()
        .copyWith(
          front: const ScreenCaptureSettings(resolution: 480, frameRate: 15),
          back: const ScreenCaptureSettings(resolution: 1440, frameRate: 60),
        )
        .withCamera(
          'rear-wide',
          const ScreenCaptureSettings(resolution: 720, frameRate: 24),
        );

    expect(config.forCamera(frontFacing: true).resolution, 480);
    expect(config.forCamera(frontFacing: false).resolution, 1440);
    expect(
      config.forCamera(frontFacing: false, deviceId: 'rear-wide').resolution,
      720,
    );
    expect(
      config.forCamera(frontFacing: false, deviceId: 'rear-tele').frameRate,
      60,
    );
    expect(
      config
          .withoutCamera('rear-wide')
          .forCamera(frontFacing: false, deviceId: 'rear-wide')
          .resolution,
      1440,
    );
    expect(config.devices.containsKey('rear-wide'), isTrue);
    expect(() => config.devices.clear(), throwsUnsupportedError);
  });

  test(
    'every camera profile validates supported resolution and at most 60 FPS',
    () {
      final config = const CameraCaptureSettings(
        front: ScreenCaptureSettings(resolution: -1, frameRate: 120),
        back: ScreenCaptureSettings(resolution: 0, frameRate: 60),
        devices: {
          'wide': ScreenCaptureSettings(resolution: 999, frameRate: -1),
          ' ': ScreenCaptureSettings(),
        },
      ).validated;

      expect(config.front.resolution, 1080);
      expect(config.front.frameRate, 30);
      expect(config.back.resolution, 0);
      expect(config.back.frameRate, 60);
      expect(config.devices['wide']!.resolution, 1080);
      expect(config.devices['wide']!.frameRate, 30);
      expect(config.devices.containsKey(' '), isFalse);
      for (final fps in ScreenCaptureSettings.frameRates) {
        expect(fps, lessThanOrEqualTo(60));
      }
    },
  );

  test('malformed JSON values retain valid independent camera fields', () {
    final config = CameraCaptureSettings.fromJson({
      'front': {'resolution': 720, 'frameRate': '60'},
      'back': false,
      'devices': {
        7: {'resolution': 480, 'frameRate': 15},
        ' ': {'resolution': 480, 'frameRate': 15},
        'invalid': [1, 2],
        'rear': {'resolution': '1080', 'frameRate': 60},
      },
    });
    expect(config.front.resolution, 720);
    expect(config.front.frameRate, 30);
    expect(config.back.resolution, 1080);
    expect(config.devices.keys, ['rear']);
    expect(config.devices['rear']!.resolution, 1080);
    expect(config.devices['rear']!.frameRate, 60);
    expect(CameraCaptureSettings.fromJson([]).front.frameRate, 30);
  });

  test('legacy preferences use independent camera defaults', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('screenResolution', 480);
    await prefs.setInt('screenFrameRate', 15);
    final settings = await SettingsRepository(prefs).load();

    expect(settings.screenCapture.resolution, 480);
    expect(settings.cameraCapture.front.resolution, 1080);
    expect(settings.cameraCapture.back.frameRate, 30);
    expect(settings.cameraCapture.devices, isEmpty);
  });

  test('camera choices persist without modifying screen limits', () async {
    final prefs = await SharedPreferences.getInstance();
    final repository = SettingsRepository(prefs);
    final original = await repository.load();
    final camera = const CameraCaptureSettings()
        .copyWith(
          front: const ScreenCaptureSettings(resolution: 480, frameRate: 15),
          back: const ScreenCaptureSettings(resolution: 1440, frameRate: 60),
        )
        .withCamera(
          'rear-wide',
          const ScreenCaptureSettings(resolution: 720, frameRate: 24),
        );
    await repository.save(original.copyWith(cameraCapture: camera));
    final loaded = await repository.load();

    expect(loaded.cameraCapture.toJson(), camera.toJson());
    expect(loaded.screenCapture.resolution, 1080);
    expect(loaded.screenCapture.frameRate, 30);
    expect(
      jsonDecode(prefs.getString('cameraCaptureSettings')!),
      camera.toJson(),
    );
  });

  test(
    'invalid stored camera JSON or preference type safely uses defaults',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final repository = SettingsRepository(prefs);
      for (final invalid in ['{broken', 'null', '[]', '"text"']) {
        await prefs.setString('cameraCaptureSettings', invalid);
        expect((await repository.load()).cameraCapture.back.frameRate, 30);
      }
      await prefs.setInt('cameraCaptureSettings', 123);
      final settings = await repository.load();
      expect(settings.cameraCapture.front.resolution, 1080);
      await repository.save(settings);
      expect(prefs.get('cameraCaptureSettings'), isA<String>());
    },
  );
}
