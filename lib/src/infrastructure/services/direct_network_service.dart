import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bshare/src/domain/entities/direct_share_invite.dart';
import 'package:bshare/src/infrastructure/services/android_platform_info_service.dart';
import 'package:bshare/src/infrastructure/services/permission_request_coordinator.dart';
import 'package:bshare/src/infrastructure/services/process_runner.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

class DirectNetworkService {
  DirectNetworkService({
    ProcessRunner? processRunner,
    AndroidPlatformInfoService? platformInfo,
    PermissionRequestCoordinator? permissionCoordinator,
    Future<PermissionStatus> Function(Permission)? readPermissionStatus,
  }) : _processRunner = processRunner ?? const ProcessRunner(),
       _androidPlatformInfo =
           platformInfo ?? AndroidPlatformInfoService.instance,
       _permissionCoordinator =
           permissionCoordinator ?? PermissionRequestCoordinator.instance,
       _readPermissionStatus =
           readPermissionStatus ?? ((permission) => permission.status);

  static const _channel = MethodChannel('bshare/direct_network');
  static final _random = Random.secure();

  Process? _windowsHotspotProcess;
  StreamSubscription<String>? _windowsHotspotStdout;
  StreamSubscription<String>? _windowsHotspotStderr;
  StringBuffer? _windowsHotspotStderrBuffer;
  Future<void>? _windowsHotspotStdoutDone;
  Future<void>? _windowsHotspotStderrDone;
  String? _linuxHotspotConnectionName;
  final ProcessRunner _processRunner;
  final AndroidPlatformInfoService _androidPlatformInfo;
  final PermissionRequestCoordinator _permissionCoordinator;
  final Future<PermissionStatus> Function(Permission) _readPermissionStatus;
  Future<void>? _disposal;
  Future<DirectNetworkCredentials>? _hotspotStart;
  Future<void>? _hotspotStop;

  Future<DirectNetworkCredentials> startLocalOnlyHotspot() {
    if (_disposal != null) {
      return Future.error(StateError('Direct network service is disposed'));
    }
    return _hotspotStart ??= _startLocalOnlyHotspot().whenComplete(() {
      _hotspotStart = null;
    });
  }

  Future<DirectNetworkCredentials> _startLocalOnlyHotspot() async {
    await _hotspotStop;
    if (_disposal != null) {
      throw StateError('Direct network service is disposed');
    }
    if (!_androidPlatformInfo.isAndroid) {
      if (Platform.isWindows) return _startWindowsLegacyHotspot();
      if (Platform.isLinux) return _startLinuxNmcliHotspot();
    }
    _ensureAndroid();
    return _startAndroidLocalOnlyHotspot();
  }

  Future<DirectNetworkCredentials> _startAndroidLocalOnlyHotspot() async {
    final sdkInt = await _androidPlatformInfo.sdkInt();
    _ensureActive();
    if (sdkInt < 26) {
      throw UnsupportedError(
        'Local-only hotspot requires Android 8.0 or newer',
      );
    }
    await _requirePermission(
      sdkInt >= 33
          ? Permission.nearbyWifiDevices
          : Permission.locationWhenInUse,
    );
    _ensureActive();
    final raw = await _channel.invokeMapMethod<String, Object?>(
      'startLocalOnlyHotspot',
    );
    if (raw == null) {
      throw StateError('Android did not return hotspot credentials');
    }
    final credentials = DirectNetworkCredentials.fromJson(raw);
    if (credentials.ssid.isEmpty) {
      throw StateError('Android returned an empty hotspot name');
    }
    return credentials;
  }

  Future<void> stopLocalOnlyHotspot() {
    return _hotspotStop ??= _stopLocalOnlyHotspot().whenComplete(() {
      _hotspotStop = null;
    });
  }

