import 'package:bshare/src/infrastructure/services/android_screen_share_execution_service.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('focused viewer state switches between preview and focused UI', () {
    final service = ScreenShareService(
      const AppLogger(),
      AndroidScreenShareExecutionService(),
    );
    addTearDown(() async => service.dispose());

    expect(service.focusedViewerActive.value, isFalse);

    service.setFocusedViewerActive(true);
    expect(service.focusedViewerActive.value, isTrue);

    service.setFocusedViewerActive(false);
    expect(service.focusedViewerActive.value, isFalse);
  });
}
