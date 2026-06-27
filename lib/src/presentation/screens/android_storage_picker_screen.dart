import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/selected_transfer_file.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:bshare/src/presentation/widgets/formatters.dart';
import 'package:bshare/src/presentation/widgets/gradient_action_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

enum AndroidStoragePickerMode { files, folder }

class AndroidStoragePickerScreen extends ConsumerStatefulWidget {
  const AndroidStoragePickerScreen({super.key, required this.mode});

  final AndroidStoragePickerMode mode;

  @override
  ConsumerState<AndroidStoragePickerScreen> createState() =>
      _AndroidStoragePickerScreenState();
}

class _AndroidStoragePickerScreenState
    extends ConsumerState<AndroidStoragePickerScreen> {
  final _scrollController = ScrollController();
  Directory _current = Directory('/storage/emulated/0');
  final _selected = <String, SelectedTransferFile>{};
  var _loading = true;
  String? _error;
  List<FileSystemEntity> _items = const [];

  bool get _isFolderMode => widget.mode == AndroidStoragePickerMode.folder;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load([Directory? directory]) async {
    setState(() {
      _loading = true;
      _error = null;
      if (directory != null) _current = directory;
    });
    try {
      if (Platform.isAndroid) {
        await Permission.manageExternalStorage.request();
      }
      final entries = await _current
          .list(followLinks: false)
          .where(
            (entity) =>
                !p.basename(entity.path).startsWith('.') &&
                (!_isFolderMode || entity is Directory),
          )
          .toList();
      entries.sort((a, b) {
        final aDir = a is Directory;
        final bDir = b is Directory;
        if (aDir != bDir) return aDir ? -1 : 1;
        return p
            .basename(a.path)
            .toLowerCase()
            .compareTo(p.basename(b.path).toLowerCase());
      });
      if (!mounted) return;
      setState(() => _items = entries);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _items = const [];
        _error = context.l10n.t('openFolderFailed');
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _goUp() async {
    final parent = _current.parent;
    if (_current.path == parent.path || !_current.path.startsWith('/storage')) {
      return;
    }
    await _load(parent);
  }

  Future<void> _toggleFile(File file) async {
    final path = file.path;
    if (_selected.containsKey(path)) {
      setState(() => _selected.remove(path));
      return;
    }
    final stat = await file.stat();
    if (!mounted) return;
    setState(() {
      _selected[path] = SelectedTransferFile(
        path: path,
        name: p.basename(path),
        size: stat.size,
      );
    });
  }

  Future<void> _confirm() async {
    if (_isFolderMode) {
      await ref.read(sendControllerProvider).addFolderPath(_current.path);
    } else {
      ref
          .read(sendControllerProvider)
          .addSelectedFiles(_selected.values.toList());
    }
    if (mounted) context.go('/send');
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 420;
    final l10n = context.l10n;
    final title = _isFolderMode ? l10n.t('folder') : l10n.t('files');
    final canConfirm = _isFolderMode || _selected.isNotEmpty;
    return AppShell(
      title: title,
      scrollController: _scrollController,
      backPath: '/send',
      actions: [
        IconButton.filledTonal(
          tooltip: l10n.t('accept'),
          onPressed: canConfirm ? _confirm : null,
          icon: const Icon(Icons.check_rounded),
        ),
        SizedBox(width: compact ? 4 : 8),
      ],
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 8 : 16,
              compact ? 6 : 10,
              compact ? 8 : 16,
              6,
            ),
            child: Row(
              children: [
                IconButton.filledTonal(
                  tooltip: l10n.t('goUp'),
                  onPressed: _goUp,
                  icon: const Icon(Icons.arrow_upward_rounded),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _current.path.replaceFirst(
                      '/storage/emulated/0',
                      l10n.t('storage'),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 3),
          if (_isFolderMode)
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 8 : 16,
                6,
                compact ? 8 : 16,
                6,
              ),
              child: GradientActionButton(
                onPressed: _confirm,
                icon: Icons.folder_rounded,
                label: l10n.t('selectThisFolder'),
                expand: true,
              ),
            ),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: EdgeInsets.fromLTRB(
                compact ? 8 : 16,
                4,
                compact ? 8 : 16,
                compact ? 8 : 16,
              ),
              itemCount: _items.length,
              itemBuilder: (context, index) {
                final item = _items[index];
                final isDirectory = item is Directory;
                final name = p.basename(item.path);
                final selected = _selected.containsKey(item.path);
                return Card(
                  margin: EdgeInsets.symmetric(vertical: compact ? 3 : 4),
                  child: ListTile(
                    dense: compact,
                    leading: Icon(
                      isDirectory
                          ? Icons.folder_rounded
                          : Icons.insert_drive_file_rounded,
                    ),
                    title: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: isDirectory
                        ? null
                        : FutureBuilder<FileStat>(
                            future: File(item.path).stat(),
                            builder: (context, snapshot) => Text(
                              snapshot.hasData
                                  ? formatBytes(snapshot.data!.size)
                                  : '',
                            ),
                          ),
                    trailing: !_isFolderMode && !isDirectory
                        ? Icon(
                            selected
                                ? Icons.check_circle_rounded
                                : Icons.circle_outlined,
                            color: selected
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          )
                        : const Icon(Icons.chevron_right_rounded),
                    onTap: () {
                      if (isDirectory) {
                        _load(item);
                      } else if (!_isFolderMode) {
                        _toggleFile(File(item.path));
                      }
                    },
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