  Future<void> _stopLocalOnlyHotspot() async {
    try {
      await _hotspotStart;
    } catch (_) {
      // Starting already reports its own failure; still finish any cleanup.
    }
    if (!_androidPlatformInfo.isAndroid) {
      if (Platform.isWindows) {
        await _stopWindowsLegacyHotspot();
        return;
      }
      if (Platform.isLinux) {
        await _stopLinuxNmcliHotspot();
        return;
      }
      return;
    }
    await _channel.invokeMethod<void>('stopLocalOnlyHotspot');
  }

  Future<void> connectToWifi(DirectNetworkCredentials credentials) async {
    _ensureAndroid();
    _ensureActive();
    final sdkInt = await _androidPlatformInfo.sdkInt();
    _ensureActive();
    if (sdkInt >= 29) {
      // MainActivity uses startScan + WifiNetworkSpecifier on this path.
      // startScan still requires location on Android 13 and newer; nearby
      // Wi-Fi access does not replace that permission.
      await _requirePermission(Permission.locationWhenInUse);
      _ensureActive();
    }
    await _channel.invokeMethod<void>('connectToWifi', credentials.toJson());
  }

  Future<void> openWifiJoinSettings(
    DirectNetworkCredentials credentials,
  ) async {
    _ensureAndroid();
    _ensureActive();
    await _channel.invokeMethod<void>(
      'openWifiJoinSettings',
      credentials.toJson(),
    );
  }

  Future<bool> ensureWifiReady() async {
    if (!_androidPlatformInfo.isAndroid) return false;
    _ensureActive();
    return await _channel.invokeMethod<bool>('ensureWifiReady') ?? false;
  }

  Future<void> openWifiPanel() async {
    _ensureAndroid();
    _ensureActive();
    await _channel.invokeMethod<void>('openWifiPanel');
  }

  Future<bool> bindToCurrentWifi() async {
    if (!_androidPlatformInfo.isAndroid) return false;
    _ensureActive();
    return await _channel.invokeMethod<bool>('bindToCurrentWifi') ?? false;
  }

  Future<bool> bindToWifiForHost({
    required String host,
    required int port,
    String path = '/api/ping',
  }) async {
    if (!_androidPlatformInfo.isAndroid) return false;
    _ensureActive();
    return await _channel.invokeMethod<bool>('bindToWifiForHost', {
          'host': host,
          'port': port,
          'path': path,
        }) ??
        false;
  }

  Future<void> disconnectWifi() async {
    if (!_androidPlatformInfo.isAndroid) return;
    await _channel.invokeMethod<void>('disconnectWifi');
  }

  Future<DirectNetworkCredentials> _startWindowsLegacyHotspot() async {
    await _stopWindowsLegacyHotspot();
    final credentials = DirectNetworkCredentials(
      ssid: 'BShare-${_randomToken(6)}',
      password: _randomPassword(),
      securityType: 'WPA2',
    );
    final process = await Process.start('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-EncodedCommand',
      _encodePowerShell(_windowsLegacyHotspotScript(credentials)),
    ]);
    _windowsHotspotProcess = process;
    _windowsHotspotStderrBuffer = StringBuffer();
    final stderrDone = Completer<void>();
    _windowsHotspotStderrDone = stderrDone.future;
    _windowsHotspotStderr = process.stderr
        .transform(systemEncoding.decoder)
        .listen(
          _windowsHotspotStderrBuffer!.write,
          onError: (Object error) {
            _windowsHotspotStderrBuffer?.write(error);
          },
          onDone: stderrDone.complete,
        );

    final started = Completer<Map<String, dynamic>>();
    final stdoutBuffer = StringBuffer();
    final stdoutDone = Completer<void>();
    _windowsHotspotStdoutDone = stdoutDone.future;
    _windowsHotspotStdout = process.stdout
        .transform(systemEncoding.decoder)
        .listen(
          (chunk) {
            stdoutBuffer.write(chunk);
            final lines = stdoutBuffer.toString().split(RegExp(r'\r?\n'));
            stdoutBuffer
              ..clear()
              ..write(lines.removeLast());
            for (final line in lines) {
              final decoded = _tryDecodeJsonLine(line);
              if (decoded != null && !started.isCompleted) {
                started.complete(decoded);
              }
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!started.isCompleted) {
              started.completeError(error, stackTrace);
            }
          },
          onDone: () {
            stdoutDone.complete();
            if (!started.isCompleted) {
              final decoded = _tryDecodeJsonLine(stdoutBuffer.toString());
              if (decoded != null) started.complete(decoded);
            }
          },
        );

