/// Hardware controls reported by the broadcasting camera. Unsupported values
/// are never replaced with a receiver-side image transformation.
class CameraNumericControl {
  const CameraNumericControl({
    this.supported = false,
    this.min = 0,
    this.max = 0,
    this.step = 0,
    this.value = 0,
    this.native = true,
  });

  final bool supported;
  final double min;
  final double max;
  final double step;
  final double value;
  final bool native;

  factory CameraNumericControl.fromMap(Object? source) {
    if (source is! Map ||
        source['supported'] != true ||
        source['native'] == false) {
      return const CameraNumericControl();
    }
    final minimum = _finite(source['min']);
    final maximum = _finite(source['max']);
    final current = _finite(source['value']);
    final increment = _finite(source['step']) ?? 0;
    if (minimum == null ||
        maximum == null ||
        current == null ||
        minimum >= maximum ||
        increment < 0) {
      return const CameraNumericControl();
    }
    return CameraNumericControl(
      supported: true,
      min: minimum,
      max: maximum,
      step: increment,
      value: current.clamp(minimum, maximum),
    );
  }

  bool accepts(double candidate) =>
      supported &&
      candidate.isFinite &&
      candidate >= min &&
      candidate <= max &&
      (step == 0 ||
          ((candidate - min) / step - ((candidate - min) / step).round())
                  .abs() <
              0.00001);

  Map<String, dynamic> toMap() => {
    'supported': supported,
    if (supported) ...{
      'min': min,
      'max': max,
      'step': step,
      'value': value,
      'native': native,
    },
  };
}

class CameraChoiceControl {
  const CameraChoiceControl({
    this.supported = false,
    this.modes = const [],
    this.value,
  });
  final bool supported;
  final List<String> modes;
  final String? value;

  factory CameraChoiceControl.fromMap(Object? source) {
    if (source is! Map ||
        source['supported'] != true ||
        source['modes'] is! List) {
      return const CameraChoiceControl();
    }
    final modes = (source['modes'] as List)
        .whereType<String>()
        .where((mode) => mode.isNotEmpty && mode.length <= 64)
        .toSet()
        .toList(growable: false);
    final value = source['value'];
    if (modes.isEmpty ||
        value is! String ||
        (!modes.contains(value) && value != 'off')) {
      return const CameraChoiceControl();
    }
    return CameraChoiceControl(
      supported: true,
      modes: List.unmodifiable(modes),
      value: value,
    );
  }

  Map<String, dynamic> toMap() => {
    'supported': supported,
    if (supported) ...{'modes': modes, 'value': value},
  };
}

/// Relative warm/cool capture-device control. It is deliberately not labelled
/// in Kelvin: Android exposes gains and a color transform, not calibrated CCT.
class CameraWhiteBalanceWarmthControl extends CameraNumericControl {
  const CameraWhiteBalanceWarmthControl({
    super.supported = false,
    super.min = -1,
    super.max = 1,
    super.step = 0,
    super.value = 0,
    super.native = true,
    this.mode = 'auto',
    this.unit = 'relative',
  });
  final String mode;
  final String unit;

  factory CameraWhiteBalanceWarmthControl.fromMap(Object? source) {
    final numeric = CameraNumericControl.fromMap(source);
    if (!numeric.supported ||
        source is! Map ||
        (source['mode'] != 'auto' && source['mode'] != 'manual') ||
        source['unit'] != 'relative') {
      return const CameraWhiteBalanceWarmthControl();
    }
    return CameraWhiteBalanceWarmthControl(
      supported: true,
      min: numeric.min,
      max: numeric.max,
      step: numeric.step,
      value: numeric.value,
      mode: source['mode'] as String,
      unit: 'relative',
    );
  }

  @override
  Map<String, dynamic> toMap() => {
    ...super.toMap(),
    if (supported) ...{'mode': mode, 'unit': unit},
  };
}

class CameraManualExposureControl {
  const CameraManualExposureControl({
    this.supported = false,
    this.mode = 'auto',
    this.timeMinMs = 0,
    this.timeMaxMs = 0,
    this.timeMs = 0,
    this.isoMin = 0,
    this.isoMax = 0,
    this.iso = 0,
  });
  final bool supported;
  final String mode;
  final double timeMinMs;
  final double timeMaxMs;
  final double timeMs;
  final int isoMin;
  final int isoMax;
  final int iso;

  factory CameraManualExposureControl.fromMap(Object? source) {
    if (source is! Map || source['supported'] != true) {
      return const CameraManualExposureControl();
    }
    final minimum = _finite(source['timeMinMs']);
    final maximum = _finite(source['timeMaxMs']);
    final current = _finite(source['timeMs']);
    final isoMin = _integer(source['isoMin']);
    final isoMax = _integer(source['isoMax']);
    final iso = _integer(source['iso']);
    final mode = source['mode'];
    if (minimum == null ||
        maximum == null ||
        current == null ||
        minimum <= 0 ||
        minimum >= maximum ||
        isoMin == null ||
        isoMax == null ||
        iso == null ||
        isoMin <= 0 ||
        isoMin >= isoMax ||
        (mode != 'auto' && mode != 'manual')) {
      return const CameraManualExposureControl();
    }
    return CameraManualExposureControl(
      supported: true,
      mode: mode as String,
      timeMinMs: minimum,
      timeMaxMs: maximum,
      timeMs: current.clamp(minimum, maximum),
      isoMin: isoMin,
      isoMax: isoMax,
      iso: iso.clamp(isoMin, isoMax),
    );
  }

  Map<String, dynamic> toMap() => {
    'supported': supported,
    if (supported) ...{
      'mode': mode,
      'timeMinMs': timeMinMs,
      'timeMaxMs': timeMaxMs,
      'timeMs': timeMs,
      'isoMin': isoMin,
      'isoMax': isoMax,
      'iso': iso,
    },
  };
}

