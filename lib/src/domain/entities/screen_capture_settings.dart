/// Limits for the next screen-sharing session. Resolution is the shorter edge
/// in pixels; the source's aspect ratio is always preserved.
class ScreenCaptureSettings {
  const ScreenCaptureSettings({this.resolution = 1080, this.frameRate = 30});

  static const resolutions = [480, 720, 1080, 1440, 0];
  static const frameRates = [15, 24, 30, 60];

  final int resolution;
  final int frameRate;

  ScreenCaptureSettings copyWith({int? resolution, int? frameRate}) =>
      ScreenCaptureSettings(
        resolution: resolution ?? this.resolution,
        frameRate: frameRate ?? this.frameRate,
      ).validated;

  ScreenCaptureSettings get validated => ScreenCaptureSettings(
    resolution: resolutions.contains(resolution) ? resolution : 1080,
    frameRate: frameRates.contains(frameRate) ? frameRate : 30,
  );

  double scaleFor(double width, double height) {
    final limit = validated.resolution;
    if (limit == 0 ||
        !width.isFinite ||
        !height.isFinite ||
        width <= 0 ||
        height <= 0) {
      return 1;
    }
    final shorterEdge = width < height ? width : height;
    return shorterEdge > limit ? shorterEdge / limit : 1;
  }

  int get maxBitrate {
    final options = validated;
    final pixels = options.resolution == 0 ? 1440 : options.resolution;
    return (pixels * pixels * (16 / 9) * options.frameRate * 0.09)
        .round()
        .clamp(500000, 20000000);
  }
}
