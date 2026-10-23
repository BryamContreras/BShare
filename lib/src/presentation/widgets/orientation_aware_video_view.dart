import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class OrientationAwareVideoView extends StatefulWidget {
  const OrientationAwareVideoView({
    super.key,
    required this.renderer,
    this.objectFit = RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
    this.borderRadius = BorderRadius.zero,
    this.constrainToVideoAspect = false,
    this.preferredAspectRatio,
    this.settleOnAspectChange = false,
    this.settleDuration = const Duration(milliseconds: 900),
  });

  final RTCVideoRenderer renderer;
  final RTCVideoViewObjectFit objectFit;
  final BorderRadius borderRadius;
  final bool constrainToVideoAspect;
  final double? preferredAspectRatio;
  final bool settleOnAspectChange;
  final Duration settleDuration;

  @override
  State<OrientationAwareVideoView> createState() =>
      _OrientationAwareVideoViewState();
}

class _OrientationAwareVideoViewState extends State<OrientationAwareVideoView> {
  static const double _aspectChangeThreshold = 0.16;

  Timer? _settleTimer;
  double? _lastAspectRatio;
  bool _settling = false;

  @override
  void initState() {
    super.initState();
    _lastAspectRatio = _aspectRatio(widget.renderer.value);
    widget.renderer.addListener(_handleRendererValueChanged);
  }

  @override
  void didUpdateWidget(covariant OrientationAwareVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.renderer != widget.renderer) {
      oldWidget.renderer.removeListener(_handleRendererValueChanged);
      widget.renderer.addListener(_handleRendererValueChanged);
      _cancelSettling();
      _lastAspectRatio = _aspectRatio(widget.renderer.value);
      return;
    }
    if (!widget.settleOnAspectChange) {
      _cancelSettling();
    }
    if (oldWidget.preferredAspectRatio != widget.preferredAspectRatio) {
      _handleAspectRatio(_aspectRatio(widget.renderer.value));
    }
  }

  @override
  void dispose() {
    widget.renderer.removeListener(_handleRendererValueChanged);
    _settleTimer?.cancel();
    super.dispose();
  }

  void _handleRendererValueChanged() {
    _handleAspectRatio(_aspectRatio(widget.renderer.value));
  }

  void _handleAspectRatio(double aspectRatio) {
    final previous = _lastAspectRatio;
    _lastAspectRatio = aspectRatio;
    if (previous == null || !_isMeaningfulAspectChange(previous, aspectRatio)) {
      return;
    }
    _startSettling();
  }

  bool _isMeaningfulAspectChange(double previous, double next) {
    if (!_isHealthyAspectRatio(previous) || !_isHealthyAspectRatio(next)) {
      return false;
    }
    if ((previous < 1 && next > 1) || (previous > 1 && next < 1)) return true;
    return (previous - next).abs() >= _aspectChangeThreshold;
  }

  void _startSettling() {
    if (!widget.settleOnAspectChange) return;
    _settleTimer?.cancel();
    if (!_settling && mounted) {
      setState(() => _settling = true);
    }
    _settleTimer = Timer(widget.settleDuration, () {
      _settleTimer = null;
      if (mounted) {
        setState(() => _settling = false);
      }
    });
  }

  void _cancelSettling() {
    _settleTimer?.cancel();
    _settleTimer = null;
    _settling = false;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<RTCVideoValue>(
      valueListenable: widget.renderer,
      builder: (context, value, _) {
        final aspectRatio = _aspectRatio(value);
        final view = ClipRRect(
          borderRadius: widget.borderRadius,
          child: ColoredBox(
            color: Colors.black,
            child: Stack(
              children: [
                _TextureVideoView(
                  renderer: widget.renderer,
                  aspectRatio: aspectRatio,
                  objectFit: widget.objectFit,
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _settling ? 1 : 0,
                      duration: _settling
                          ? Duration.zero
                          : const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      child: const ColoredBox(color: Colors.black),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );

        if (!widget.constrainToVideoAspect) return view;
        return AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: AspectRatio(aspectRatio: aspectRatio, child: view),
        );
      },
    );
  }

  double _aspectRatio(RTCVideoValue value) {
    if (value.width > 0 && value.height > 0) {
      final aspect = value.aspectRatio;
      if (_isHealthyAspectRatio(aspect)) return aspect;
    }
    // Signaling metadata can arrive before or after the actual rotated frame.
    // Stretching a decoded frame to that metadata deforms it during each turn.
    final preferred = widget.preferredAspectRatio;
    if (_isHealthyAspectRatio(preferred)) return preferred!;
    return 16 / 9;
  }

  bool _isHealthyAspectRatio(double? aspect) {
    return aspect != null && aspect.isFinite && aspect > 0;
  }
}

class _TextureVideoView extends StatelessWidget {
  const _TextureVideoView({
    required this.renderer,
    required this.aspectRatio,
    required this.objectFit,
  });

  final RTCVideoRenderer renderer;
  final double aspectRatio;
  final RTCVideoViewObjectFit objectFit;

  @override
  Widget build(BuildContext context) {
    final textureId = renderer.textureId;
    final hasVideo = renderer.renderVideo && textureId != null;
    final fit = objectFit == RTCVideoViewObjectFit.RTCVideoViewObjectFitCover
        ? BoxFit.cover
        : BoxFit.contain;

    return SizedBox.expand(
      child: FittedBox(
        clipBehavior: Clip.hardEdge,
        fit: fit,
        child: SizedBox(
          width: 1000 * aspectRatio,
          height: 1000,
          child: hasVideo
              ? Texture(
                  textureId: textureId,
                  filterQuality: FilterQuality.low,
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
  }
}
