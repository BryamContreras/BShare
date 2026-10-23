import 'screen_capture_settings.dart';

/// Camera limits are independent from screen sharing. Physical-device settings
/// override the front/rear defaults only when explicitly configured.
class CameraCaptureSettings {
  const CameraCaptureSettings({
    this.front = const ScreenCaptureSettings(),
    this.back = const ScreenCaptureSettings(),
    this.devices = const {},
  });

  final ScreenCaptureSettings front;
  final ScreenCaptureSettings back;
  final Map<String, ScreenCaptureSettings> devices;

  ScreenCaptureSettings forCamera({
    required bool frontFacing,
    String? deviceId,
  }) => (devices[deviceId] ?? (frontFacing ? front : back)).validated;

  CameraCaptureSettings copyWith({
    ScreenCaptureSettings? front,
    ScreenCaptureSettings? back,
    Map<String, ScreenCaptureSettings>? devices,
  }) => CameraCaptureSettings(
    front: front ?? this.front,
    back: back ?? this.back,
    devices: devices ?? this.devices,
  ).validated;

  CameraCaptureSettings withCamera(String id, ScreenCaptureSettings config) =>
      copyWith(devices: {...devices, id: config});

  CameraCaptureSettings withoutCamera(String id) =>
      copyWith(devices: Map.of(devices)..remove(id));

  CameraCaptureSettings get validated => CameraCaptureSettings(
    front: front.validated,
    back: back.validated,
    devices: Map.unmodifiable({
      for (final entry in devices.entries)
        if (entry.key.trim().isNotEmpty) entry.key: entry.value.validated,
    }),
  );

  factory CameraCaptureSettings.fromJson(Object? json) {
    if (json is! Map) return const CameraCaptureSettings();
    final devices = json['devices'];
    final parsedDevices = <String, ScreenCaptureSettings>{};
    if (devices is Map) {
      for (final entry in devices.entries) {
        final id = entry.key;
        if (id is! String || id.trim().isEmpty) continue;
        final config = _configFromJson(entry.value);
        if (config != null) parsedDevices[id] = config;
      }
    }
    return CameraCaptureSettings(
      front: _configFromJson(json['front']) ?? const ScreenCaptureSettings(),
      back: _configFromJson(json['back']) ?? const ScreenCaptureSettings(),
      devices: parsedDevices,
    ).validated;
  }

  Map<String, Object> toJson() {
    final config = validated;
    final ids = config.devices.keys.toList()..sort();
    return {
      'front': _configToJson(config.front),
      'back': _configToJson(config.back),
      'devices': {for (final id in ids) id: _configToJson(config.devices[id]!)},
    };
  }

  static ScreenCaptureSettings? _configFromJson(Object? value) {
    if (value is! Map) return null;
    return ScreenCaptureSettings(
      resolution: value['resolution'] is int
          ? value['resolution'] as int
          : 1080,
      frameRate: value['frameRate'] is int ? value['frameRate'] as int : 30,
    ).validated;
  }

  static Map<String, int> _configToJson(ScreenCaptureSettings value) => {
    'resolution': value.resolution,
    'frameRate': value.frameRate,
  };
}
