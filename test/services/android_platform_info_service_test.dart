import 'dart:async';

import 'package:bshare/src/infrastructure/services/android_platform_info_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('concurrent callers share one OS read and cache the result', () async {
    final ready = Completer<int>();
    var reads = 0;
    final platform = AndroidPlatformInfoService(
      isAndroid: true,
      readSdkInt: () {
        reads++;
        return ready.future;
      },
    );
    final requests = List.generate(12, (_) => platform.sdkInt());
    ready.complete(29);
    expect(await Future.wait(requests), everyElement(29));
    expect(await platform.sdkInt(), 29);
    expect(reads, 1);
  });

  test(
    'a failed OS read can be retried without caching a guessed SDK',
    () async {
      var reads = 0;
      final platform = AndroidPlatformInfoService(
        isAndroid: true,
        readSdkInt: () async {
          if (reads++ == 0) {
            throw PlatformException(code: 'temporarily-unavailable');
          }
          return 36;
        },
      );
      await expectLater(platform.sdkInt(), throwsA(isA<PlatformException>()));
      expect(await platform.sdkInt(), 36);
      expect(reads, 2);
    },
  );

  test('invalid OS values are rejected and not retained', () async {
    var reads = 0;
    final platform = AndroidPlatformInfoService(
      isAndroid: true,
      readSdkInt: () async => reads++ == 0 ? 0 : 24,
    );
    await expectLater(platform.sdkInt(), throwsStateError);
    expect(await platform.sdkInt(), 24);
  });

  test('non-Android callers never read the native channel', () async {
    var reads = 0;
    final platform = AndroidPlatformInfoService(
      isAndroid: false,
      readSdkInt: () async => ++reads,
    );
    await expectLater(platform.sdkInt(), throwsUnsupportedError);
    expect(reads, 0);
  });

  test(
    'production reader obtains the integer from the device channel',
    () async {
      const channel = MethodChannel('bshare/device');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getAndroidSdkInt');
        return 31;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      expect(await AndroidPlatformInfoService(isAndroid: true).sdkInt(), 31);
    },
  );
}
