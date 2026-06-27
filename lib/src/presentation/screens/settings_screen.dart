import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/app_settings.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
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

  @override
  void dispose() {
    _nameController.dispose();
    _portController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _initControllers(AppSettings data) {
    if (_nameController.text != data.deviceName) {
      _nameController.text = data.deviceName;
    }
    final portStr = data.preferredPort.toString();
    if (_portController.text != portStr) {
      _portController.text = portStr;
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final l10n = context.l10n;
    final value = settings.value;
    if (value != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _initControllers(value);
      });
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
          padding: EdgeInsets.all(Platform.isAndroid ? 8 : 20),
          children: [
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: l10n.t('deviceName'),
                prefixIcon: const Icon(Icons.badge_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _portController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: l10n.t('preferredPort'),
                helperText: l10n.t('preferredPortHelp'),
                prefixIcon: const Icon(Icons.settings_ethernet_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            SwitchListTile(
              value: data.autoAccept,
              onChanged: (value) => _save(data.copyWith(autoAccept: value)),
              title: Text(l10n.t('automaticReceive')),
              subtitle: Text(l10n.t('automaticReceiveHelp')),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: data.themeMode,
              decoration: InputDecoration(
                labelText: l10n.t('theme'),
                prefixIcon: const Icon(Icons.contrast_rounded),
                border: OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem(
                  value: 'system',
                  child: Text(l10n.t('system')),
                ),
                DropdownMenuItem(value: 'light', child: Text(l10n.t('light'))),
                DropdownMenuItem(value: 'dark', child: Text(l10n.t('dark'))),
              ],
              onChanged: (value) {
                if (value != null) {
                  _save(data.copyWith(themeMode: value));
                }
              },
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: data.languageCode,
              decoration: InputDecoration(
                labelText: l10n.t('language'),
                prefixIcon: const Icon(Icons.language_rounded),
                border: const OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem(value: 'en', child: Text(l10n.t('english'))),
                DropdownMenuItem(value: 'es', child: Text(l10n.t('spanish'))),
              ],
              onChanged: (value) {
                if (value != null) {
                  _save(data.copyWith(languageCode: value));
                }
              },
            ),
            const SizedBox(height: 14),
            Card(
              child: ListTile(
                leading: const Icon(Icons.folder_rounded),
                title: Text(l10n.t('downloadFolder')),
                subtitle: Text(data.downloadDirectory),
                trailing: IconButton(
                  tooltip: l10n.t('chooseFolder'),
                  onPressed: () async {
                    final path = await FilePicker.platform.getDirectoryPath();
                    if (path != null) {
                      await _save(data.copyWith(downloadDirectory: path));
                    }
                  },
                  icon: const Icon(Icons.edit_rounded),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: () => _save(
                    data.copyWith(
                      deviceName: _nameController.text.trim().isEmpty
                          ? data.deviceName
                          : _nameController.text.trim(),
                      preferredPort: _parsePort(data.preferredPort),
                    ),
                  ),
                  icon: const Icon(Icons.save_rounded),
                  label: Text(l10n.t('saveSettings')),
                ),
                OutlinedButton.icon(
                  onPressed: () => ref.read(historyProvider.notifier).clear(),
                  icon: const Icon(Icons.delete_sweep_rounded),
                  label: Text(l10n.t('clearHistory')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  int _parsePort(int fallback) {
    final parsed = int.tryParse(_portController.text.trim());
    if (parsed == null || parsed < 1 || parsed > 65535) {
      _portController.text = fallback.toString();
      return fallback;
    }
    return parsed;
  }

  Future<void> _save(AppSettings settings) async {
    final previous = ref.read(settingsProvider).value;
    final shouldRestartNetworking =
        previous != null &&
        (previous.deviceName != settings.deviceName ||
            previous.preferredPort != settings.preferredPort ||
            previous.downloadDirectory != settings.downloadDirectory ||
            previous.autoAccept != settings.autoAccept);
    if (shouldRestartNetworking) {
      await ref.read(runtimeCleanupProvider).cleanupNetworking();
    }
    await ref.read(settingsProvider.notifier).save(settings);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.t('settingsSaved'))));
    }
  }
}
