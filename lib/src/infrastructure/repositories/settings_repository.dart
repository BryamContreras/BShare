import 'dart:io';

import 'package:bshare/src/domain/entities/app_settings.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class SettingsRepository {
  SettingsRepository(this._prefs);

  static const _deviceChannel = MethodChannel('bshare/device');

  final SharedPreferences _prefs;

  static const _deviceId = 'deviceId';
  static const _deviceName = 'deviceName';
  static const _downloadDirectory = 'downloadDirectory';
  static const _autoAccept = 'autoAccept';
  static const _autoAcceptDefaultMigrated = 'autoAcceptDefaultMigrated';
  static const _preferredPort = 'preferredPort';
  static const _themeMode = 'themeMode';
  static const _languageCode = 'languageCode';
  static const _androidDownloadDirectory = '/storage/emulated/0/Download';

  Future<AppSettings> load() async {
    var id = _prefs.getString(_deviceId);
    if (id == null) {
      id = const Uuid().v4();
      await _prefs.setString(_deviceId, id);
    }

    var downloadDirectory = _prefs.getString(_downloadDirectory);
    if (downloadDirectory == null ||
        downloadDirectory.isEmpty ||
        (Platform.isAndroid &&
            (downloadDirectory.contains('/Android/data/') ||
                _isLegacyAndroidDownloadDirectory(downloadDirectory)))) {
      downloadDirectory = await defaultDownloadDirectory();
      await _prefs.setString(_downloadDirectory, downloadDirectory);
    }

    if (!(_prefs.getBool(_autoAcceptDefaultMigrated) ?? false)) {
      await _prefs.setBool(_autoAccept, true);
      await _prefs.setBool(_autoAcceptDefaultMigrated, true);
    }

    var deviceName = _prefs.getString(_deviceName)?.trim();
    if (deviceName == null ||
        deviceName.isEmpty ||
        _shouldReplaceDefaultDeviceName(deviceName)) {
      deviceName = await _defaultDeviceName();
      await _prefs.setString(_deviceName, deviceName);
    }

    return AppSettings(
      deviceId: id,
      deviceName: deviceName,
      downloadDirectory: downloadDirectory,
      autoAccept: _prefs.getBool(_autoAccept) ?? true,
      preferredPort: _prefs.getInt(_preferredPort) ?? 53317,
      themeMode: _prefs.getString(_themeMode) ?? 'system',
      languageCode: _prefs.getString(_languageCode) ?? 'en',
    );
  }

  bool _shouldReplaceDefaultDeviceName(String value) {
    if (!Platform.isAndroid) return false;
    final normalized = value.trim().toLowerCase();
    return normalized == 'localhost' || normalized == 'localhost.localdomain';
  }

  Future<String> _defaultDeviceName() async {
    if (Platform.isAndroid) {
      try {
        final name = await _deviceChannel.invokeMethod<String>('getDeviceName');
        if (name != null && name.trim().isNotEmpty) return name.trim();
      } catch (_) {}
    }
    final hostname = Platform.localHostname.trim();
    if (hostname.isNotEmpty && !_shouldReplaceDefaultDeviceName(hostname)) {
      return hostname;
    }
    return Platform.isAndroid ? 'Android' : 'BShare';
  }

  Future<void> save(AppSettings settings) async {
    await _prefs.setString(_deviceId, settings.deviceId);
    await _prefs.setString(_deviceName, settings.deviceName);
    await _prefs.setString(_downloadDirectory, settings.downloadDirectory);
    await _prefs.setBool(_autoAccept, settings.autoAccept);
    await _prefs.setInt(_preferredPort, settings.preferredPort);
    await _prefs.setString(_themeMode, settings.themeMode);
    await _prefs.setString(_languageCode, settings.languageCode);
  }

  Future<String> defaultDownloadDirectory() async {
    if (Platform.isAndroid || Platform.isIOS) {
      if (Platform.isAndroid) {
        return Directory(_androidDownloadDirectory).path;
      }
      final dir = await getApplicationDocumentsDirectory();
      return Directory('${dir.path}${Platform.pathSeparator}BShare').path;
    }
    final downloads = await getDownloadsDirectory();
    final base = downloads ?? await getApplicationDocumentsDirectory();
    return Directory('${base.path}${Platform.pathSeparator}BShare').path;
  }

  bool _isLegacyAndroidDownloadDirectory(String path) {
    final normalized = path
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    return normalized == '/storage/emulated/0/BShare' ||
        normalized == '/sdcard/BShare' ||
        normalized == '/storage/emulated/0/Download/BShare' ||
        normalized == '/sdcard/Download/BShare';
  }
}
