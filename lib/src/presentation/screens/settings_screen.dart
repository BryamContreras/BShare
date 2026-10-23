import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/app_settings.dart';
import 'package:bshare/src/domain/entities/screen_capture_settings.dart';
import 'package:bshare/src/infrastructure/services/android_storage_access_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/localization/camera_localizations.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:bshare/src/presentation/widgets/settings_section.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _nameController = TextEditingController();
  final _portController = TextEditingController();
  final _scrollController = ScrollController();
  bool _controllersInitialized = false;

  @override
  void dispose() {
    _nameController.dispose();
    _portController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _initControllers(AppSettings data) {
    if (_controllersInitialized) return;
    _controllersInitialized = true;
    _nameController.text = data.deviceName;
    _portController.text = data.preferredPort.toString();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final l10n = context.l10n;
    final platform = Theme.of(context).platform;
    final mobile =
        platform == TargetPlatform.android || platform == TargetPlatform.iOS;
    final value = settings.value;
    if (value != null) {
      _initControllers(value);
    }
    return AppShell(
      title: l10n.t('settings'),
      scrollController: _scrollController,
      child: settings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) =>
            Center(child: Text('${l10n.t('settingsUnavailable')}: $error')),
        data: (data) => ListView(
          controller: _scrollController,
          padding: EdgeInsets.all(mobile ? 12 : 20),
          children: [
            _deviceSection(),
            const SizedBox(height: 16),
            _transferSection(data),
            const SizedBox(height: 16),
            _appearanceSection(data),
            const SizedBox(height: 16),
            _screenSection(data),
            // Desktop is a camera viewer. Keep the stored mobile profiles
            // untouched when saving other desktop settings.
            if (mobile) ...[const SizedBox(height: 16), _cameraSection(data)],
            const SizedBox(height: 20),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.icon(
                key: const ValueKey('settings-save'),
                onPressed: () {
                  final name = _nameController.text.trim();
                  final port = _parsePort(data.preferredPort);
                  _save(
                    (current) => current.copyWith(
                      deviceName: name.isEmpty ? current.deviceName : name,
                      preferredPort: port,
                    ),
                  );
                },
                icon: const Icon(Icons.save_rounded),
                label: Text(l10n.t('saveSettings')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _deviceSection() => SettingsSection(
    key: const ValueKey('settings-section-device'),
    title: context.l10n.t('settingsDeviceSection'),
    icon: Icons.devices_rounded,
    children: [
      TextField(
        key: const ValueKey('settings-device-name'),
        controller: _nameController,
        decoration: _fieldDecoration(
          context.l10n.t('deviceName'),
          Icons.badge_rounded,
        ),
      ),
    ],
  );

  Widget _transferSection(AppSettings data) {
    final l10n = context.l10n;
    return SettingsSection(
      key: const ValueKey('settings-section-transfers'),
      title: l10n.t('transfers'),
      icon: Icons.swap_horiz_rounded,
      children: [
        TextField(
          key: const ValueKey('settings-preferred-port'),
          controller: _portController,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration:
              _fieldDecoration(
                l10n.t('preferredPort'),
                Icons.settings_ethernet_rounded,
              ).copyWith(
                helperText: l10n.t('preferredPortHelp'),
                helperMaxLines: 20,
              ),
        ),
        InputDecorator(
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          child: SwitchListTile.adaptive(
            key: const ValueKey('settings-auto-accept'),
            contentPadding: EdgeInsets.zero,
            value: data.autoAccept,
            onChanged: (value) =>
                _save((current) => current.copyWith(autoAccept: value)),
            title: Text(l10n.t('automaticReceive')),
            subtitle: Text(l10n.t('automaticReceiveHelp')),
          ),
        ),
        InputDecorator(
          key: const ValueKey('settings-download-folder'),
          decoration:
              _fieldDecoration(
                l10n.t('downloadFolder'),
                Icons.folder_rounded,
              ).copyWith(
                suffixIcon: IconButton(
                  tooltip: l10n.t('chooseFolder'),
                  onPressed: _chooseDownloadDirectory,
                  icon: const Icon(Icons.edit_rounded),
                ),
              ),
          child: Text(data.downloadDirectory),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            key: const ValueKey('settings-clear-history'),
            onPressed: () => ref.read(historyProvider.notifier).clear(),
            icon: const Icon(Icons.delete_sweep_rounded),
            label: Text(l10n.t('clearHistory')),
          ),
        ),
      ],
    );
  }

  Widget _appearanceSection(AppSettings data) {
    final l10n = context.l10n;
    final themeLabels = {
      'system': l10n.t('system'),
      'light': l10n.t('light'),
      'dark': l10n.t('dark'),
    };
    final languageLabels = {'en': l10n.t('english'), 'es': l10n.t('spanish')};
    return SettingsSection(
      key: const ValueKey('settings-section-appearance'),
      title: l10n.t('settingsAppearanceSection'),
      icon: Icons.palette_rounded,
      children: [
        DropdownButtonFormField<String>(
          key: const ValueKey('settings-theme'),
          initialValue: data.themeMode,
          isExpanded: true,
          itemHeight: null,
          selectedItemBuilder: (_) => _selectedLabels(themeLabels.values),
          decoration: _fieldDecoration(l10n.t('theme'), Icons.contrast_rounded),
          items: [
            for (final entry in themeLabels.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
          onChanged: (value) {
            if (value != null) {
              _save((current) => current.copyWith(themeMode: value));
            }
          },
        ),
        DropdownButtonFormField<String>(
          key: const ValueKey('settings-language'),
          initialValue: data.languageCode,
          isExpanded: true,
          itemHeight: null,
          selectedItemBuilder: (_) => _selectedLabels(languageLabels.values),
          decoration: _fieldDecoration(
            l10n.t('language'),
            Icons.language_rounded,
          ),
          items: [
            for (final entry in languageLabels.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
          onChanged: (value) {
            if (value != null) {
              _save((current) => current.copyWith(languageCode: value));
            }
          },
        ),
      ],
    );
  }

  Widget _screenSection(AppSettings data) {
    final l10n = context.l10n;
    return SettingsSection(
      key: const ValueKey('settings-section-screen'),
      title: l10n.t('screenCaptureSettings'),
      icon: Icons.screen_share_rounded,
      description: l10n.t('screenCaptureSettingsHelp'),
      children: [
        DropdownButtonFormField<int>(
          key: const ValueKey('screen-resolution'),
          initialValue: data.screenCapture.resolution,
          isExpanded: true,
          itemHeight: null,
          selectedItemBuilder: (_) => _selectedLabels(
            ScreenCaptureSettings.resolutions.map(_resolutionLabel),
          ),
          decoration: _fieldDecoration(
            l10n.t('screenResolution'),
            Icons.aspect_ratio_rounded,
          ),
          items: [
            for (final resolution in ScreenCaptureSettings.resolutions)
              DropdownMenuItem(
                value: resolution,
                child: Text(_resolutionLabel(resolution)),
              ),
          ],
          onChanged: (value) {
            if (value != null) {
              _save(
                (current) => current.copyWith(
                  screenCapture: current.screenCapture.copyWith(
                    resolution: value,
                  ),
                ),
              );
            }
          },
        ),
        DropdownButtonFormField<int>(
          key: const ValueKey('screen-frame-rate'),
          initialValue: data.screenCapture.frameRate,
          isExpanded: true,
          itemHeight: null,
          selectedItemBuilder: (_) => _selectedLabels(
            ScreenCaptureSettings.frameRates.map(
              (frameRate) => '$frameRate FPS',
            ),
          ),
          decoration: _fieldDecoration(
            l10n.t('screenFrameRate'),
            Icons.speed_rounded,
          ),
          items: [
            for (final frameRate in ScreenCaptureSettings.frameRates)
              DropdownMenuItem(value: frameRate, child: Text('$frameRate FPS')),
          ],
          onChanged: (value) {
            if (value != null) {
              _save(
                (current) => current.copyWith(
                  screenCapture: current.screenCapture.copyWith(
                    frameRate: value,
                  ),
                ),
              );
            }
          },
        ),
      ],
    );
  }

  Widget _cameraSection(AppSettings data) {
    final l10n = context.l10n;
    return SettingsSection(
      key: const ValueKey('settings-section-camera'),
      title: l10n.cameraText('cameraSettings'),
      icon: Icons.videocam_rounded,
      description: l10n.cameraText('cameraSettingsHelp'),
      children: [
        for (final frontFacing in [false, true])
          ExpansionTile(
            key: ValueKey('camera-profile-${frontFacing ? 'front' : 'back'}'),
            tilePadding: EdgeInsets.zero,
            title: Text(
              l10n.cameraText(frontFacing ? 'frontCamera' : 'backCamera'),
            ),
            children: [
              _cameraProfileFields(
                keyPrefix: 'camera-${frontFacing ? 'front' : 'back'}',
                settings: data.cameraCapture.forCamera(
                  frontFacing: frontFacing,
                ),
                onResolutionChanged: (value) => _save(
                  (current) => current.copyWith(
                    cameraCapture: current.cameraCapture.copyWith(
                      front: frontFacing
                          ? current.cameraCapture.front.copyWith(
                              resolution: value,
                            )
                          : null,
                      back: !frontFacing
                          ? current.cameraCapture.back.copyWith(
                              resolution: value,
                            )
                          : null,
                    ),
                  ),
                ),
                onFrameRateChanged: (value) => _save(
                  (current) => current.copyWith(
                    cameraCapture: current.cameraCapture.copyWith(
                      front: frontFacing
                          ? current.cameraCapture.front.copyWith(
                              frameRate: value,
                            )
                          : null,
                      back: !frontFacing
                          ? current.cameraCapture.back.copyWith(
                              frameRate: value,
                            )
                          : null,
                    ),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }

  InputDecoration _fieldDecoration(String label, IconData icon) =>
      InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        border: const OutlineInputBorder(),
      );

  Future<void> _chooseDownloadDirectory() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path != null && mounted) {
      await _save((current) => current.copyWith(downloadDirectory: path));
    }
  }

  Widget _cameraProfileFields({
    required String keyPrefix,
    required ScreenCaptureSettings settings,
    required ValueChanged<int> onResolutionChanged,
    required ValueChanged<int> onFrameRateChanged,
  }) {
    final l10n = context.l10n;
    return Column(
      children: [
        DropdownButtonFormField<int>(
          key: ValueKey('$keyPrefix-resolution'),
          initialValue: settings.resolution,
          isExpanded: true,
          itemHeight: null,
          selectedItemBuilder: (_) => _selectedLabels(
            ScreenCaptureSettings.resolutions.map(_resolutionLabel),
          ),
          decoration: _fieldDecoration(
            l10n.cameraText('cameraResolution'),
            Icons.aspect_ratio_rounded,
          ),
          items: [
            for (final resolution in ScreenCaptureSettings.resolutions)
              DropdownMenuItem(
                value: resolution,
                child: Text(_resolutionLabel(resolution)),
              ),
          ],
          onChanged: (value) {
            if (value != null) onResolutionChanged(value);
          },
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<int>(
          key: ValueKey('$keyPrefix-frame-rate'),
          initialValue: settings.frameRate,
          isExpanded: true,
          itemHeight: null,
          selectedItemBuilder: (_) => _selectedLabels(
            ScreenCaptureSettings.frameRates.map(
              (frameRate) => '$frameRate FPS',
            ),
          ),
          decoration: _fieldDecoration(
            l10n.cameraText('cameraFrameRate'),
            Icons.speed_rounded,
          ),
          items: [
            for (final frameRate in ScreenCaptureSettings.frameRates)
              DropdownMenuItem(value: frameRate, child: Text('$frameRate FPS')),
          ],
          onChanged: (value) {
            if (value != null) onFrameRateChanged(value);
          },
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  String _resolutionLabel(int resolution) => resolution == 0
      ? context.l10n.t('screenNativeResolution')
      : '${resolution}p';

  // The closed field stays compact; the popup keeps complete, wrapping labels.
  List<Widget> _selectedLabels(Iterable<String> labels) => [
    for (final label in labels)
      Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
  ];

  int _parsePort(int fallback) {
    final parsed = int.tryParse(_portController.text.trim());
    if (parsed == null || parsed < 1 || parsed > 65535) {
      _portController.text = fallback.toString();
      return fallback;
    }
    return parsed;
  }

  Future<void> _save(AppSettings Function(AppSettings) change) async {
    try {
      await ref.read(settingsProvider.notifier).saveChanges(change);
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.t('settingsSaved'))));
    } catch (error) {
      if (!mounted) return;
      ref.read(loggerProvider).warn('Could not save settings: $error');
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.t(
              error is AndroidStorageAccessDenied
                  ? 'storagePermissionRequired'
                  : 'settingsSaveFailed',
            ),
          ),
        ),
      );
    }
  }
}
