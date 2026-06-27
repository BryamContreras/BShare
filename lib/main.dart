import 'dart:io';

import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/presentation/app.dart';
import 'package:args/args.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _historyBoxName = 'transfer_history';
const _mainHiveDirectory = 'hive';
const _viewerHiveDirectory = 'hive_viewer';
const _mainLegacyHiveProfile = 'bshare';
const _viewerLegacyHiveProfile = 'bshare_viewer';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final viewerDevice = _viewerDevice(args);
  await _initHive(
    hiveDirectoryName: viewerDevice == null
        ? _mainHiveDirectory
        : _viewerHiveDirectory,
    legacyProfileName: viewerDevice == null
        ? _mainLegacyHiveProfile
        : _viewerLegacyHiveProfile,
  );
  await Hive.openBox<String>(_historyBoxName);
  runApp(ProviderScope(child: BShareApp(initialViewerDevice: viewerDevice)));
}

Future<void> _initHive({
  required String hiveDirectoryName,
  required String legacyProfileName,
}) async {
  if (kIsWeb) {
    await Hive.initFlutter(hiveDirectoryName);
    return;
  }

  final supportDirectory = await getApplicationSupportDirectory();
  final hiveDirectory = Directory(
    p.join(supportDirectory.path, hiveDirectoryName),
  );
  await hiveDirectory.create(recursive: true);
  await _migrateLegacyHiveStorage(legacyProfileName, hiveDirectory);
  Hive.init(hiveDirectory.path);
}

Future<void> _migrateLegacyHiveStorage(
  String profileName,
  Directory hiveDirectory,
) async {
  try {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final legacyDirectory = Directory(
      p.join(documentsDirectory.path, profileName),
    );
    final targetHistory = File(
      p.join(hiveDirectory.path, '$_historyBoxName.hive'),
    );
    if (!await legacyDirectory.exists() || await targetHistory.exists()) {
      return;
    }

    final migratedFiles = <File>[];
    await for (final entity in legacyDirectory.list()) {
      if (entity is! File) continue;
      final fileName = p.basename(entity.path);
      if (!fileName.startsWith(_historyBoxName) || fileName.endsWith('.lock')) {
        continue;
      }
      final targetFile = File(p.join(hiveDirectory.path, fileName));
      await entity.copy(targetFile.path);
      migratedFiles.add(entity);
    }

    if (await targetHistory.exists()) {
      for (final file in migratedFiles) {
        await file.delete();
      }
      await _deleteLegacyLockFile(legacyDirectory);
      if (await legacyDirectory.exists() &&
          await legacyDirectory.list().isEmpty) {
        await legacyDirectory.delete();
      }
    }
  } catch (_) {
    // Migration is best-effort; startup should continue with the new app-data path.
  }
}

Future<void> _deleteLegacyLockFile(Directory legacyDirectory) async {
  final lockFile = File(p.join(legacyDirectory.path, '$_historyBoxName.lock'));
  if (await lockFile.exists()) {
    await lockFile.delete();
  }
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
