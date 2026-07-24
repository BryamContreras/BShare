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
}

void main() {
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
}
