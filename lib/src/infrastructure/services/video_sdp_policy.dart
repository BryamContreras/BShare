/// Reorders only codecs already advertised by WebRTC. Never invents a profile,
/// level or payload type: those are capabilities of the actual device.
class VideoSdpPolicy {
  static String offer(String sdp, {bool compatibility = false}) {
    final lines = sdp.split(RegExp(r'\r?\n'));
    final output = <String>[];
    for (var start = 0; start < lines.length;) {
      if (!lines[start].startsWith('m=video ')) {
        output.add(lines[start++]);
        continue;
      }
      var end = start + 1;
      while (end < lines.length && !lines[end].startsWith('m=')) {
        end++;
      }
      output.addAll(_video(lines.sublist(start, end), compatibility));
      start = end;
    }
    return output.join('\r\n');
  }

  static List<String> _video(List<String> lines, bool compatibility) {
    final parts = lines.first.split(RegExp(r'\s+'));
    if (parts.length < 4 || parts[1] == '0') return lines;
    final payloads = parts.skip(3).toList();
    final codecs = <String, String>{};
    final formats = <String, String>{};
    for (final line in lines.skip(1)) {
      final rtp = RegExp(r'^a=rtpmap:(\d+)\s+([^/]+)/').firstMatch(line);
      if (rtp != null) codecs[rtp[1]!] = rtp[2]!.toUpperCase();
      final fmtp = RegExp(r'^a=fmtp:(\d+)\s+(.+)$').firstMatch(line);
      if (fmtp != null) formats[fmtp[1]!] = fmtp[2]!;
    }
    final vp8 = payloads.where((p) => codecs[p] == 'VP8').toList();
    if (compatibility && vp8.isEmpty) {
      throw StateError('This WebRTC device does not offer VP8 video');
    }
    final baseline = payloads.where(
      (p) => codecs[p] == 'H264' && _constrainedBaseline(formats[p] ?? ''),
    );
    final primary = compatibility
        ? vp8
        : <String>{...baseline, ...vp8, ...payloads}.toList();
    final ordered = <String>{};
    for (final payload in primary) {
      ordered.add(payload);
      // Keep retransmission payloads with the video format they protect.
      ordered.addAll(
        payloads.where((p) {
          return codecs[p] == 'RTX' &&
              RegExp(
                '(?:^|;)\\s*apt=$payload(?:;|\$)',
              ).hasMatch(formats[p] ?? '');
        }),
      );
    }
    return [
      [...parts.take(3), ...ordered].join(' '),
      ...lines.skip(1).where((line) {
        if (!compatibility) return true;
        final attribute = RegExp(
          r'^a=(?:rtpmap|fmtp|rtcp-fb):(\d+)(?:\s|$)',
        ).firstMatch(line);
        return attribute == null || ordered.contains(attribute[1]);
      }),
    ];
  }

  static bool _constrainedBaseline(String format) {
    final match = RegExp(
      r'(?:^|;)\s*profile-level-id=([0-9a-f]{6})(?:;|$)',
      caseSensitive: false,
    ).firstMatch(format);
    // RFC 6184's default profile is constrained baseline, level 3.1.
    if (match == null) return !format.contains('profile-level-id=');
    final profile = int.parse(match[1]!.substring(0, 2), radix: 16);
    final constraints = int.parse(match[1]!.substring(2, 4), radix: 16);
    return (profile == 0x42 && constraints & 0x4f == 0x40) ||
        (profile == 0x4d && constraints & 0x8f == 0x80) ||
        (profile == 0x58 && constraints & 0xcf == 0xc0);
  }

  static String? firstVideoCodec(String sdp) {
    final lines = sdp.split(RegExp(r'\r?\n'));
    final start = lines.indexWhere((line) => line.startsWith('m=video '));
    if (start < 0) return null;
    final parts = lines[start].split(RegExp(r'\s+'));
    if (parts.length < 4 || parts[1] == '0') return null;
    final pattern = RegExp('^a=rtpmap:${RegExp.escape(parts[3])}\\s+([^/]+)/');
    for (final line in lines.skip(start + 1)) {
      if (line.startsWith('m=')) break;
      final match = pattern.firstMatch(line);
      if (match != null) return match[1]!.toUpperCase();
    }
    return null;
  }
}