class CameraControlDevice {
  const CameraControlDevice({
    required this.id,
    required this.label,
    required this.frontFacing,
    this.focalLengthMm,
  });
  final String id;
  final String label;
  final bool frontFacing;
  final double? focalLengthMm;

  static CameraControlDevice? fromMap(Object? source) {
    if (source is! Map) return null;
    final id = source['id'];
    final label = source['label'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 256 ||
        label is! String ||
        label.isEmpty) {
      return null;
    }
    return CameraControlDevice(
      id: id,
      label: label,
      frontFacing: source['frontFacing'] == true,
      focalLengthMm: _finite(source['focalLengthMm']),
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'label': label,
    'frontFacing': frontFacing,
    if (focalLengthMm != null) 'focalLengthMm': focalLengthMm,
  };
}

class CameraCaptureControls {
  const CameraCaptureControls({
    this.available = false,
    this.cameraId,
    this.trackId,
    this.zoom = const CameraNumericControl(),
    this.whiteBalance = const CameraChoiceControl(),
    this.whiteBalanceWarmth = const CameraWhiteBalanceWarmthControl(),
    this.exposure = const CameraNumericControl(),
    this.brightness = const CameraNumericControl(),
    this.manualExposure = const CameraManualExposureControl(),
    this.cameras = const [],
    this.observed = const {},
  });
  final bool available;
  final String? cameraId;
  final String? trackId;
  final CameraNumericControl zoom;
  final CameraChoiceControl whiteBalance;
  final CameraWhiteBalanceWarmthControl whiteBalanceWarmth;

  /// Device auto-exposure compensation in EV, rather than a pixel brightness filter.
  final CameraNumericControl exposure;

  /// An independent device brightness property, only if the backend exposes one.
  final CameraNumericControl brightness;
  final CameraManualExposureControl manualExposure;

  /// Public camera IDs the driver advertises, including exposed physical lenses.
  final List<CameraControlDevice> cameras;

  /// Actual sensor capture-result fields provided by the native backend.
  final Map<String, dynamic> observed;

  factory CameraCaptureControls.fromMap(Object? source) {
    if (source is! Map || source['ready'] == false) {
      return const CameraCaptureControls();
    }
    final cameraId = source['cameraId'];
    final devices = source['cameras'] ?? source['lenses'];
    final seen = <String>{};
    final cameras = devices is List
        ? devices
              .map(CameraControlDevice.fromMap)
              .whereType<CameraControlDevice>()
              .where((camera) => seen.add(camera.id))
              .toList(growable: false)
        : const <CameraControlDevice>[];
    final zoom = CameraNumericControl.fromMap(source['zoom']);
    final rawObserved = source['observed'];
    final observed = <String, dynamic>{};
    if (rawObserved is Map) {
      for (final key in const [
        'frameNumber',
        'zoom',
        'zoomRatio',
        'exposure',
        'exposureCompensation',
        'exposureTimeMs',
        'iso',
        'whiteBalance',
        'activePhysicalId',
        'activePhysicalCameraId',
        'focalLengthMm',
        'aeMode',
        'awbMode',
        'whiteBalanceWarmth',
        'colorCorrectionMode',
      ]) {
        final value = rawObserved[key];
        if ((value is num && value.isFinite) ||
            (value is String && value.length <= 256)) {
          observed[key] = value;
        }
      }
      final gains = rawObserved['whiteBalanceGains'];
      if (gains is List &&
          gains.length == 4 &&
          gains.every((value) => value is num && value.isFinite && value > 0)) {
        observed['whiteBalanceGains'] = List<double>.unmodifiable(
          gains.map((value) => (value as num).toDouble()),
        );
      }
      final transform = rawObserved['colorCorrectionTransform'];
      if (transform is List &&
          transform.length == 9 &&
          transform.every((value) => value is num && value.isFinite)) {
        observed['colorCorrectionTransform'] = List<double>.unmodifiable(
          transform.map((value) => (value as num).toDouble()),
        );
      }
    }
    return CameraCaptureControls(
      available:
          source['ready'] != false &&
          (source['available'] == true || cameraId is String),
      cameraId: cameraId is String ? cameraId : null,
      trackId: source['trackId'] is String ? source['trackId'] as String : null,
      zoom: zoom.min > 0 ? zoom : const CameraNumericControl(),
      whiteBalance: CameraChoiceControl.fromMap(source['whiteBalance']),
      whiteBalanceWarmth: CameraWhiteBalanceWarmthControl.fromMap(
        source['whiteBalanceWarmth'],
      ),
      exposure: CameraNumericControl.fromMap(source['exposure']),
      brightness: CameraNumericControl.fromMap(source['brightness']),
      manualExposure: CameraManualExposureControl.fromMap(
        source['manualExposure'],
      ),
      cameras: List.unmodifiable(cameras),
      observed: Map.unmodifiable(observed),
    );
  }

  Map<String, dynamic> toMap() => {
    'available': available,
    'cameraId': cameraId,
    'trackId': trackId,
    'zoom': zoom.toMap(),
    'whiteBalance': whiteBalance.toMap(),
    'whiteBalanceWarmth': whiteBalanceWarmth.toMap(),
    'exposure': exposure.toMap(),
    'brightness': brightness.toMap(),
    'manualExposure': manualExposure.toMap(),
    'cameras': cameras.map((camera) => camera.toMap()).toList(growable: false),
    if (observed.isNotEmpty) 'observed': observed,
  };
}

double? _finite(Object? value) =>
    value is num && value.isFinite ? value.toDouble() : null;
int? _integer(Object? value) =>
    value is num && value.isFinite && value == value.roundToDouble()
    ? value.toInt()
    : null;
