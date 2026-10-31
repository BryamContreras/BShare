import 'dart:math';

import 'package:webrtc_interface/webrtc_interface.dart';

import 'utils.dart';

enum CameraFocusMode { auto, locked }

enum CameraExposureMode { auto, locked }

class CameraUtils {
  static Future<Map<String, dynamic>> getCameraCaptureControls(
      MediaStreamTrack videoTrack) async {
    if (!WebRTC.platformIsAndroid) return {'available': true};
    final result = await WebRTC.invokeMethod<dynamic, dynamic>(
        'getCameraCaptureControls', {'trackId': videoTrack.id});
    if (result is! Map)
      throw StateError('Camera controls returned no capabilities');
    return Map<String, dynamic>.from(result);
  }

  static Future<Map<String, dynamic>> setCameraCaptureControls(
      MediaStreamTrack videoTrack, Map<String, dynamic> settings) async {
    if (!WebRTC.platformIsAndroid) {
      throw UnsupportedError(
          'Native capture controls are not available on this platform');
    }
    final result = await WebRTC.invokeMethod<dynamic, dynamic>(
        'setCameraCaptureControls',
        {'trackId': videoTrack.id, 'settings': settings});
    if (result is! Map)
      throw StateError('Camera controls returned no confirmed state');
    return Map<String, dynamic>.from(result);
  }

  static Future<void> setZoom(
      MediaStreamTrack videoTrack, double zoomLevel) async {
    if (WebRTC.platformIsAndroid || WebRTC.platformIsIOS) {
      await WebRTC.invokeMethod(
        'mediaStreamTrackSetZoom',
        <String, dynamic>{'trackId': videoTrack.id, 'zoomLevel': zoomLevel},
      );
    } else {
      throw Exception('setZoom only support for mobile devices!');
    }
  }

  /// Set the exposure point for the camera, focusMode can be:
  /// 'auto', 'locked'
  static Future<void> setFocusMode(
      MediaStreamTrack videoTrack, CameraFocusMode focusMode) async {
    if (WebRTC.platformIsAndroid || WebRTC.platformIsIOS) {
      await WebRTC.invokeMethod(
        'mediaStreamTrackSetFocusMode',
        <String, dynamic>{
          'trackId': videoTrack.id,
          'focusMode': focusMode.name,
        },
      );
    } else {
      throw Exception('setFocusMode only support for mobile devices!');
    }
  }

  static Future<void> setFocusPoint(
      MediaStreamTrack videoTrack, Point<double>? point) async {
    if (WebRTC.platformIsAndroid || WebRTC.platformIsIOS) {
      await WebRTC.invokeMethod(
        'mediaStreamTrackSetFocusPoint',
        <String, dynamic>{
          'trackId': videoTrack.id,
          'focusPoint': {
            'reset': point == null,
            'x': point?.x,
            'y': point?.y,
          },
        },
      );
    } else {
      throw Exception('setFocusPoint only support for mobile devices!');
    }
  }

  static Future<void> setExposureMode(
      MediaStreamTrack videoTrack, CameraExposureMode exposureMode) async {
    if (WebRTC.platformIsAndroid || WebRTC.platformIsIOS) {
      await WebRTC.invokeMethod(
        'mediaStreamTrackSetExposureMode',
        <String, dynamic>{
          'trackId': videoTrack.id,
          'exposureMode': exposureMode.name,
        },
      );
    } else {
      throw Exception('setExposureMode only support for mobile devices!');
    }
  }

  static Future<void> setExposurePoint(
      MediaStreamTrack videoTrack, Point<double>? point) async {
    if (WebRTC.platformIsAndroid || WebRTC.platformIsIOS) {
      await WebRTC.invokeMethod(
        'mediaStreamTrackSetExposurePoint',
        <String, dynamic>{
          'trackId': videoTrack.id,
          'exposurePoint': {
            'reset': point == null,
            'x': point?.x,
            'y': point?.y,
          },
        },
      );
    } else {
      throw Exception('setExposurePoint only support for mobile devices!');
    }
  }
}
