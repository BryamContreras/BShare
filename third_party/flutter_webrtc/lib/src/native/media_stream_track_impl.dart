import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:webrtc_interface/webrtc_interface.dart';

import '../helper.dart';
import 'event_channel.dart';
import 'utils.dart';

class MediaStreamTrackNative extends MediaStreamTrack {
  MediaStreamTrackNative(this._trackId, this._label, this._kind, this._enabled,
      this._peerConnectionId,
      [this.settings_ = const {}]);

  factory MediaStreamTrackNative.fromMap(
      Map<dynamic, dynamic> map, String peerConnectionId) {
    return MediaStreamTrackNative(map['id'], map['label'], map['kind'],
        map['enabled'], peerConnectionId, map['settings'] ?? {});
  }
  final String _trackId;
  final String _label;
  final String _kind;
  final String _peerConnectionId;
  final Map<Object?, Object?> settings_;

  bool _enabled;

  bool _muted = false;

  StreamTrackCallback? _onEnded;
  StreamSubscription<Map<String, dynamic>>? _endedEventSubscription;
  Future<void> _endedEventCancellation = Future.value();
  Future<void>? _stopping;
  bool _ended = false;
  bool _stopped = false;

  @override
  StreamTrackCallback? get onEnded => _onEnded;

  @override
  set onEnded(StreamTrackCallback? callback) {
    _onEnded = _ended || _stopped ? null : callback;
    if (_onEnded == null) {
      unawaited(_cancelEndedEvents());
      return;
    }
    _endedEventSubscription ??= FlutterWebRTCEventChannel
        .instance.handleEvents.stream
        .listen(_handleEndedEvent);
  }

  void _handleEndedEvent(Map<String, dynamic> event) {
    final stoppedTrack = event['onScreenCaptureStopped'];
    if (_ended ||
        _stopped ||
        stoppedTrack is! Map ||
        stoppedTrack['trackId'] != _trackId) {
      return;
    }
    _ended = true;
    final callback = _onEnded;
    _onEnded = null;
    // Cancel before notifying: the callback can stop/dispose this track, and
    // a repeated native notification must not trigger another teardown.
    unawaited(_cancelEndedEvents());
    callback?.call();
  }

  Future<void> _cancelEndedEvents() {
    final cancellation = _endedEventSubscription?.cancel();
    _endedEventSubscription = null;
    if (cancellation != null) {
      _endedEventCancellation = Future.wait<void>([
        _endedEventCancellation,
        cancellation,
      ]).then<void>((_) {});
    }
    return _endedEventCancellation;
  }

  String get peerConnectionId => _peerConnectionId;

  @override
  set enabled(bool enabled) {
    WebRTC.invokeMethod('mediaStreamTrackSetEnable', <String, dynamic>{
      'trackId': _trackId,
      'enabled': enabled,
      'peerConnectionId': _peerConnectionId
    });
    _enabled = enabled;

    if (kind == 'audio') {
      _muted = !enabled;
      muted ? onMute?.call() : onUnMute?.call();
    }
  }

  @override
  bool get enabled => _enabled;

  @override
  String get label => _label;

  @override
  String get kind => _kind;

  @override
  String get id => _trackId;

  @override
  bool get muted => _muted;

  @override
  Future<bool> hasTorch() => WebRTC.invokeMethod(
        'mediaStreamTrackHasTorch',
        <String, dynamic>{'trackId': _trackId},
      ).then((value) => value ?? false);

  @override
  Future<void> setTorch(bool torch) => WebRTC.invokeMethod(
        'mediaStreamTrackSetTorch',
        <String, dynamic>{'trackId': _trackId, 'torch': torch},
      );

  @override
  Future<bool> switchCamera() => Helper.switchCamera(this);

  Future<void> setZoom(double zoomLevel) => Helper.setZoom(this, zoomLevel);

  @Deprecated('Use Helper.setSpeakerphoneOn instead')
  @override
  void enableSpeakerphone(bool enable) async {
    return Helper.setSpeakerphoneOn(enable);
  }

  @override
  Future<ByteBuffer> captureFrame() async {
    var filePath = await getTemporaryDirectory();
    await WebRTC.invokeMethod(
      'captureFrame',
      <String, dynamic>{
        'trackId': _trackId,
        'peerConnectionId': _peerConnectionId,
        'path': '${filePath.path}/captureFrame.png'
      },
    );
    return File('${filePath.path}/captureFrame.png')
        .readAsBytes()
        .then((value) => value.buffer);
  }

  @override
  Future<void> applyConstraints([Map<String, dynamic>? constraints]) {
    if (constraints == null) return Future.value();

    var current = getConstraints();
    if (constraints.containsKey('volume') &&
        current['volume'] != constraints['volume']) {
      Helper.setVolume(constraints['volume'], this);
    }

    return Future.value();
  }

  @override
  Map<String, dynamic> getSettings() {
    return settings_.map((key, value) => MapEntry(key.toString(), value));
  }

  @override
  Future<void> dispose() async {
    return stop();
  }

  @override
  Future<void> stop() => _stopping ??= _stop();

  Future<void> _stop() async {
    _stopped = true;
    _onEnded = null;
    await _cancelEndedEvents();
    try {
      await WebRTC.invokeMethod(
        'trackDispose',
        <String, dynamic>{'trackId': _trackId},
      );
    } catch (_) {
      // A failed native disposal can be retried without restoring listeners.
      _stopping = null;
      rethrow;
    }
  }
}
