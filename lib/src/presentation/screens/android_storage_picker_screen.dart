import 'dart:io';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/selected_transfer_file.dart';
import 'package:bshare/src/infrastructure/services/android_storage_access_service.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/navigation/app_navigation.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:bshare/src/presentation/widgets/formatters.dart';
import 'package:bshare/src/presentation/widgets/gradient_action_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

enum AndroidStoragePickerMode { files, folder }

class AndroidStoragePickerScreen extends ConsumerStatefulWidget {
  const AndroidStoragePickerScreen({
    super.key,
    required this.mode,
    this.initialDirectoryPath = '/storage/emulated/0',
  });

  final AndroidStoragePickerMode mode;
  final String initialDirectoryPath;

  @override
  ConsumerState<AndroidStoragePickerScreen> createState() =>
      _AndroidStoragePickerScreenState();
}

class _AndroidStoragePickerScreenState
    extends ConsumerState<AndroidStoragePickerScreen>
    with WidgetsBindingObserver {
  final _scrollController = ScrollController();
  late Directory _current;
  final _selected = <String, SelectedTransferFile>{};
  var _loading = true;
  String? _errorKey;
  bool _hasDirectoryAccess = false;
  bool _confirming = false;
  final _fileStats = <String, Future<FileStat>>{};
  List<FileSystemEntity> _items = const [];
  int _loadGeneration = 0;

  bool get _isFolderMode => widget.mode == AndroidStoragePickerMode.folder;

  @override
  void initState() {
    super.initState();
    _current = Directory(widget.initialDirectoryPath);
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(_load);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_loading && !_confirming) {
      _load(requestPermission: false);
    }
  }

  Future<void> _load({
    Directory? directory,
    bool requestPermission = true,
  }) async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _errorKey = null;
      _hasDirectoryAccess = false;
      _fileStats.clear();
      if (directory != null) _current = directory;
    });
    try {
      final storage = ref.read(androidStorageAccessProvider);
      await storage.ensureAccess(
        _current.path,
        requestPermission: requestPermission,
      );
      if (!mounted || generation != _loadGeneration) return;
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
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _items = entries;
        _hasDirectoryAccess = true;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _items = const [];
        _selected.clear();
        _hasDirectoryAccess = false;
        _errorKey = error is AndroidStorageAccessDenied
            ? 'storagePermissionRequired'
            : 'openFolderFailed';
      });
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _goUp() async {
    final parent = _current.parent;
    if (_current.path == parent.path || !_current.path.startsWith('/storage')) {
      return;
    }
    await _load(directory: parent);
  }

  Future<FileStat> _fileStat(File file) =>
      _fileStats.putIfAbsent(file.path, () async {
        await ref
            .read(androidStorageAccessProvider)
            .ensureAccess(file.path, requestPermission: false);
        return file.stat();
      });

  Future<void> _toggleFile(File file) async {
    if (_loading || _confirming || !_hasDirectoryAccess) return;
    final path = file.path;
    final generation = _loadGeneration;
    if (_selected.containsKey(path)) {
      setState(() => _selected.remove(path));
      return;
    }
    try {
      await ref
          .read(androidStorageAccessProvider)
          .ensureAccess(path, requestPermission: false);
      final stat = await _fileStat(file);
      if (!mounted || generation != _loadGeneration) return;
      if (stat.type != FileSystemEntityType.file) {
        throw FileSystemException('The selected file is no longer available');
      }
      setState(() {
        _selected[path] = SelectedTransferFile(
          path: path,
          name: p.basename(path),
          size: stat.size,
        );
      });
    } catch (error) {
      if (generation == _loadGeneration) _showAccessError(error);
    }
  }

  void _showAccessError(Object error) {
    if (!mounted) return;
    setState(() {
      _selected.clear();
      _hasDirectoryAccess = false;
      _errorKey = error is AndroidStorageAccessDenied
          ? 'storagePermissionRequired'
          : 'storageAccessFailed';
    });
  }

  Future<void> _confirm() async {
    if (_loading ||
        _confirming ||
        !_hasDirectoryAccess ||
        (!_isFolderMode && _selected.isEmpty)) {
      return;
    }
    setState(() => _confirming = true);
    try {
      final storage = ref.read(androidStorageAccessProvider);
      final paths = _isFolderMode
          ? [_current.path]
          : _selected.keys.toList(growable: false);
      for (final path in paths) {
        await storage.ensureAccess(path, requestPermission: false);
      }
      if (!mounted) return;
      if (_isFolderMode) {
        await ref.read(sendControllerProvider).addFolderPath(_current.path);
      } else {
        ref
            .read(sendControllerProvider)
            .addSelectedFiles(_selected.values.toList(growable: false));
      }
      if (mounted) AppNavigationScope.back(context, fallback: '/send');
    } catch (error) {
      _showAccessError(error);
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 420;
    final l10n = context.l10n;
    final title = _isFolderMode ? l10n.t('folder') : l10n.t('files');
    final canConfirm =
        !_loading &&
        !_confirming &&
        _hasDirectoryAccess &&
        (_isFolderMode || _selected.isNotEmpty);
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
                  onPressed: _loading || _confirming ? null : _goUp,
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
                onPressed: canConfirm ? _confirm : null,
                icon: Icons.folder_rounded,
                label: l10n.t('selectThisFolder'),
                expand: true,
              ),
            ),
          if (_errorKey != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l10n.t(_errorKey!)),
                  TextButton.icon(
                    onPressed: _loading || _confirming ? null : _load,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(l10n.t('retry')),
                  ),
                ],
              ),
            ),
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
                            future: _fileStat(File(item.path)),
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
                    onTap: _loading || _confirming || !_hasDirectoryAccess
                        ? null
                        : () {
                            if (isDirectory) {
                              _load(directory: item);
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
