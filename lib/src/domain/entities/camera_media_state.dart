class CameraMediaState {
  const CameraMediaState({
    this.ready = false,
    this.supported = false,
    this.busy = false,
    this.recording = false,
    this.elapsed = Duration.zero,
    this.photoDirectory,
    this.videoDirectory,
    this.lastSavedPath,
    this.error,
  });

  final bool ready;
  final bool supported;
  final bool busy;
  final bool recording;
  final Duration elapsed;
  final String? photoDirectory;
  final String? videoDirectory;
  final String? lastSavedPath;

  /// A localization key; platform exception details stay out of the product UI.
  final String? error;

  CameraMediaState copyWith({
    bool? ready,
    bool? supported,
    bool? busy,
    bool? recording,
    Duration? elapsed,
    String? photoDirectory,
    String? videoDirectory,
    String? lastSavedPath,
    String? error,
    bool clearError = false,
    bool clearSavedPath = false,
  }) => CameraMediaState(
    ready: ready ?? this.ready,
    supported: supported ?? this.supported,
    busy: busy ?? this.busy,
    recording: recording ?? this.recording,
    elapsed: elapsed ?? this.elapsed,
    photoDirectory: photoDirectory ?? this.photoDirectory,
    videoDirectory: videoDirectory ?? this.videoDirectory,
    lastSavedPath: clearSavedPath ? null : lastSavedPath ?? this.lastSavedPath,
    error: clearError ? null : error ?? this.error,
  );
}
