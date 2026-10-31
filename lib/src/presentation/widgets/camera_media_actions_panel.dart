import 'dart:async';
import 'dart:io';

import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/localization/camera_viewer_localizations.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// Native folder dialogs require an existing starting directory. A fresh
/// BShare destination is intentionally created only when media is saved.
Future<String?> cameraMediaPickerDirectory(String? path) async {
  if (path == null || !p.isAbsolute(path)) return null;
  var candidate = p.normalize(path);
  while (!await Directory(candidate).exists()) {
    final parent = p.dirname(candidate);
    if (parent == candidate) return null;
    candidate = parent;
  }
  return candidate;
}

/// Local computer actions. Camera adjustments remain in the right-hand panel.
class CameraMediaActionsPanel extends StatefulWidget {
  const CameraMediaActionsPanel({
    super.key,
    required this.previewEnabled,
    required this.onPreviewChanged,
    required this.onChoosePhotoFolder,
    required this.onChooseVideoFolder,
    required this.onTakePhoto,
    required this.onToggleRecording,
    this.previewBusy = false,
    this.initializing = false,
    this.supported = true,
    this.streamReady = false,
    this.takingPhoto = false,
    this.startingRecording = false,
    this.recording = false,
    this.savingVideo = false,
    this.elapsed = Duration.zero,
    this.photoDirectory,
    this.videoDirectory,
    this.lastSavedPath,
    this.errorMessage,
  });

  final bool previewEnabled;
  final bool previewBusy;
  final bool initializing;
  final bool supported;
  final bool streamReady;
  final bool takingPhoto;
  final bool startingRecording;
  final bool recording;
  final bool savingVideo;
  final Duration elapsed;
  final String? photoDirectory;
  final String? videoDirectory;
  final String? lastSavedPath;
  final String? errorMessage;
  final ValueChanged<bool>? onPreviewChanged;
  final VoidCallback? onChoosePhotoFolder;
  final VoidCallback? onChooseVideoFolder;
  final VoidCallback? onTakePhoto;
  final VoidCallback? onToggleRecording;

  @override
  State<CameraMediaActionsPanel> createState() =>
      _CameraMediaActionsPanelState();

