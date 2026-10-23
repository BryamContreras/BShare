import 'dart:async';
import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/camera_connection_mode.dart';
import 'package:bshare/src/domain/entities/camera_device.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/localization/camera_localizations.dart';
import 'package:bshare/src/presentation/localization/camera_ui_localizations.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:bshare/src/presentation/screens/camera_viewer_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class CameraShareScreen extends ConsumerStatefulWidget {
  const CameraShareScreen({super.key});

  @override
  ConsumerState<CameraShareScreen> createState() => _CameraShareScreenState();
}

class _CameraShareScreenState extends ConsumerState<CameraShareScreen>
    with WidgetsBindingObserver {
  final _scrollController = ScrollController();
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '53317');
  CameraConnectionMode _connection = CameraConnectionMode.wifi;
  List<CameraDevice> _cameras = const [];
  String? _cameraId;
  String? _selectedDeviceId;
  bool _loadingCameras = false;
  bool _watchBusy = false;
  bool _viewerOpen = false;
  DeviceInfo? _viewerDevice;
  List<String>? _viewerLocalIps;
  String? _cameraError;
  late final ScreenShareService _service;

  bool get _mobile {
    final platform = Theme.of(context).platform;
    return platform == TargetPlatform.android || platform == TargetPlatform.iOS;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _service = ref.read(screenShareServiceProvider);
    _connection =
        ref.read(cameraSessionProvider).connection ?? CameraConnectionMode.wifi;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_mobile) {
        unawaited(_loadCameras());
      } else {
        unawaited(ref.read(discoveryProvider.notifier).start());
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        mounted &&
        _connection == CameraConnectionMode.usb) {
      ref.invalidate(usbCameraNetworkProvider);
    }
  }

  Future<void> _loadCameras({bool refresh = false}) async {
    if (_loadingCameras) return;
    setState(() {
      _loadingCameras = true;
      _cameraError = null;
    });
    try {
      if (refresh) ref.invalidate(cameraDevicesProvider);
      final cameras = await ref.read(cameraDevicesProvider.future);
      if (!mounted) return;
      final currentId = _service.currentCamera?.id ?? _cameraId;
      setState(() {
        _cameras = cameras;
        _cameraId = cameras.any((camera) => camera.id == currentId)
            ? currentId
            : cameras.where((camera) => !camera.frontFacing).firstOrNull?.id ??
                  cameras.firstOrNull?.id;
      });
    } catch (error) {
      if (!mounted) return;
      ref.read(loggerProvider).warn('Could not enumerate cameras: $error');
      setState(
        () => _cameraError = context.l10n.cameraText('camerasUnavailable'),
      );
    } finally {
      if (mounted) setState(() => _loadingCameras = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final session = ref.watch(cameraSessionProvider);
    final settings = ref.watch(settingsProvider).value;
    final devices = ref.watch(discoveryProvider);
    final discovery = ref.watch(discoveryStatusProvider);
    final selectedDevice = devices
        .where((device) => device.id == _selectedDeviceId)
        .firstOrNull;
    final selectedCamera = _cameras
        .where((camera) => camera.id == _cameraId)
        .firstOrNull;
    final usb = _connection == CameraConnectionMode.usb
        ? ref.watch(usbCameraNetworkProvider)
        : null;
    final receiver = ref.watch(receiveControllerProvider).value;
    final busy = session.busy || _watchBusy;

    return ValueListenableBuilder<ScreenShareState>(
      valueListenable: _service.state,
      builder: (context, state, _) {
        if (_viewerOpen) {
          return FocusedCameraViewer(
            device: _viewerDevice,
            allowedLocalIps: _viewerLocalIps,
            onClose: () async {
              if (!mounted) return;
              setState(() {
                _viewerOpen = false;
                _viewerDevice = null;
                _viewerLocalIps = null;
              });
            },
          );
        }
        final cameraSession = _service.source == VideoShareSource.camera;
        final sharing = cameraSession && state.mode == ScreenShareMode.sharing;
        final watching =
            cameraSession && state.mode == ScreenShareMode.watching;
        final idle = state.mode == ScreenShareMode.idle;
        final camera = sharing ? _service.currentCamera : selectedCamera;
        final config = sharing
            ? _service.captureSettings
            : camera == null
            ? null
            : settings?.cameraCapture.forCamera(
                frontFacing: camera.frontFacing,
              );

        return AppShell(
          title: l10n.cameraText('deviceCamera'),
          scrollController: _scrollController,
          child: ListView(
            controller: _scrollController,
            padding: const EdgeInsets.all(12),
            children: [
              SegmentedButton<CameraConnectionMode>(
                segments: [
                  ButtonSegment(
                    value: CameraConnectionMode.wifi,
                    icon: const Icon(Icons.wifi_rounded),
                    label: Text(l10n.cameraUiText('wifi')),
                  ),
                  ButtonSegment(
                    value: CameraConnectionMode.usb,
                    icon: const Icon(Icons.usb_rounded),
                    label: Text(l10n.cameraUiText('usb')),
                  ),
                ],
                selected: {_connection},
                onSelectionChanged: !idle || busy
                    ? null
                    : (selection) {
                        setState(() => _connection = selection.single);
                        if (_connection == CameraConnectionMode.usb) {
                          ref.invalidate(usbCameraNetworkProvider);
                        } else if (!_mobile) {
                          unawaited(
                            ref.read(discoveryProvider.notifier).start(),
                          );
                        }
                      },
              ),
              const SizedBox(height: 12),
              Text(
                l10n.cameraUiText(
                  _connection == CameraConnectionMode.wifi
                      ? 'wifiHelp'
                      : 'usbHelp',
                ),
              ),
              const SizedBox(height: 16),
              if (!idle && !cameraSession)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.screen_share_rounded),
                    title: Text(l10n.cameraUiText('cameraBusy')),
                    trailing: IconButton(
                      tooltip: l10n.cameraUiText('openScreenSession'),
                      onPressed: () => context.go('/screen'),
                      icon: const Icon(Icons.arrow_forward_rounded),
                    ),
                  ),
                ),
              if (_mobile) ...[
                if (_loadingCameras) const LinearProgressIndicator(),
                if (_cameras.isNotEmpty)
                  DropdownButtonFormField<String>(
                    key: ValueKey('camera-choice-${camera?.id}'),
                    initialValue: camera?.id,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: l10n.cameraUiText('camera'),
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      for (final option in _cameras)
                        DropdownMenuItem(
                          value: option.id,
                          child: Text(
                            _cameraLabel(option),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: busy || (!idle && !sharing)
                        ? null
                        : (id) {
                            final option = _cameras
                                .where((camera) => camera.id == id)
                                .firstOrNull;
                            if (option != null) {
                              unawaited(_chooseCamera(option));
                            }
                          },
                  )
                else if (!_loadingCameras)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.videocam_off_rounded),
                      title: Text(
                        _cameraError ?? l10n.cameraText('camerasUnavailable'),
                      ),
                      trailing: IconButton(
                        tooltip: l10n.cameraUiText('retry'),
                        onPressed: busy
                            ? null
                            : () => _loadCameras(refresh: true),
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                    ),
                  ),
                if (config != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: busy ? null : () => context.go('/settings'),
                      icon: const Icon(Icons.tune_rounded, size: 18),
                      label: Text(
                        '${config.resolution == 0 ? l10n.t('screenNativeResolution') : '${config.resolution}p'} · ${config.frameRate} FPS',
                      ),
                    ),
                  ),
                if (sharing)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.videocam_rounded),
                      title: Text(l10n.cameraUiText('cameraSharing')),
                      trailing: IconButton.filledTonal(
                        key: const ValueKey('camera-open-broadcast'),
                        tooltip: l10n.cameraUiText('openBroadcast'),
                        onPressed: busy ? null : _openBroadcast,
                        icon: const Icon(Icons.fullscreen_rounded),
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Text(
                  l10n.cameraUiText('awakeHelp'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (_connection == CameraConnectionMode.usb) ...[
                const SizedBox(height: 12),
                if (_mobile)
                  Row(
                    children: [
                      if (Platform.isAndroid)
                        Expanded(
                          child: TextButton.icon(
                            onPressed: busy ? null : _openUsbSettings,
                            icon: const Icon(Icons.settings_ethernet_rounded),
                            label: Text(l10n.cameraUiText('openUsbSettings')),
                          ),
                        )
                      else
                        const Spacer(),
                      IconButton(
                        tooltip: l10n.t('refreshDevices'),
                        onPressed: busy
                            ? null
                            : () => ref.invalidate(usbCameraNetworkProvider),
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                    ],
                  ),
                if (_mobile)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: usb!.when(
                        loading: () => const LinearProgressIndicator(),
                        error: (_, _) =>
                            Text(l10n.cameraUiText('usbUnavailable')),
                        data: (snapshot) => Text(
                          snapshot.addresses.isEmpty
                              ? l10n.cameraUiText('usbUnavailable')
                              : '${l10n.cameraUiText('usbAddress')}:\n${snapshot.addresses.map((address) => address.ip).join('\n')}\n${l10n.cameraUiText('port')}: ${receiver?.port ?? settings?.preferredPort ?? 53317}',
                        ),
                      ),
                    ),
                  )
                else
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        children: [
                          TextField(
                            key: const ValueKey('camera-usb-host'),
                            controller: _hostController,
                            enabled: idle && !busy,
                            keyboardType: TextInputType.url,
                            autocorrect: false,
                            decoration: InputDecoration(
                              labelText: l10n.cameraUiText('host'),
                              hintText: '192.168.42.129',
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            key: const ValueKey('camera-usb-port'),
                            controller: _portController,
                            enabled: idle && !busy,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: l10n.cameraUiText('port'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
              if (!_mobile &&
                  idle &&
                  _connection == CameraConnectionMode.wifi) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.t('availableDevices'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: l10n.t('refreshDevices'),
                      onPressed: discovery.isSearching || busy
                          ? null
                          : () =>
                                ref.read(discoveryProvider.notifier).refresh(),
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ],
                ),
                if (discovery.isSearching) const LinearProgressIndicator(),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(l10n.cameraUiText('chooseDevice')),
                ),
                for (final device in devices)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.smartphone_rounded),
                      title: Text(device.name),
                      subtitle: Text('${device.ip}:${device.port}'),
                      trailing: Icon(
                        device.id == _selectedDeviceId
                            ? Icons.check_circle_rounded
                            : Icons.circle_outlined,
                      ),
                      selected: device.id == _selectedDeviceId,
                      onTap: busy
                          ? null
                          : () => setState(() => _selectedDeviceId = device.id),
                    ),
                  ),
              ],
              if (watching)
                ListTile(
                  title: Text(l10n.cameraUiText('cameraWatching')),
                  trailing: IconButton.filledTonal(
                    tooltip: l10n.cameraUiText('openViewer'),
                    onPressed: () => setState(() => _viewerOpen = true),
                    icon: const Icon(Icons.fullscreen_rounded),
                  ),
                ),
              if ((cameraSession && state.error != null) ||
                  session.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    l10n.cameraUiText(session.error ?? 'cameraFailed'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              if (sharing || watching)
                FilledButton.icon(
                  key: const ValueKey('camera-stop'),
                  onPressed: busy ? null : _stop,
                  icon: const Icon(Icons.stop_rounded),
                  label: Text(l10n.cameraUiText('stop')),
                  style: _actionStyle(),
                )
              else if (_mobile)
                FilledButton.icon(
                  key: const ValueKey('camera-share'),
                  onPressed: !idle || busy || selectedCamera == null
                      ? null
                      : () => _start(selectedCamera),
                  icon: const Icon(Icons.videocam_rounded),
                  label: Text(l10n.cameraUiText('shareCamera')),
                  style: _actionStyle(),
                )
              else
                FilledButton.icon(
                  key: const ValueKey('camera-watch'),
                  onPressed:
                      !idle ||
                          busy ||
                          (_connection == CameraConnectionMode.wifi &&
                              selectedDevice == null)
                      ? null
                      : () => _watch(selectedDevice),
                  icon: const Icon(Icons.visibility_rounded),
                  label: Text(l10n.cameraUiText('watchCamera')),
                  style: _actionStyle(),
                ),
            ],
          ),
        );
      },
    );
  }

  ButtonStyle _actionStyle() => FilledButton.styleFrom(
    minimumSize: const Size(0, 52),
    shape: const StadiumBorder(),
  );

  String _cameraLabel(CameraDevice camera) {
    final kind = context.l10n.cameraText(
      camera.frontFacing ? 'frontCamera' : 'backCamera',
    );
    return kind;
  }

  Future<void> _chooseCamera(CameraDevice camera) async {
    try {
      if (_service.source == VideoShareSource.camera &&
          _service.state.value.mode == ScreenShareMode.sharing) {
        await ref.read(cameraSessionProvider.notifier).switchCamera(camera);
      }
      if (mounted) setState(() => _cameraId = camera.id);
    } catch (error) {
      _showFailure('cameraSwitchFailed', error);
    }
  }

  void _openBroadcast() => context.go('/camera/live');

  Future<void> _start(CameraDevice camera) async {
    final controller = ref.read(cameraSessionProvider.notifier);
    try {
      await controller.start(connection: _connection, camera: camera);
      if (!mounted) {
        await controller.stop();
        return;
      }
      _openBroadcast();
    } catch (error) {
      _showFailure('cameraFailed', error);
    }
  }

  Future<void> _openUsbSettings() async {
    try {
      await ref.read(usbCameraNetworkServiceProvider).openUsbSettings();
      if (mounted) ref.invalidate(usbCameraNetworkProvider);
    } catch (error) {
      _showFailure('usbUnavailable', error);
    }
  }

  Future<void> _watch(DeviceInfo? selected) async {
    if (_watchBusy) return;
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    final connection = _connection;
    if (connection == CameraConnectionMode.usb &&
        (InternetAddress.tryParse(host) == null ||
            port == null ||
            port < 1 ||
            port > 65535)) {
      _showMessage('invalidAddress');
      return;
    }
    setState(() => _watchBusy = true);
    try {
      List<String>? allowedLocalIps;
      final device = connection == CameraConnectionMode.wifi
          ? selected!
          : DeviceInfo(
              id: 'usb-camera-$host:$port',
              name: host,
              platform: 'mobile',
              ip: host,
              port: port!,
              lastSeen: DateTime.now(),
            );
      if (connection == CameraConnectionMode.usb) {
        final usb = await ref.read(usbCameraNetworkProvider.future);
        if (!mounted) return;
        if (!usb.containsRemote(host)) {
          _showMessage('usbUnavailable');
          return;
        }
        allowedLocalIps = usb.localIps;
      }
      if (!mounted) return;
      setState(() {
        _viewerDevice = device;
        _viewerLocalIps = allowedLocalIps;
        _viewerOpen = true;
      });
    } catch (error) {
      _showFailure('watchFailed', error);
    } finally {
      if (mounted) setState(() => _watchBusy = false);
    }
  }

  Future<void> _stop() async {
    if (_service.source != VideoShareSource.camera) return;
    try {
      if (_service.state.value.mode == ScreenShareMode.sharing) {
        await ref.read(cameraSessionProvider.notifier).stop();
      } else {
        await _service.stopWatching();
      }
    } catch (error) {
      _showFailure('cameraFailed', error);
    }
  }

  void _showFailure(String key, Object error) {
    if (!mounted) return;
    ref.read(loggerProvider).warn('Camera action failed: $error');
    _showMessage(key);
  }

  void _showMessage(String key) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(context.l10n.cameraUiText(key))));
  }
}
