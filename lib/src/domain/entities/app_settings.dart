class AppSettings {
  const AppSettings({
    required this.deviceId,
    required this.deviceName,
    required this.downloadDirectory,
    required this.autoAccept,
    required this.preferredPort,
    required this.themeMode,
    required this.languageCode,
  });

  final String deviceId;
  final String deviceName;
  final String downloadDirectory;
  final bool autoAccept;
  final int preferredPort;
  final String themeMode;
  final String languageCode;

  AppSettings copyWith({
    String? deviceId,
    String? deviceName,
    String? downloadDirectory,
    bool? autoAccept,
    int? preferredPort,
    String? themeMode,
    String? languageCode,
  }) {
    return AppSettings(
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      downloadDirectory: downloadDirectory ?? this.downloadDirectory,
      autoAccept: autoAccept ?? this.autoAccept,
      preferredPort: preferredPort ?? this.preferredPort,
      themeMode: themeMode ?? this.themeMode,
      languageCode: languageCode ?? this.languageCode,
    );
  }
}
