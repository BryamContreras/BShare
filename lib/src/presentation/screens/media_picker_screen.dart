import 'dart:io';
import 'dart:typed_data';

import 'package:bshare/src/application/providers.dart';
import 'package:bshare/src/domain/entities/selected_transfer_file.dart';
import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/widgets/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';

class MediaPickerScreen extends ConsumerStatefulWidget {
  const MediaPickerScreen({super.key});

  @override
  ConsumerState<MediaPickerScreen> createState() => _MediaPickerScreenState();
}

class _MediaPickerScreenState extends ConsumerState<MediaPickerScreen> {
  static const _pageSize = 160;

  final _scrollController = ScrollController();
  final _selected = <String, AssetEntity>{};

  List<AssetPathEntity> _albums = const [];
  AssetPathEntity? _album;
  List<AssetEntity> _assets = const [];
  var _page = 0;
  var _hasMore = true;
  var _hasAccess = true;
  var _loadingAlbums = true;
  var _loadingAssets = false;
  var _loadingMore = false;
  var _confirming = false;
  String? _errorKey;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_maybeLoadMore);
    Future.microtask(_loadAlbums);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_maybeLoadMore);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadAlbums() async {
    setState(() {
      _loadingAlbums = true;
      _errorKey = null;
    });
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!mounted) return;
      if (!permission.hasAccess) {
        setState(() {
          _hasAccess = false;
          _loadingAlbums = false;
          _albums = const [];
          _album = null;
          _assets = const [];
        });
        return;
      }

      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        hasAll: true,
      );
      if (!mounted) return;
      setState(() {
        _hasAccess = true;
        _albums = albums;
        _album = albums.isEmpty ? null : albums.first;
        _loadingAlbums = false;
      });
      await _loadAssets(reset: true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingAlbums = false;
        _errorKey = 'mediaLoadFailed';
      });
    }
  }

  Future<void> _loadAssets({required bool reset}) async {
    final album = _album;
    if (album == null) return;
    if (!reset && (!_hasMore || _loadingAssets || _loadingMore)) return;

    final page = reset ? 0 : _page;
    setState(() {
      _errorKey = null;
      if (reset) {
        _assets = const [];
        _page = 0;
        _hasMore = true;
        _loadingAssets = true;
      } else {
        _loadingMore = true;
      }
    });

    try {
      final assets = await album.getAssetListPaged(page: page, size: _pageSize);
      if (!mounted || _album?.id != album.id) return;
      setState(() {
        _assets = reset ? assets : [..._assets, ...assets];
        _page = page + 1;
        _hasMore = assets.length == _pageSize;
      });
    } catch (_) {
      if (!mounted || _album?.id != album.id) return;
      setState(() => _errorKey = 'mediaLoadFailed');
    } finally {
      if (mounted && _album?.id == album.id) {
        setState(() {
          _loadingAssets = false;
          _loadingMore = false;
        });
      }
    }
  }

  void _maybeLoadMore() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.extentAfter < 520) {
      _loadAssets(reset: false);
    }
  }

  void _selectAlbum(AssetPathEntity? album) {
    if (album == null || album.id == _album?.id) return;
    setState(() => _album = album);
    _loadAssets(reset: true);
  }

  void _toggle(AssetEntity asset) {
    setState(() {
      if (_selected.containsKey(asset.id)) {
        _selected.remove(asset.id);
      } else {
        _selected[asset.id] = asset;
      }
    });
  }

  Future<void> _confirm() async {
    if (_selected.isEmpty || _confirming) return;
    setState(() => _confirming = true);
    final files = <SelectedTransferFile>[];

    for (final asset in _selected.values) {
      final file = await asset.originFile ?? await asset.file;
      if (file == null) continue;
      final stat = await file.stat();
      files.add(
        SelectedTransferFile(
          path: file.path,
          name: await _assetName(asset, file),
          size: stat.size,
        ),
      );
    }

    if (!mounted) return;
    if (files.isEmpty) {
      setState(() {
        _confirming = false;
        _errorKey = 'mediaSelectionFailed';
      });
      return;
    }
    ref.read(sendControllerProvider).addSelectedFiles(files);
    context.go('/send');
  }

  Future<String> _assetName(AssetEntity asset, File file) async {
    final title = asset.title?.trim();
    if (title != null && title.isNotEmpty) return title;
    try {
      final asyncTitle = (await asset.titleAsync).trim();
      if (asyncTitle.isNotEmpty) return asyncTitle;
    } catch (_) {
      // Fall back to the resolved file path when the platform has no title.
    }
    return p.basename(file.path);
  }

  String _albumLabel(AssetPathEntity album) {
    final name = album.name.trim();
    if (album.isAll || name.isEmpty) return context.l10n.t('recent');
    return name;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final compact = MediaQuery.sizeOf(context).width < 420;
    final selectedCount = _selected.length;

    return AppShell(
      title: l10n.t('media'),
      backPath: '/send',
      actions: [
        if (selectedCount > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: Text(
                '$selectedCount',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
        IconButton.filledTonal(
          tooltip: l10n.t('addSelected'),
          onPressed: selectedCount == 0 || _confirming ? null : _confirm,
          icon: _confirming
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check_rounded),
        ),
        SizedBox(width: compact ? 4 : 8),
      ],
      child: !_hasAccess
          ? _PermissionView(onRetry: _loadAlbums)
          : _loadingAlbums
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 8 : 16,
                    compact ? 6 : 10,
                    compact ? 8 : 16,
                    8,
                  ),
                  child: DropdownButtonFormField<AssetPathEntity>(
                    key: ValueKey(_album?.id),
                    initialValue: _album,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: l10n.t('albums'),
                      prefixIcon: const Icon(Icons.photo_album_rounded),
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      for (final album in _albums)
                        DropdownMenuItem(
                          value: album,
                          child: Text(
                            _albumLabel(album),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _selectAlbum,
                  ),
                ),
                if (_loadingAssets) const LinearProgressIndicator(minHeight: 3),
                if (_errorKey != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text(
                      l10n.t(_errorKey!),
                      textAlign: TextAlign.center,
                    ),
                  ),
                Expanded(
                  child: _assets.isEmpty && _loadingAssets
                      ? const Center(child: CircularProgressIndicator())
                      : _assets.isEmpty
                      ? Center(child: Text(l10n.t('noMediaFound')))
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            final width = constraints.maxWidth;
                            final columns = width < 340
                                ? 3
                                : width < 620
                                ? 4
                                : width < 900
                                ? 5
                                : 6;
                            return GridView.builder(
                              controller: _scrollController,
                              padding: EdgeInsets.fromLTRB(
                                compact ? 8 : 16,
                                4,
                                compact ? 8 : 16,
                                compact ? 12 : 18,
                              ),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: columns,
                                    mainAxisSpacing: 4,
                                    crossAxisSpacing: 4,
                                  ),
                              itemCount:
                                  _assets.length + (_loadingMore ? 1 : 0),
                              itemBuilder: (context, index) {
                                if (index >= _assets.length) {
                                  return const Center(
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  );
                                }
                                final asset = _assets[index];
                                final selectedIndex = _selected.keys
                                    .toList()
                                    .indexOf(asset.id);
                                return _MediaTile(
                                  asset: asset,
                                  selectedIndex: selectedIndex,
                                  onTap: () => _toggle(asset),
                                );
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

class _PermissionView extends StatelessWidget {
  const _PermissionView({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.photo_library_rounded, size: 44),
                const SizedBox(height: 12),
                Text(
                  l10n.t('mediaPermissionTitle'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.t('mediaPermissionBody'),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton.filledTonal(
                      tooltip: l10n.t('retry'),
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: PhotoManager.openSetting,
                      icon: const Icon(Icons.settings_rounded),
                      label: Text(l10n.t('openSettings')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MediaTile extends StatelessWidget {
  const _MediaTile({
    required this.asset,
    required this.selectedIndex,
    required this.onTap,
  });

  final AssetEntity asset;
  final int selectedIndex;
  final VoidCallback onTap;

  bool get _selected => selectedIndex >= 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _AssetThumbnail(key: ValueKey(asset.id), asset: asset),
            if (_selected)
              ColoredBox(color: Colors.black.withValues(alpha: 0.2)),
            if (asset.type == AssetType.video)
              Positioned(
                left: 6,
                bottom: 6,
                child: _VideoBadge(duration: asset.videoDuration),
              ),
            Positioned(
              right: 6,
              top: 6,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: _selected
                      ? scheme.primary
                      : Colors.black.withValues(alpha: 0.42),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _selected ? scheme.primary : Colors.white,
                    width: 1.6,
                  ),
                ),
                child: _selected
                    ? Center(
                        child: Text(
                          '${selectedIndex + 1}',
                          style: TextStyle(
                            color: scheme.onPrimary,
                            fontWeight: FontWeight.w800,
                            fontSize: 12,
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AssetThumbnail extends StatefulWidget {
  const _AssetThumbnail({super.key, required this.asset});

  final AssetEntity asset;

  @override
  State<_AssetThumbnail> createState() => _AssetThumbnailState();
}

class _AssetThumbnailState extends State<_AssetThumbnail> {
  late Future<Uint8List?> _thumbnail;

  @override
  void initState() {
    super.initState();
    _thumbnail = _loadThumbnail();
  }

  @override
  void didUpdateWidget(covariant _AssetThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id) {
      _thumbnail = _loadThumbnail();
    }
  }

  Future<Uint8List?> _loadThumbnail() {
    return widget.asset.thumbnailDataWithSize(
      const ThumbnailSize.square(360),
      quality: 88,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _thumbnail,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) {
          return ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const Center(
              child: Icon(Icons.image_rounded, color: Colors.white70),
            ),
          );
        }
        return Image.memory(
          data,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
        );
      },
    );
  }
}

class _VideoBadge extends StatelessWidget {
  const _VideoBadge({required this.duration});

  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 14),
            Text(
              _formatDuration(duration),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60);
    final seconds = value.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