    unawaited(
      process.exitCode.then((exitCode) async {
        await Future.wait([stdoutDone.future, stderrDone.future]);
        if (started.isCompleted) return;
        final errorText = _windowsHotspotStderrBuffer?.toString().trim();
        started.completeError(
          StateError(
            'Windows hotspot exited before it started'
            '${errorText?.isEmpty == false ? ': $errorText' : ''}',
          ),
        );
      }),
    );

    late final Map<String, dynamic> raw;
    try {
      raw = await started.future.timeout(const Duration(seconds: 20));
    } on Object {
      await terminateProcess(process);
      await _clearWindowsProcessHandles();
      rethrow;
    }

    if (raw['ok'] != true) {
      final error = raw['error']?.toString() ?? 'Unknown Windows hotspot error';
      await _stopWindowsLegacyHotspot();
      throw StateError(error);
    }
    return DirectNetworkCredentials.fromJson(raw);
  }

  Future<DirectNetworkCredentials> _startLinuxNmcliHotspot() async {
    await _stopLinuxNmcliHotspot();
    await _ensureLinuxNmcliReady();
    await _deleteStaleLinuxHotspots();
    await _runNmcli(['radio', 'wifi', 'on']);

    final interfaceName = await _findLinuxHotspotInterface();
    final connectionName = 'BShare-Hotspot-${_randomToken(5)}';
    final credentials = DirectNetworkCredentials(
      ssid: 'BShare-${_randomToken(6)}',
      password: _randomPassword(),
      securityType: 'WPA2',
    );

    _linuxHotspotConnectionName = connectionName;
    try {
      await _runNmcli([
        'device',
        'wifi',
        'hotspot',
        'ifname',
        interfaceName,
        'con-name',
        connectionName,
        'ssid',
        credentials.ssid,
        'password',
        credentials.password,
      ], timeout: const Duration(seconds: 35));
      await _runNmcli([
        'connection',
        'modify',
        connectionName,
        'connection.autoconnect',
        'no',
        'ipv4.method',
        'shared',
        'ipv6.method',
        'disabled',
      ], allowFailure: true);
      await _ensureLinuxHotspotSecurity(connectionName);
      await _ensureLinuxHotspotHasAddress(interfaceName);
      return credentials;
    } catch (_) {
      await _stopLinuxNmcliHotspot();
      rethrow;
    }
  }

  Future<void> _stopWindowsLegacyHotspot() async {
    final process = _windowsHotspotProcess;
    if (process == null) return;
    try {
      process.stdin.writeln('stop');
      await process.stdin.flush();
      await process.stdin.close();
      await process.exitCode.timeout(const Duration(seconds: 8));
    } catch (_) {
      await terminateProcess(process);
    } finally {
      await _clearWindowsProcessHandles();
    }
  }

  Future<void> _clearWindowsProcessHandles() async {
    try {
      await _windowsHotspotProcess?.stdin.close();
    } catch (_) {}
    await Future.wait([?_windowsHotspotStdoutDone, ?_windowsHotspotStderrDone]);
    await _windowsHotspotStdout?.cancel();
    await _windowsHotspotStderr?.cancel();
    _windowsHotspotStdout = null;
    _windowsHotspotStderr = null;
    _windowsHotspotStderrBuffer = null;
    _windowsHotspotStdoutDone = null;
    _windowsHotspotStderrDone = null;
    _windowsHotspotProcess = null;
  }

  Future<void> _stopLinuxNmcliHotspot() async {
    final connectionName = _linuxHotspotConnectionName;
    if (connectionName == null) return;
    await _runNmcli(['connection', 'down', connectionName], allowFailure: true);
    await _runNmcli([
      'connection',
      'delete',
      connectionName,
    ], allowFailure: true);
    _linuxHotspotConnectionName = null;
  }

  Future<void> _deleteStaleLinuxHotspots() async {
    final result = await _runNmcli([
      '-t',
      '-f',
      'NAME',
      'connection',
      'show',
    ], allowFailure: true);
    if (result.exitCode != 0) return;
    final names = result.stdout
        .toString()
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.startsWith('BShare-Hotspot-'))
        .toSet();
    for (final name in names) {
      await _runNmcli(['connection', 'down', name], allowFailure: true);
      await _runNmcli(['connection', 'delete', name], allowFailure: true);
    }
  }

  Future<String> _findLinuxHotspotInterface() async {
    final result = await _runNmcli([
      '-t',
      '-f',
      'DEVICE,TYPE,STATE',
      'device',
      'status',
    ]);
    final wifiDevices = <String>[];
    for (final line in result.stdout.toString().split(RegExp(r'\r?\n'))) {
      if (line.trim().isEmpty) continue;
      final fields = _splitNmcliLine(line);
      if (fields.length < 3 || fields[1] != 'wifi') continue;
      if (fields[2] == 'unavailable' || fields[2] == 'unmanaged') continue;
      wifiDevices.add(fields[0]);
    }
    if (wifiDevices.isEmpty) {
      throw StateError('No NetworkManager Wi-Fi adapter is available');
    }
    for (final device in wifiDevices) {
      if (await _linuxDeviceSupportsAp(device)) return device;
    }
    throw StateError('The Wi-Fi adapter does not support hotspot/AP mode');
  }

  Future<void> _ensureLinuxNmcliReady() async {
    await _runNmcli(['--version'], timeout: const Duration(seconds: 5));

    final running = await _runNmcli([
      '-t',
      '-f',
      'RUNNING',
      'general',
    ], timeout: const Duration(seconds: 5));
    if (running.stdout.toString().trim().toLowerCase() != 'running') {
      throw StateError(
        'NetworkManager is not running. Start it with: '
        'sudo systemctl enable --now NetworkManager',
      );
    }

    final permissions = await _runNmcli(
      ['-t', '-f', 'PERMISSION,VALUE', 'general', 'permissions'],
      allowFailure: true,
      timeout: const Duration(seconds: 5),
    );
    if (permissions.exitCode != 0) return;

    final denied = _deniedLinuxNmPermissions(permissions.stdout.toString());
    if (denied.isNotEmpty) {
      throw StateError(
        'This Linux user is not allowed to manage NetworkManager '
        'connections (${denied.join(', ')}). Configure polkit permissions '
        'or run BShare from a desktop session with a polkit agent.',
      );
    }
  }

  List<String> _deniedLinuxNmPermissions(String output) {
    const requiredPermissions = {
      'org.freedesktop.NetworkManager.enable-disable-wifi',
      'org.freedesktop.NetworkManager.network-control',
      'org.freedesktop.NetworkManager.settings.modify.system',
    };
    final denied = <String>[];
    for (final line in output.split(RegExp(r'\r?\n'))) {
      if (line.trim().isEmpty) continue;
      final fields = _splitNmcliLine(line);
      if (fields.length < 2) continue;
      final permission = fields[0];
      final value = fields[1].toLowerCase();
      if (requiredPermissions.contains(permission) && value == 'no') {
        denied.add(permission);
      }
    }
    return denied;
  }

  Future<bool> _linuxDeviceSupportsAp(String interfaceName) async {
    final result = await _runNmcli([
      '-g',
      'WIFI-PROPERTIES.AP',
      'device',
      'show',
      interfaceName,
    ], allowFailure: true);
    if (result.exitCode != 0) return false;
    return result.stdout.toString().trim().toLowerCase() == 'yes';
  }

  Future<void> _ensureLinuxHotspotSecurity(String connectionName) async {
    final result = await _runNmcli([
      '-g',
      '802-11-wireless-security.key-mgmt',
      'connection',
      'show',
      connectionName,
    ], allowFailure: true);
    if (result.exitCode != 0) return;
    final keyManagement = result.stdout.toString().trim().toLowerCase();
    if (keyManagement != 'wpa-psk') {
      throw StateError(
        'NetworkManager did not create a WPA/WPA2 hotspot safely',
      );
    }
  }

  Future<void> _ensureLinuxHotspotHasAddress(String interfaceName) async {
    for (var attempt = 0; attempt < 10; attempt++) {
      final result = await _runNmcli(
        ['-g', 'IP4.ADDRESS', 'device', 'show', interfaceName],
        allowFailure: true,
        timeout: const Duration(seconds: 5),
      );
      if (result.stdout.toString().trim().isNotEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    throw StateError(
      'NetworkManager created the hotspot but did not assign an IPv4 '
      'address. Install dnsmasq-base and check NetworkManager shared IPv4 '
      'support.',
    );
  }

  Future<ProcessResult> _runNmcli(
    List<String> arguments, {
    bool allowFailure = false,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      final result = await _processRunner.run(
        'nmcli',
        arguments,
        timeout: timeout,
        environment: {'LC_ALL': 'C'},
      );
      if (result.exitCode != 0 && !allowFailure) {
        throw StateError(_nmcliError(arguments, result));
      }
      return result;
    } on ProcessException catch (error) {
      if (allowFailure) {
        return ProcessResult(0, 127, '', error.message);
      }
      throw StateError(
        'NetworkManager/nmcli is required to create a Linux hotspot',
      );
    } on TimeoutException {
      if (allowFailure) {
        return ProcessResult(0, 124, '', 'nmcli timed out');
      }
      throw StateError('NetworkManager timed out while creating the hotspot');
    }
  }

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    try {
      await stopLocalOnlyHotspot();
    } finally {
      await disconnectWifi();
    }
  }

  String _nmcliError(List<String> arguments, ProcessResult result) {
    final output = [
      result.stderr.toString().trim(),
      result.stdout.toString().trim(),
    ].where((text) => text.isNotEmpty).join(' ');
    final help = _linuxNmcliHelp(output);
    return 'nmcli ${_redactedNmcliArguments(arguments)} failed'
        '${output.isEmpty ? '' : ': $output'}'
        '${help == null ? '' : ' $help'}';
  }

  String? _linuxNmcliHelp(String output) {
    final lower = output.toLowerCase();
    if (lower.contains('not authorized') ||
        lower.contains('authorization') ||
        lower.contains('permission denied')) {
      return 'Allow this user to manage NetworkManager through polkit.';
    }
    if (lower.contains('networkmanager is not running') ||
        lower.contains('networkmanager is not active')) {
      return 'Start it with: sudo systemctl enable --now NetworkManager.';
    }
    if (lower.contains('dnsmasq')) {
      return 'Install dnsmasq-base; NetworkManager uses it for hotspot DHCP.';
    }
    if (lower.contains('rfkill') || lower.contains('wi-fi is disabled')) {
      return 'Unblock Wi-Fi and enable the radio before starting receiver.';
    }
    if (lower.contains('no suitable device') ||
        lower.contains('not a wi-fi device') ||
        lower.contains('does not support ap')) {
      return 'Use a physical Wi-Fi adapter with AP/hotspot support.';
    }
    return null;
  }

  String _redactedNmcliArguments(List<String> arguments) {
    final redacted = [...arguments];
    for (var index = 0; index < redacted.length - 1; index++) {
      if (redacted[index] == 'password') redacted[index + 1] = '***';
    }
    return redacted.join(' ');
  }

  List<String> _splitNmcliLine(String line) {
    final fields = <String>[];
    final current = StringBuffer();
    var escaped = false;
    for (final codeUnit in line.codeUnits) {
      final character = String.fromCharCode(codeUnit);
      if (escaped) {
        current.write(character);
        escaped = false;
      } else if (character == '\\') {
        escaped = true;
      } else if (character == ':') {
        fields.add(current.toString());
        current.clear();
      } else {
        current.write(character);
      }
    }
    fields.add(current.toString());
    return fields;
  }

  Map<String, dynamic>? _tryDecodeJsonLine(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) return null;
    try {
      final decoded = jsonDecode(trimmed);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  String _windowsLegacyHotspotScript(DirectNetworkCredentials credentials) {
    final ssid = _psQuote(credentials.ssid);
    final password = _psQuote(credentials.password);
    return '''
\$ErrorActionPreference = 'Stop'
\$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
[Windows.Devices.WiFiDirect.WiFiDirectAdvertisementPublisher,Windows.Devices.WiFiDirect,ContentType=WindowsRuntime] | Out-Null
[Windows.Security.Credentials.PasswordCredential,Windows.Security.Credentials,ContentType=WindowsRuntime] | Out-Null

\$publisher = \$null
try {
  \$publisher = [Windows.Devices.WiFiDirect.WiFiDirectAdvertisementPublisher]::new()
  \$publisher.Advertisement.IsAutonomousGroupOwnerEnabled = \$true
  \$publisher.Advertisement.LegacySettings.IsEnabled = \$true
  \$publisher.Advertisement.LegacySettings.Ssid = $ssid
  \$credential = [Windows.Security.Credentials.PasswordCredential]::new()
  \$credential.Password = $password
  \$publisher.Advertisement.LegacySettings.Passphrase = \$credential
  \$publisher.Start()
  for (\$i = 0; \$i -lt 30; \$i++) {
    if (\$publisher.Status.ToString() -ne 'Created') { break }
    Start-Sleep -Milliseconds 200
  }
  \$status = \$publisher.Status.ToString()
  if (\$status -ne 'Started') {
    throw "Windows Wi-Fi Direct hotspot did not start. Status: \$status"
  }
  [pscustomobject]@{
    ok = \$true
    ssid = $ssid
    password = $password
    securityType = 'WPA2'
    status = \$status
  } | ConvertTo-Json -Compress
  [Console]::Out.Flush()
  [void][Console]::In.ReadLine()
} catch {
  [pscustomobject]@{
    ok = \$false
    error = \$_.Exception.Message
  } | ConvertTo-Json -Compress
  [Console]::Out.Flush()
} finally {
  if (\$null -ne \$publisher) {
    try { \$publisher.Stop() } catch {}
  }
}
''';
  }

  String _randomToken(int length) {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    return List.generate(
      length,
      (_) => chars[_random.nextInt(chars.length)],
    ).join();
  }

  String _randomPassword() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
    return List.generate(
      14,
      (_) => chars[_random.nextInt(chars.length)],
    ).join();
  }

  String _psQuote(String value) => "'${value.replaceAll("'", "''")}'";

  String _encodePowerShell(String script) {
    final bytes = <int>[];
    for (final codeUnit in script.codeUnits) {
      bytes
        ..add(codeUnit & 0xff)
        ..add(codeUnit >> 8);
    }
    return base64Encode(bytes);
  }

  Future<void> _requirePermission(Permission permission) async {
    final status = await _permissionCoordinator.request(permission);
    // The first location result may describe coarse access even if the user
    // denied fine access. Recheck the full permission group without opening
    // another dialog, and never cache a grant across protected operations.
    if (!status.isGranted ||
        !(await _readPermissionStatus(permission)).isGranted) {
      throw StateError('Wi-Fi permission was denied: $permission');
    }
  }

  void _ensureActive() {
    if (_disposal != null) {
      throw StateError('Direct network service is disposed');
    }
  }

  void _ensureAndroid() {
    if (!_androidPlatformInfo.isAndroid) {
      throw UnsupportedError(
        'BShare direct network is only supported on Android, Windows, and Linux',
      );
    }
  }
}
