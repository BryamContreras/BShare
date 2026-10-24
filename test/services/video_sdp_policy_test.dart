import 'package:bshare/src/infrastructure/services/video_sdp_policy.dart';
import 'package:flutter_test/flutter_test.dart';

const sdp =
    'v=0\r\n'
    'a=group:BUNDLE audio video\r\n'
    'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
    'a=mid:audio\r\na=rtpmap:111 opus/48000/2\r\n'
    'a=fmtp:111 minptime=10;useinbandfec=1\r\n'
    'm=video 9 UDP/TLS/RTP/SAVPF 100 101 96 97 102 103\r\n'
    'a=mid:video\r\n'
    'a=rtpmap:100 H264/90000\r\na=fmtp:100 profile-level-id=640c1f;packetization-mode=1\r\n'
    'a=rtpmap:101 rtx/90000\r\na=fmtp:101 apt=100\r\n'
    'a=rtpmap:96 VP8/90000\r\na=rtcp-fb:96 nack pli\r\n'
    'a=rtpmap:97 rtx/90000\r\na=fmtp:97 apt=96\r\n'
    'a=rtpmap:102 H264/90000\r\na=fmtp:102 profile-level-id=42e01f;packetization-mode=1\r\n'
    'a=rtpmap:103 rtx/90000\r\na=fmtp:103 apt=102\r\n'
    'a=rtcp-fb:100 nack pli\r\na=rtcp-fb:102 nack pli\r\n'
    'a=rtcp-fb:* transport-cc\r\n'
    'a=candidate:1 1 udp 2122260223 192.168.1.5 50000 typ host\r\n';

void main() {
  test(
    'prefers constrained baseline then VP8 without changing device profiles',
    () {
      final result = VideoSdpPolicy.offer(sdp);
      expect(
        result,
        contains('m=video 9 UDP/TLS/RTP/SAVPF 102 103 96 97 100 101'),
      );
      expect(result, contains('profile-level-id=42e01f;packetization-mode=1'));
      expect(result, contains('profile-level-id=640c1f;packetization-mode=1'));
      expect(VideoSdpPolicy.firstVideoCodec(result), 'H264');
    },
  );

  test('fallback keeps only VP8 and its RTX and preserves audio and ICE', () {
    final result = VideoSdpPolicy.offer(sdp, compatibility: true);
    expect(result, contains('m=video 9 UDP/TLS/RTP/SAVPF 96 97\r\n'));
    expect(result, isNot(contains('H264')));
    expect(result, isNot(contains('a=fmtp:101')));
    expect(result, isNot(contains('a=rtcp-fb:100')));
    expect(result, contains('a=fmtp:97 apt=96'));
    expect(result, contains('a=rtcp-fb:* transport-cc'));
    expect(result.split('m=video').first, sdp.split('m=video').first);
    expect(result, contains('192.168.1.5 50000 typ host'));
    expect(VideoSdpPolicy.firstVideoCodec(result), 'VP8');
  });

  test('does not invent fallback when VP8 is absent', () {
    expect(
      () => VideoSdpPolicy.offer(
        'm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=rtpmap:96 H264/90000\r\n',
        compatibility: true,
      ),
      throwsStateError,
    );
  });

  test(
    'payload types in subsequent media cannot change the selected codec',
    () {
      expect(
        VideoSdpPolicy.firstVideoCodec(
          'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
          'm=audio 9 UDP/TLS/RTP/SAVPF 96\r\na=rtpmap:96 opus/48000/2\r\n',
        ),
        isNull,
      );
      expect(
        VideoSdpPolicy.firstVideoCodec(
          sdp.replaceFirst('m=video 9', 'm=video 0'),
        ),
        isNull,
      );
    },
  );
}
