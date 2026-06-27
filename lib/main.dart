import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/presentation/app.dart';
import 'package:args/args.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final viewerDevice = _viewerDevice(args);
  await Hive.initFlutter(viewerDevice == null ? 'bshare' : 'bshare_viewer');
  await Hive.openBox<String>('transfer_history');
  runApp(ProviderScope(child: BShareApp(initialViewerDevice: viewerDevice)));
}

DeviceInfo? _viewerDevice(List<String> args) {
  final parser = ArgParser()
    ..addOption('viewer-ip')
    ..addOption('viewer-port')
    ..addOption('viewer-name');
  final parsed = parser.parse(args);
  final ip = parsed['viewer-ip'] as String?;
  final port = int.tryParse(parsed['viewer-port'] as String? ?? '');
  if (ip == null || port == null) return null;
  return DeviceInfo(
    id: 'external-viewer',
    name: Uri.decodeComponent(
      parsed['viewer-name'] as String? ?? 'Remote screen',
    ),
    platform: 'Remote',
    ip: Uri.decodeComponent(ip),
    port: port,
    lastSeen: DateTime.now(),
  );
}
