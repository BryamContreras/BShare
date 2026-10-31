import 'dart:async';

import 'package:bshare/src/infrastructure/services/virtual_camera_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final virtualCameraServiceProvider = Provider((ref) {
  final service = VirtualCameraService();
  ref.onDispose(service.dispose);
  unawaited(service.refresh());
  return service;
});
