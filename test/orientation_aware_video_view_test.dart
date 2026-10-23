import 'package:bshare/src/presentation/widgets/orientation_aware_video_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class _DelayedVideoRenderer extends RTCVideoRenderer {
  bool _active = false;

  @override
  int? get textureId => 7;

  @override
  bool get renderVideo => _active;

  void receiveFirstFrame() {
    _active = true;
    value = const RTCVideoValue(width: 640, height: 360, renderVideo: true);
  }

  void receiveFrame(double width, double height, {int rotation = 0}) {
    _active = true;
    value = RTCVideoValue(
      width: width,
      height: height,
      rotation: rotation,
      renderVideo: true,
    );
  }
}

void main() {
  testWidgets('texture paint bounds follow rotation in a fixed viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final renderer = _DelayedVideoRenderer();
    addTearDown(renderer.dispose);
    await tester.pumpWidget(
      MaterialApp(home: OrientationAwareVideoView(renderer: renderer)),
    );

    for (final dimensions in [
      (1080.0, 2316.0),
      (2316.0, 1080.0),
      (1080.0, 2316.0),
    ]) {
      renderer.receiveFrame(dimensions.$1, dimensions.$2);
      await tester.pump();
      final texture = tester.renderObject<RenderBox>(find.byType(Texture));
      expect(
        tester.widget<Texture>(find.byType(Texture)).filterQuality,
        FilterQuality.low,
      );
      final bounds = MatrixUtils.transformRect(
        texture.getTransformTo(null),
        Offset.zero & texture.size,
      );
      expect(
        bounds.width / bounds.height,
        closeTo(dimensions.$1 / dimensions.$2, 0.000001),
      );
      expect(bounds.center.dx, closeTo(640, 0.000001));
      expect(bounds.center.dy, closeTo(384, 0.000001));
      expect(bounds.left, greaterThanOrEqualTo(0));
      expect(bounds.top, greaterThanOrEqualTo(0));
      expect(bounds.right, lessThanOrEqualTo(1280));
      expect(bounds.bottom, lessThanOrEqualTo(768));
    }
  });

  testWidgets('creates the texture when video arrives after mounting', (
    tester,
  ) async {
    final renderer = _DelayedVideoRenderer();
    addTearDown(renderer.dispose);

    await tester.pumpWidget(
      MaterialApp(home: OrientationAwareVideoView(renderer: renderer)),
    );

    expect(find.byType(Texture), findsNothing);

    renderer.receiveFirstFrame();
    await tester.pump();

    expect(find.byType(Texture), findsOneWidget);
  });

  testWidgets('preserves tall phone and ultrawide display proportions', (
    tester,
  ) async {
    final renderer = _DelayedVideoRenderer();
    addTearDown(renderer.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: OrientationAwareVideoView(
          renderer: renderer,
          constrainToVideoAspect: true,
        ),
      ),
    );

    for (final dimensions in [(1080.0, 2640.0), (5120.0, 1440.0)]) {
      renderer.receiveFrame(dimensions.$1, dimensions.$2);
      await tester.pump();
      expect(
        tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio,
        closeTo(dimensions.$1 / dimensions.$2, 0.000001),
      );
    }
  });

  testWidgets('follows repeated portrait and landscape rotations', (
    tester,
  ) async {
    final renderer = _DelayedVideoRenderer();
    addTearDown(renderer.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: OrientationAwareVideoView(
          renderer: renderer,
          constrainToVideoAspect: true,
        ),
      ),
    );

    for (final rotation in [0, 90, 180, 270, 0]) {
      renderer.receiveFrame(1080, 2400, rotation: rotation);
      await tester.pump();
      expect(
        tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio,
        closeTo(rotation % 180 == 0 ? 1080 / 2400 : 2400 / 1080, 0.000001),
      );
      expect(find.byType(Texture), findsOneWidget);
    }
  });

  testWidgets('accepts valid preferred ratios and ignores invalid values', (
    tester,
  ) async {
    final renderer = _DelayedVideoRenderer();
    addTearDown(renderer.dispose);
    for (final preferred in [
      0.35,
      4.0,
      0.0,
      -1.0,
      double.nan,
      double.infinity,
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: OrientationAwareVideoView(
            renderer: renderer,
            constrainToVideoAspect: true,
            preferredAspectRatio: preferred,
          ),
        ),
      );
      expect(
        tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio,
        closeTo(
          preferred.isFinite && preferred > 0 ? preferred : 16 / 9,
          0.000001,
        ),
      );
    }
  });

  testWidgets('decoded frames take precedence over delayed rotation metadata', (
    tester,
  ) async {
    final renderer = _DelayedVideoRenderer()..receiveFrame(1080, 2400);
    addTearDown(renderer.dispose);
    Widget view(double metadata) => MaterialApp(
      home: OrientationAwareVideoView(
        renderer: renderer,
        constrainToVideoAspect: true,
        preferredAspectRatio: metadata,
      ),
    );

    // Landscape metadata arrives while the decoded frame is still portrait.
    await tester.pumpWidget(view(2400 / 1080));
    expect(
      tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio,
      closeTo(1080 / 2400, 0.000001),
    );
    renderer.receiveFrame(2400, 1080);
    await tester.pump();
    // The next metadata response is still portrait after the frame has turned.
    await tester.pumpWidget(view(1080 / 2400));
    expect(
      tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio,
      closeTo(2400 / 1080, 0.000001),
    );
  });

  testWidgets('changing renderer clears a previous rotation transition', (
    tester,
  ) async {
    final first = _DelayedVideoRenderer()..receiveFrame(640, 480);
    final second = _DelayedVideoRenderer()..receiveFrame(1080, 2400);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    Widget view(_DelayedVideoRenderer renderer, {bool settle = true}) =>
        MaterialApp(
          home: OrientationAwareVideoView(
            renderer: renderer,
            settleOnAspectChange: settle,
          ),
        );

    await tester.pumpWidget(view(first));
    first.receiveFrame(480, 640);
    await tester.pump();
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );

    await tester.pumpWidget(view(second));
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
    );
    first.receiveFrame(640, 480);
    await tester.pump();
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('disabling transitions cancels the pending timer', (
    tester,
  ) async {
    final renderer = _DelayedVideoRenderer()..receiveFrame(640, 480);
    addTearDown(renderer.dispose);
    Widget view(bool settle) => MaterialApp(
      home: OrientationAwareVideoView(
        renderer: renderer,
        settleOnAspectChange: settle,
      ),
    );

    await tester.pumpWidget(view(true));
    renderer.receiveFrame(480, 640);
    await tester.pump();
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );

    await tester.pumpWidget(view(false));
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
