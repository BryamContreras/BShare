import 'package:bshare/src/domain/entities/camera_capture_controls.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> numeric({
    double min = 0.6,
    double max = 10,
    double step = 0,
    double value = 1,
  }) => {
    'supported': true,
    'native': true,
    'min': min,
    'max': max,
    'step': step,
    'value': value,
  };

  test('retains a real device sub-one zoom range and actual state', () {
    final controls = CameraCaptureControls.fromMap({
      'cameraId': '0',
      'zoom': numeric(value: 0.7),
      'exposure': numeric(min: -2, max: 2, step: 1 / 3, value: 0),
    });
    expect(controls.available, isTrue);
    expect(controls.zoom.min, .6);
    expect(controls.zoom.value, .7);
    expect(controls.zoom.accepts(.7123), isTrue);
    expect(controls.exposure.accepts(1 / 3), isTrue);
    expect(controls.exposure.accepts(.2), isFalse);
    expect(controls.exposure.accepts(double.nan), isFalse);
  });

  test('unknown, opening and native unsupported are distinct', () {
    expect(CameraCaptureControls.fromMap(null).available, isFalse);
    expect(
      CameraCaptureControls.fromMap({
        'cameraId': '0',
        'ready': false,
        'zoom': numeric(),
      }).available,
      isFalse,
    );
    final unsupported = CameraCaptureControls.fromMap({
      'available': true,
      'cameraId': '0',
    });
    expect(unsupported.available, isTrue);
    expect(unsupported.zoom.supported, isFalse);
    expect(unsupported.brightness.supported, isFalse);
  });

  test('malformed device values do not create usable slider ranges', () {
    for (final values in [
      numeric(min: 0),
      numeric(max: double.infinity),
      numeric(max: .6),
      numeric(step: -1),
      {...numeric(), 'native': false},
    ]) {
      expect(
        CameraCaptureControls.fromMap({
          'cameraId': '0',
          'zoom': values,
        }).zoom.supported,
        isFalse,
      );
    }
  });

  test(
    'manual shutter and ISO retain advertised hardware limits and units',
    () {
      final controls = CameraCaptureControls.fromMap({
        'cameraId': '0',
        'manualExposure': {
          'supported': true,
          'mode': 'manual',
          'timeMinMs': .1,
          'timeMaxMs': 100,
          'timeMs': 12.5,
          'isoMin': 50,
          'isoMax': 3200,
          'iso': 400,
        },
      });
      expect(controls.manualExposure.supported, isTrue);
      expect(controls.manualExposure.timeMs, 12.5);
      expect(controls.manualExposure.iso, 400);
      final invalid = CameraCaptureControls.fromMap({
        'cameraId': '0',
        'manualExposure': {...controls.manualExposure.toMap(), 'isoMax': 50},
      });
      expect(invalid.manualExposure.supported, isFalse);
    },
  );

  test(
    'public cameras and safe observed capture-result fields survive wire round-trip',
    () {
      final value = CameraCaptureControls.fromMap({
        'cameraId': '2',
        'zoom': numeric(),
        'whiteBalance': {
          'supported': true,
          'modes': ['auto', 'daylight'],
          'value': 'daylight',
        },
        'lenses': [
          {
            'id': '2',
            'label': 'Rear 3x',
            'frontFacing': false,
            'focalLengthMm': 7.9,
          },
          {'id': '2', 'label': 'Duplicate', 'frontFacing': false},
          {'label': 'Invalid'},
        ],
        'observed': {
          'frameNumber': 12,
          'zoom': 1.7,
          'activePhysicalCameraId': '3',
          'iso': 400,
          'arbitraryPrivateData': 'drop',
          'exposureTimeMs': double.nan,
        },
      });
      final restored = CameraCaptureControls.fromMap(value.toMap());
      expect(restored.cameraId, '2');
      expect(restored.cameras, hasLength(1));
      expect(restored.cameras.single.focalLengthMm, 7.9);
      expect(restored.whiteBalance.value, 'daylight');
      expect(restored.observed, {
        'frameNumber': 12,
        'zoom': 1.7,
        'activePhysicalCameraId': '3',
        'iso': 400,
      });
    },
  );

  test(
    'manual warm/cool values keep real gain observations and permit restoring AWB',
    () {
      final controls = CameraCaptureControls.fromMap({
        'cameraId': '0',
        'whiteBalance': {
          'supported': true,
          'modes': ['auto', 'daylight'],
          'value': 'off',
        },
        'whiteBalanceWarmth': {
          'supported': true,
          'min': -1.0,
          'max': 1.0,
          'step': 0.0,
          'value': .37,
          'mode': 'manual',
          'unit': 'relative',
        },
        'observed': {
          'whiteBalanceWarmth': .37,
          'colorCorrectionMode': 0,
          'whiteBalanceGains': [1.3, 1.0, 1.0, .8],
          'colorCorrectionTransform': [1, 0, 0, 0, 1, 0, 0, 0, 1],
        },
      });
      expect(controls.whiteBalance.supported, isTrue);
      expect(controls.whiteBalance.value, 'off');
      expect(controls.whiteBalance.modes, contains('auto'));
      expect(controls.whiteBalanceWarmth.supported, isTrue);
      expect(controls.whiteBalanceWarmth.mode, 'manual');
      expect(controls.whiteBalanceWarmth.value, .37);
      expect(controls.whiteBalanceWarmth.unit, 'relative');
      final restored = CameraCaptureControls.fromMap(controls.toMap());
      expect(restored.observed['whiteBalanceGains'], [1.3, 1.0, 1.0, .8]);
      expect(restored.observed['colorCorrectionTransform'], hasLength(9));
      expect(restored.whiteBalanceWarmth.accepts(.37111), isTrue);
    },
  );
}
