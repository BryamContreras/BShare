/// USB offers can name only the authenticated TURN/TCP endpoint supplied by the
/// local cable bridge. Neither a LAN caller nor a supplied STUN URL may redirect
/// a phone's capture to an unrelated network service.
class UsbIceConfiguration {
  static Map<String, dynamic> validate(Object? value) {
    if (value is! Map || value['iceTransportPolicy'] != 'relay') {
      throw const FormatException('Invalid USB relay configuration');
    }
    final servers = value['iceServers'];
    if (servers is! List || servers.length != 1 || servers.single is! Map) {
      throw const FormatException('Invalid USB relay configuration');
    }
    final server = servers.single as Map;
    final urls = server['urls'];
    if (urls is! List || urls.length != 1 || urls.single is! String) {
      throw const FormatException('Invalid USB relay configuration');
    }
    final url = urls.single as String;
    final match = RegExp(
      r'^turn:127\.0\.0\.1:([0-9]{1,5})\?transport=tcp$',
    ).firstMatch(url);
    final port = int.tryParse(match?[1] ?? '');
    final username = server['username'];
    final credential = server['credential'];
    bool validSecret(Object? text) =>
        text is String && RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(text);
    if (port == null ||
        port < 1 ||
        port > 65535 ||
        !validSecret(username) ||
        !validSecret(credential)) {
      throw const FormatException('Invalid USB relay configuration');
    }
    return {
      'iceTransportPolicy': 'relay',
      'iceServers': [
        {
          'urls': [url],
          'username': username,
          'credential': credential,
        },
      ],
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
    };
  }

  /// Both relayed allocations live on the PC's loopback interface. Keep only
  /// those candidates, so a malformed/older peer cannot fall back to LAN.
  static String relaySdp(String sdp) {
    final lines = <String>[];
    var candidates = 0;
    for (final line in sdp.split(RegExp(r'\r?\n'))) {
      if (line.startsWith('a=candidate:')) {
        final fields = line.split(RegExp(r'\s+'));
        if (fields.length < 8 ||
            fields[4] != '127.0.0.1' ||
            fields[6] != 'typ' ||
            fields[7] != 'relay') {
          continue;
        }
        candidates++;
      } else if (line.startsWith('a=remote-candidates:')) {
        continue;
      } else if (line.startsWith('c=IN IP')) {
        lines.add('c=IN IP4 127.0.0.1');
        continue;
      }
      lines.add(line);
    }
    if (candidates == 0) throw StateError('USB relay produced no candidate');
    return lines.join('\r\n');
  }
}
