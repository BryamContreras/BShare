import 'screen_capture_settings.dart';
import 'camera_capture_settings.dart';

class AppSettings {
  const AppSettings({
    required this.deviceId,
    required this.deviceName,
    required this.downloadDirectory,
    required this.autoAccept,
    required this.preferredPort,
    required this.themeMode,
    required this.languageCode,
    this.screenCapture = const ScreenCaptureSettings(),
    this.cameraCapture = const CameraCaptureSettings(),
  });

  final String deviceId;
  final String deviceName;
  final String downloadDirectory;
  final bool autoAccept;
  final int preferredPort;
  final String themeMode;
  final String languageCode;
  final ScreenCaptureSettings screenCapture;
  final CameraCaptureSettings cameraCapture;

  AppSettings copyWith({
    String? deviceId,
    String? deviceName,
    String? downloadDirectory,
    bool? autoAccept,
    int? preferredPort,
    String? themeMode,
    String? languageCode,
    ScreenCaptureSettings? screenCapture,
    CameraCaptureSettings? cameraCapture,
  }) {
    return AppSettings(
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      downloadDirectory: downloadDirectory ?? this.downloadDirectory,
      autoAccept: autoAccept ?? this.autoAccept,
      preferredPort: preferredPort ?? this.preferredPort,
      themeMode: themeMode ?? this.themeMode,
      languageCode: languageCode ?? this.languageCode,
      screenCapture: screenCapture ?? this.screenCapture,
      cameraCapture: cameraCapture ?? this.cameraCapture,
    );
  }
}