  String get _duration {
    final totalSeconds = elapsed.inSeconds;
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    final minutes = (totalSeconds ~/ 60 % 60).toString().padLeft(2, '0');
    final hours = totalSeconds ~/ 3600;
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  Widget _build(BuildContext context, Widget savedFooter) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final saveBusy =
        initializing || takingPhoto || startingRecording || savingVideo;
    return Material(
      key: const ValueKey('camera-viewer-actions'),
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                l10n.cameraViewerText('captureActions'),
                style: theme.textTheme.titleMedium,
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                key: const ValueKey('camera-viewer-actions-scroll'),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SwitchListTile(
                      key: const ValueKey('camera-viewer-preview'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(l10n.cameraViewerText('preview')),
                      value: previewEnabled,
                      onChanged: previewBusy ? null : onPreviewChanged,
                    ),
                    Text(
                      l10n.cameraViewerText('previewHelp'),
                      style: theme.textTheme.bodySmall,
                    ),
                    if (previewBusy) ...[
                      const SizedBox(height: 8),
                      const LinearProgressIndicator(),
                    ],
                    const SizedBox(height: 20),
                    if (initializing) ...[
                      const LinearProgressIndicator(),
                      const SizedBox(height: 8),
                      Text(l10n.cameraViewerText('preparingFolders')),
                      const SizedBox(height: 12),
                    ] else if (!supported || !streamReady) ...[
                      Text(
                        l10n.cameraViewerText(
                          supported ? 'mediaNotReady' : 'mediaUnsupported',
                        ),
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                    ],
                    FilledButton.tonalIcon(
                      key: const ValueKey('camera-take-photo'),
                      onPressed: !saveBusy && supported && streamReady
                          ? onTakePhoto
                          : null,
                      icon: takingPhoto
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.photo_camera_rounded),
                      label: Text(
                        l10n.cameraViewerText(
                          takingPhoto ? 'takingPhoto' : 'takePhoto',
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _folder(
                      context,
                      kind: 'photo',
                      label: l10n.cameraViewerText('photosFolder'),
                      directory: photoDirectory,
                      onChoose: saveBusy ? null : onChoosePhotoFolder,
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      key: const ValueKey('camera-record-video'),
                      onPressed:
                          !saveBusy && (recording || (supported && streamReady))
                          ? onToggleRecording
                          : null,
                      style: recording
                          ? FilledButton.styleFrom(
                              backgroundColor: theme.colorScheme.error,
                              foregroundColor: theme.colorScheme.onError,
                            )
                          : null,
                      icon: savingVideo || startingRecording
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              recording
                                  ? Icons.stop_rounded
                                  : Icons.fiber_manual_record_rounded,
                            ),
                      label: Text(
                        l10n.cameraViewerText(
                          startingRecording
                              ? 'startingRecording'
                              : savingVideo
                              ? 'savingVideo'
                              : recording
                              ? 'stopRecording'
                              : 'recordVideo',
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    if (recording) ...[
                      const SizedBox(height: 8),
                      Semantics(
                        excludeSemantics: true,
                        label:
                            '${l10n.cameraViewerText('recording')} $_duration',
                        child: Text(
                          '${l10n.cameraViewerText('recording')} · $_duration',
                          key: const ValueKey('camera-recording-duration'),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    _folder(
                      context,
                      kind: 'video',
                      label: l10n.cameraViewerText('videosFolder'),
                      directory: videoDirectory,
                      onChoose: saveBusy || recording
                          ? null
                          : onChooseVideoFolder,
                    ),
                    if (errorMessage case final error?) ...[
                      const SizedBox(height: 16),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          error,
                          key: const ValueKey('camera-media-error'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            savedFooter,
          ],
        ),
      ),
    );
  }

  Widget _folder(
    BuildContext context, {
    required String kind,
    required String label,
    required String? directory,
    required VoidCallback? onChoose,
  }) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        Text(
          directory ??
              l10n.cameraViewerText(
                initializing ? 'preparingFolders' : 'folderUnavailable',
              ),
          key: ValueKey('camera-$kind-directory'),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: ValueKey('camera-$kind-folder'),
          onPressed: onChoose,
          icon: const Icon(Icons.folder_open_rounded),
          label: Text(
            l10n.cameraViewerText('chooseFolder'),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

class _CameraMediaActionsPanelState extends State<CameraMediaActionsPanel> {
  Timer? _savedTimer;
  String? _visibleSavedPath;

  @override
  void initState() {
    super.initState();
    if (widget.lastSavedPath case final path?) _showSaved(path);
  }

  @override
  void didUpdateWidget(covariant CameraMediaActionsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final path = widget.lastSavedPath;
    if (path != null && path != oldWidget.lastSavedPath) _showSaved(path);
  }

  void _showSaved(String path) {
    _savedTimer?.cancel();
    _visibleSavedPath = path;
    _savedTimer = Timer(const Duration(seconds: 10), () {
      if (mounted) setState(() => _visibleSavedPath = null);
    });
  }

  @override
  void dispose() {
    _savedTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => widget._build(
      context,
      _savedFooter(
        context,
        (constraints.maxHeight * .4).clamp(0, 160).toDouble(),
      ),
    ),
  );

  Widget _savedFooter(BuildContext context, double maximumHeight) {
    final theme = Theme.of(context);
    final path = _visibleSavedPath;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return ClipRect(
      key: const ValueKey('camera-media-saved-footer'),
      child: AnimatedSwitcher(
        duration: reducedMotion
            ? Duration.zero
            : const Duration(milliseconds: 220),
        reverseDuration: reducedMotion
            ? Duration.zero
            : const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SizeTransition(
            sizeFactor: animation,
            alignment: Alignment.bottomCenter,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, .06),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
        ),
        child: path == null
            ? const SizedBox(key: ValueKey('camera-media-saved-empty'))
            : ConstrainedBox(
                key: ValueKey(path),
                constraints: BoxConstraints(maxHeight: maximumHeight),
                child: Semantics(
                  liveRegion: true,
                  child: Column(
                    key: const ValueKey('camera-media-saved'),
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Divider(height: 1),
                      Flexible(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${context.l10n.cameraViewerText('mediaSaved')}:',
                                key: const ValueKey('camera-media-saved-title'),
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              SelectableText(
                                path,
                                key: const ValueKey('camera-media-saved-path'),
                                maxLines: 2,
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}
