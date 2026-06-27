import 'dart:convert';
import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/android_app_file.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:bshare/src/presentation/widgets/formatters.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class AndroidAppPickerScreen extends ConsumerStatefulWidget {
  const AndroidAppPickerScreen({super.key});

  @override
  ConsumerState<AndroidAppPickerScreen> createState() =>
      _AndroidAppPickerScreenState();
}

class _AndroidAppPickerScreenState
    extends ConsumerState<AndroidAppPickerScreen> {
  final _filterController = TextEditingController();
  final _scrollController = ScrollController();
  final _selected = <AndroidAppFile>{};
  var _apps = const <AndroidAppFile>[];
  var _loading = true;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _filterController.addListener(() {
      setState(() => _query = _filterController.text.trim().toLowerCase());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadApps());
  }

  @override
  void dispose() {
    _filterController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadApps() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final apps = Platform.isAndroid
          ? await ref.read(androidAppsServiceProvider).listInstalledApps()
          : const <AndroidAppFile>[];
      if (!mounted) return;
      setState(() => _apps = apps);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = context.l10n.t('appsLoadFailed'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 420;
    final l10n = context.l10n;
    final filtered = _apps
        .where(
          (app) =>
              app.name.toLowerCase().contains(_query) ||
              app.packageName.toLowerCase().contains(_query),
        )
        .toList();
    return AppShell(
      title: l10n.t('apps'),
      scrollController: _scrollController,
      backPath: '/send',
      actions: [
        IconButton.filledTonal(
          tooltip: l10n.t('addSelectedApps'),
          onPressed: _selected.isEmpty
              ? null
              : () {
                  ref
                      .read(sendControllerProvider)
                      .addAndroidApps(_selected.toList());
                  context.go('/send');
                },
          icon: const Icon(Icons.check_rounded),
        ),
        const SizedBox(width: 8),
      ],
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 8 : 16,
              compact ? 6 : 10,
              compact ? 8 : 16,
              8,
            ),
            child: TextField(
              controller: _filterController,
              decoration: InputDecoration(
                hintText: l10n.t('searchApps'),
                prefixIcon: const Icon(Icons.search_rounded),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 3),
          Expanded(
            child: _loading && filtered.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(child: Text(_error!))
                : filtered.isEmpty
                ? Center(child: Text(l10n.t('noAppsFound')))
                : ListView.builder(
                    controller: _scrollController,
                    padding: EdgeInsets.fromLTRB(
                      compact ? 8 : 16,
                      4,
                      compact ? 8 : 16,
                      compact ? 8 : 16,
                    ),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final app = filtered[index];
                      final checked = _selected.contains(app);
                      return Card(
                        margin: EdgeInsets.symmetric(vertical: compact ? 3 : 4),
                        child: CheckboxListTile(
                          dense: compact,
                          value: checked,
                          onChanged: (value) {
                            setState(() {
                              if (value == true) {
                                _selected.add(app);
                              } else {
                                _selected.remove(app);
                              }
                            });
                          },
                          secondary: _AppIcon(base64: app.iconBase64),
                          title: Text(app.name),
                          subtitle: Text(
                            'Tamaño: ${formatBytes(app.size)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _AppIcon extends StatelessWidget {
  const _AppIcon({required this.base64});

  final String base64;

  @override
  Widget build(BuildContext context) {
    if (base64.isEmpty) {
      return const CircleAvatar(child: Icon(Icons.apps_rounded));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.memory(
        base64Decode(base64),
        width: 42,
        height: 42,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      ),
    );
  }
}
