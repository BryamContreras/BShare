import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// An authenticated, session-scoped TURN/TCP relay for one USB sender/viewer.
///
/// The Android ingress and allocated addresses are loopback-only. Desktop
/// self-address listeners accommodate native SDK sockets bound to a local NIC;
/// they accept only source addresses owned by this PC. A permission can target
/// only the other live allocation. Media remains DTLS/SRTP encrypted over USB.
class UsbTurnRelay {
  UsbTurnRelay._(
    this._server,
    this._credentials,
    this._localIpv4,
    this._fronts,
  );

  static const _realm = 'BShare-USB';
  static const _cookie = 0x2112a442;
  static const _allocationLifetime = 600;
  static const _permissionLifetime = 300;
  final ServerSocket _server;
  final Map<String, String> _credentials;
  final Set<String> _localIpv4;
  final List<ServerSocket> _fronts;
  final Map<String, int> _counters = {};
  final Set<_TurnClient> _clients = {};
  final Map<int, _TurnAllocation> _allocations = {};
  final Map<String, _TurnAllocation> _roles = {};
  StreamSubscription<Socket>? _listener;
  final List<StreamSubscription<Socket>> _frontListeners = [];
  Timer? _expiry;
  Future<void>? _closing;
  bool get isClosed => _closing != null;
  int get port => _server.port;
  int get allocationCount => _allocations.length;
  Map<String, int> get diagnostics => Map.unmodifiable({
    'tcpAccepted': _counters['tcpAccepted'] ?? 0,
    'tcpRejected': _counters['tcpRejected'] ?? 0,
    'localInterfaceClients': _counters['localInterfaceClients'] ?? 0,
    'allocateRequests': _counters['allocateRequests'] ?? 0,
    'allocateSuccess': _counters['allocateSuccess'] ?? 0,
    'authChallenges': _counters['authChallenges'] ?? 0,
    'authFailures': _counters['authFailures'] ?? 0,
    'quotaFailures': _counters['quotaFailures'] ?? 0,
    'forbiddenPeers': _counters['forbiddenPeers'] ?? 0,
    'protocolErrors': _counters['protocolErrors'] ?? 0,
    'relayPackets': _counters['relayPackets'] ?? 0,
    'relayBytes': _counters['relayBytes'] ?? 0,
    'activeClients': _clients.length,
    'activeAllocations': _allocations.length,
    'desktopSelfListeners': _fronts.length,
  });
  void _count(String name, [int amount = 1]) =>
      _counters.update(name, (value) => value + amount, ifAbsent: () => amount);

  static Future<UsbTurnRelay> start() async {
    final localIpv4 = <String>{'127.0.0.1'};
    try {
      for (final network in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: true,
      )) {
        localIpv4.addAll(network.addresses.map((address) => address.address));
      }
    } catch (_) {}
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final fronts = <ServerSocket>[];
    // The SDK has eight ICE server slots. Keep one loopback fallback plus at
    // most seven local self endpoints, so each bound NIC can reach its own IP.
    for (final address in localIpv4) {
      if (fronts.length >= 7) break;
      final ip = InternetAddress(address);
      if (ip.isLoopback ||
          ip.isLinkLocal ||
          ip.isMulticast ||
          address == '0.0.0.0') {
        continue;
      }
      try {
        fronts.add(await ServerSocket.bind(ip, 0));
      } catch (_) {
        // An interface can disappear or refuse listening during enumeration.
      }
    }
    final relay = UsbTurnRelay._(
      server,
      {
        'desktop-${_secret(12)}': _secret(32),
        'android-${_secret(12)}': _secret(32),
      },
      localIpv4,
      fronts,
    );
    relay._listener = server.listen(relay._accept);
    for (final front in fronts) {
      relay._frontListeners.add(front.listen(relay._accept));
    }
    relay._expiry = Timer.periodic(const Duration(seconds: 5), (_) {
      final now = DateTime.now();
      for (final allocation in relay._allocations.values.toList()) {
        if (!allocation.expires.isAfter(now)) allocation.client.close();
      }
    });
    return relay;
  }

  Map<String, dynamic> desktopIceConfiguration() {
    final configuration = _configuration(0, port);
    final loopback =
        (configuration['iceServers'] as List).single as Map<String, dynamic>;
    configuration['iceServers'] = [
      for (final front in _fronts)
        {
          ...loopback,
          'urls': ['turn:${front.address.address}:${front.port}?transport=tcp'],
        },
      loopback,
    ];
    return configuration;
  }

  Map<String, dynamic> androidIceConfiguration(int reversePort) =>
      _configuration(1, reversePort);

  Map<String, dynamic> _configuration(int role, int serverPort) {
    if (serverPort < 1 || serverPort > 65535) {
      throw ArgumentError.value(serverPort, 'serverPort');
    }
    final username = _credentials.keys.elementAt(role);
    return {
      'iceTransportPolicy': 'relay',
      'iceServers': [
        {
          'urls': ['turn:127.0.0.1:$serverPort?transport=tcp'],
          'username': username,
          'credential': _credentials[username],
        },
      ],
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
    };
  }

  void _accept(Socket socket) {
    if (isClosed ||
        (!socket.address.isLoopback &&
            !_fronts.any(
              (front) => front.address.address == socket.address.address,
            )) ||
        (!socket.remoteAddress.isLoopback &&
            !_localIpv4.contains(socket.remoteAddress.address)) ||
        _clients.length >= 8) {
      _count('tcpRejected');
      socket.destroy();
      return;
    }
    _count('tcpAccepted');
    if (!socket.remoteAddress.isLoopback) _count('localInterfaceClients');
    socket.setOption(SocketOption.tcpNoDelay, true);
    final client = _TurnClient(this, socket);
    _clients.add(client);
    client.start();
  }

  void _remove(_TurnClient client) {
    _clients.remove(client);
    _releaseAllocation(client);
  }

  void _releaseAllocation(_TurnClient client) {
    final allocation = client.allocation;
    if (allocation != null) {
      _allocations.remove(allocation.port);
      _roles.remove(allocation.username);
      allocation.reservation.close();
      client.allocation = null;
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _expiry?.cancel();
    await _listener?.cancel();
    for (final listener in _frontListeners) {
      await listener.cancel();
    }
    await _server.close();
    for (final front in _fronts) {
      await front.close();
    }
    for (final client in _clients.toList()) {
      client.close();
    }
    _credentials.clear();
  }

  Future<void> _handle(_TurnClient client, Uint8List bytes) async {
    if (client.closed || isClosed) return;
    if ((bytes[0] & 0xc0) == 0x40) {
      final channel = _u16(bytes, 0);
      final length = _u16(bytes, 2);
      final binding = client.allocation?.channels[channel];
      if (binding != null && binding.expires.isAfter(DateTime.now())) {
        _relay(
          client,
          binding.peerPort,
          Uint8List.sublistView(bytes, 4, 4 + length),
        );
      }
      return;
    }
    final message = _StunMessage.parse(bytes);
    if (message == null) {
      _count('protocolErrors');
      client.close();
      return;
    }
    // Binding is a harmless loopback-only discovery request (RFC 8489).
    if (message.type == 0x0001) {
      client.reply(message, 0x0101, [
        _attribute(
          0x0020,
          _address(
            client.socket.remotePort,
            address: client.socket.remoteAddress,
          ),
        ),
      ]);
      return;
    }
    if (message.type == 0x0016) {
      final peer = _peerPort(message.first(0x0012));
      final data = message.first(0x0013);
      if (peer != null && data != null) _relay(client, peer, data);
      return;
    }
    // Only requests are handled; unknown indications/responses are ignored.
    if ((message.type & 0x0110) != 0) return;
    final username = _text(message.first(0x0006));
    if (message.type == 0x0003) _count('allocateRequests');
    final password = _credentials[username];
    final nonce = _text(message.first(0x0015));
    final realm = _text(message.first(0x0014));
    final key = password == null
        ? null
        : Uint8List.fromList(
            md5.convert(utf8.encode('$username:$_realm:$password')).bytes,
          );
    if (key == null || realm != _realm || !message.authentic(key)) {
      _count(username == null ? 'authChallenges' : 'authFailures');
      client.error(message, 401, 'Unauthorized', challenge: true);
      return;
    }
    if (nonce != client.nonce) {
      client.error(message, 438, 'Stale Nonce', challenge: true);
      return;
    }
    if (client.allocation != null && client.allocation!.username != username) {
      client.error(message, 441, 'Wrong Credentials', key: key);
      return;
    }
    switch (message.type) {
      case 0x0003: // Allocate
        if (client.allocation != null) {
          client.error(message, 437, 'Allocation Mismatch', key: key);
          return;
        }
        final transport = message.first(0x0019);
        if (transport == null || transport.length != 4 || transport[0] != 17) {
          client.error(message, 442, 'Unsupported Transport', key: key);
          return;
        }
        final family = message.first(0x0017);
        if (family != null && (family.length != 4 || family[0] != 1)) {
          client.error(message, 440, 'Address Family Not Supported', key: key);
          return;
        }
        if (_roles.containsKey(username) || _allocations.length >= 2) {
          _count('quotaFailures');
          client.error(message, 486, 'Allocation Quota Reached', key: key);
          return;
        }
        // Reserve a genuine UDP port, but never relay to external UDP peers.
        final reservation = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        if (client.closed || isClosed || _roles.containsKey(username)) {
          reservation.close();
          if (!client.closed) {
            client.error(message, 486, 'Allocation Quota Reached', key: key);
          }
          return;
        }
        reservation.listen((event) {
          if (event == RawSocketEvent.read) {
            while (reservation.receive() != null) {}
          }
        });
        final allocation = _TurnAllocation(client, username!, reservation);
        client.allocation = allocation;
        _allocations[allocation.port] = allocation;
        _roles[username] = allocation;
        _count('allocateSuccess');
        client.reply(message, 0x0103, [
          _attribute(0x0016, _address(allocation.port)),
          _attribute(
            0x0020,
            _address(
              client.socket.remotePort,
              address: client.socket.remoteAddress,
            ),
          ),
          _attribute(0x000d, _uint32(_allocationLifetime)),
        ], key: key);
      case 0x0004: // Refresh
        final allocation = client.allocation;
        if (allocation == null) {
          client.error(message, 437, 'Allocation Mismatch', key: key);
          return;
        }
        final lifetime = message.first(0x000d);
        if (lifetime != null && lifetime.length != 4) {
          client.error(message, 400, 'Bad Request', key: key);
          return;
        }
        final requested = lifetime == null
            ? _allocationLifetime
            : _u32(lifetime, 0);
        final seconds = min(requested, _allocationLifetime);
        allocation.expires = DateTime.now().add(Duration(seconds: seconds));
        client.reply(message, 0x0104, [
          _attribute(0x000d, _uint32(seconds)),
        ], key: key);
        if (seconds == 0) {
          _releaseAllocation(client);
          client.waitForAllocation();
        }
      case 0x0008: // CreatePermission
        final allocation = client.allocation;
        if (allocation == null) {
          client.error(message, 437, 'Allocation Mismatch', key: key);
          return;
        }
        final peers = message.all(0x0012).toList();
        if (peers.isEmpty ||
            peers.any((value) => !_allowedPeer(_peerPort(value), allocation))) {
          client.error(message, 403, 'Forbidden Peer', key: key);
          return;
        }
        allocation.permissionExpires = DateTime.now().add(
          const Duration(seconds: _permissionLifetime),
        );
        client.reply(message, 0x0108, [], key: key);
      case 0x0009: // ChannelBind
        final allocation = client.allocation;
        if (allocation == null) {
          client.error(message, 437, 'Allocation Mismatch', key: key);
          return;
        }
        final channelValue = message.first(0x000c);
        final peer = _peerPort(message.first(0x0012));
        final channel = channelValue == null || channelValue.length != 4
            ? 0
            : _u16(channelValue, 0);
        if (channel < 0x4000 ||
            channel > 0x7fff ||
            !_allowedPeer(peer, allocation)) {
          client.error(message, 400, 'Bad Channel', key: key);
          return;
        }
        final existing = allocation.channels[channel];
        if ((existing != null && existing.peerPort != peer) ||
            allocation.channels.entries.any(
              (entry) => entry.key != channel && entry.value.peerPort == peer,
            )) {
          _count('forbiddenPeers');
          client.error(message, 400, 'Channel Already Bound', key: key);
          return;
        }
        allocation.permissionExpires = DateTime.now().add(
          const Duration(seconds: _permissionLifetime),
        );
        allocation.channels[channel] = _TurnChannel(
          peer!,
          DateTime.now().add(const Duration(seconds: _allocationLifetime)),
        );
        client.reply(message, 0x0109, [], key: key);
      default:
        client.error(message, 400, 'Unsupported Method', key: key);
    }
  }

  bool _allowedPeer(int? port, _TurnAllocation source) =>
      port != null &&
      _allocations[port] != null &&
      _allocations[port] != source;

  void _relay(_TurnClient client, int peerPort, Uint8List data) {
    if (data.length > 65507) return;
    final source = client.allocation;
    final target = _allocations[peerPort];
    final now = DateTime.now();
    if (source == null ||
        target == null ||
        source == target ||
        !source.expires.isAfter(now) ||
        !target.expires.isAfter(now) ||
        !source.permissionExpires.isAfter(now) ||
        !target.permissionExpires.isAfter(now)) {
      return;
    }
    _count('relayPackets');
    _count('relayBytes', data.length);
    for (final entry in target.channels.entries) {
      if (entry.value.peerPort == source.port &&
          entry.value.expires.isAfter(now)) {
        final frame = Uint8List(4 + ((data.length + 3) & ~3));
        _put16(frame, 0, entry.key);
        _put16(frame, 2, data.length);
        frame.setRange(4, 4 + data.length, data);
        target.client.write(frame);
        return;
      }
    }
    target.client.write(
      _stun(0x0017, _randomBytes(12), [
        _attribute(0x0012, _address(source.port)),
        _attribute(0x0013, data),
      ]),
    );
  }

  static Uint8List _address(int port, {InternetAddress? address}) {
    final bytes = Uint8List(8);
    bytes[1] = 1;
    _put16(bytes, 2, port ^ (_cookie >> 16));
    final ip = address?.rawAddress ?? InternetAddress.loopbackIPv4.rawAddress;
    _put32(bytes, 4, _u32(ip, 0) ^ _cookie);
    return bytes;
  }

  static int? _peerPort(Uint8List? bytes) {
    if (bytes == null ||
        bytes.length != 8 ||
        bytes[0] != 0 ||
        bytes[1] != 1 ||
        (_u32(bytes, 4) ^ _cookie) != 0x7f000001) {
      return null;
    }
    return _u16(bytes, 2) ^ (_cookie >> 16);
  }
}

class _TurnAllocation {
  _TurnAllocation(this.client, this.username, this.reservation);
  final _TurnClient client;
  final String username;
  final RawDatagramSocket reservation;
  int get port => reservation.port;
  DateTime expires = DateTime.now().add(
    const Duration(seconds: UsbTurnRelay._allocationLifetime),
  );
  DateTime permissionExpires = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<int, _TurnChannel> channels = {};
}

class _TurnChannel {
  _TurnChannel(this.peerPort, this.expires);
  final int peerPort;
  final DateTime expires;
}

class _TurnClient {
  _TurnClient(this.relay, this.socket);
  final UsbTurnRelay relay;
  final Socket socket;
  final String nonce = _secret(24);
  _TurnAllocation? allocation;
  bool closed = false;
  final _buffer = <int>[];
  final Queue<Uint8List> _output = Queue();
  int _outputBytes = 0;
  int _pendingFrames = 0;
  Future<void> _processing = Future.value();
  bool _writing = false;
  StreamSubscription<Uint8List>? _input;
  Timer? _openingTimeout;

  void start() {
    waitForAllocation();
    _input = socket.listen(_read, onError: (_) => close(), onDone: close);
  }

  void waitForAllocation() {
    _openingTimeout?.cancel();
    _openingTimeout = Timer(const Duration(seconds: 15), () {
      if (allocation == null) close();
    });
  }

  void close() {
    if (closed) return;
    closed = true;
    _openingTimeout?.cancel();
    unawaited(_input?.cancel());
    socket.destroy();
    _output.clear();
    _buffer.clear();
    relay._remove(this);
  }

  void _read(Uint8List chunk) {
    if (closed) return;
    if (_buffer.length + chunk.length > 131072) {
      close();
      return;
    }
    _buffer.addAll(chunk);
    var consumed = 0;
    while (_buffer.length - consumed >= 4) {
      final high = _buffer[consumed] & 0xc0;
      final channel = high == 0x40;
      if (high != 0 && !channel) {
        close();
        return;
      }
      final header = channel ? 4 : 20;
      if (_buffer.length - consumed < header) break;
      final length = (_buffer[consumed + 2] << 8) | _buffer[consumed + 3];
      if (!channel && (length & 3) != 0) {
        close();
        return;
      }
      final total = header + (channel ? (length + 3) & ~3 : length);
      if (_buffer.length - consumed < total) break;
      if (++_pendingFrames > 256) {
        close();
        return;
      }
      final frame = Uint8List.fromList(
        _buffer.sublist(consumed, consumed + total),
      );
      consumed += total;
      _processing = _processing
          .then((_) => relay._handle(this, frame))
          .catchError((Object _) {
            close();
          })
          .whenComplete(() => _pendingFrames--);
    }
    if (!closed && consumed > 0) _buffer.removeRange(0, consumed);
  }

  void write(Uint8List frame) {
    if (closed) return;
    if (_outputBytes + frame.length > 524288) {
      close();
      return;
    }
    _output.add(frame);
    _outputBytes += frame.length;
    if (!_writing) unawaited(_drain());
  }

  Future<void> _drain() async {
    _writing = true;
    try {
      while (_output.isNotEmpty && !closed) {
        var bytes = 0;
        while (_output.isNotEmpty && bytes < 65536) {
          final frame = _output.removeFirst();
          socket.add(frame);
          bytes += frame.length;
        }
        await socket.flush().timeout(const Duration(seconds: 3));
        _outputBytes -= bytes;
      }
    } catch (_) {
      close();
    } finally {
      _writing = false;
    }
  }

  void reply(
    _StunMessage request,
    int type,
    List<Uint8List> attributes, {
    Uint8List? key,
  }) => write(_stun(type, request.transaction, attributes, key: key));
  void error(
    _StunMessage request,
    int code,
    String reason, {
    Uint8List? key,
    bool challenge = false,
  }) {
    reply(request, request.type | 0x0110, [
      _attribute(0x0009, [
        0,
        0,
        code ~/ 100,
        code % 100,
        ...utf8.encode(reason),
      ]),
      if (challenge) _attribute(0x0014, utf8.encode(UsbTurnRelay._realm)),
      if (challenge) _attribute(0x0015, utf8.encode(nonce)),
    ], key: key);
  }
}

class _StunMessage {
  _StunMessage(this.bytes, this.type, this.transaction, this.attributes);
  final Uint8List bytes;
  final int type;
  final Uint8List transaction;
  final List<_StunAttribute> attributes;
  Uint8List? first(int type) =>
      attributes.where((item) => item.type == type).firstOrNull?.value;
  Iterable<Uint8List> all(int type) =>
      attributes.where((item) => item.type == type).map((item) => item.value);
  static _StunMessage? parse(Uint8List bytes) {
    if (bytes.length < 20 ||
        _u32(bytes, 4) != UsbTurnRelay._cookie ||
        _u16(bytes, 2) + 20 != bytes.length) {
      return null;
    }
    final attributes = <_StunAttribute>[];
    var offset = 20;
    while (offset + 4 <= bytes.length) {
      final length = _u16(bytes, offset + 2);
      final end = offset + 4 + length;
      if (end > bytes.length) return null;
      attributes.add(
        _StunAttribute(
          _u16(bytes, offset),
          offset,
          Uint8List.sublistView(bytes, offset + 4, end),
        ),
      );
      offset += 4 + ((length + 3) & ~3);
    }
    if (offset != bytes.length || attributes.length > 64) return null;
    return _StunMessage(
      bytes,
      _u16(bytes, 0),
      Uint8List.sublistView(bytes, 8, 20),
      attributes,
    );
  }

  bool authentic(Uint8List key) {
    for (final unique in [0x0006, 0x0014, 0x0015, 0x0008]) {
      if (attributes.where((item) => item.type == unique).length != 1) {
        return false;
      }
    }
    final integrity = attributes.firstWhere((item) => item.type == 0x0008);
    if (integrity.value.length != 20 ||
        attributes.any(
          (item) => item.offset > integrity.offset && item.type != 0x8028,
        )) {
      return false;
    }
    final signed = Uint8List.fromList(bytes.sublist(0, integrity.offset));
    _put16(signed, 2, integrity.offset + 24 - 20);
    final expected = Hmac(sha1, key).convert(signed).bytes;
    var different = 0;
    for (var i = 0; i < expected.length; i++) {
      different |= expected[i] ^ integrity.value[i];
    }
    return different == 0;
  }
}

class _StunAttribute {
  _StunAttribute(this.type, this.offset, this.value);
  final int type;
  final int offset;
  final Uint8List value;
}

String? _text(Uint8List? bytes) {
  if (bytes == null) return null;
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return null;
  }
}

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

String _secret(int length) =>
    base64Url.encode(_randomBytes(length)).replaceAll('=', '');
int _u16(List<int> bytes, int offset) =>
    (bytes[offset] << 8) | bytes[offset + 1];
int _u32(List<int> bytes, int offset) =>
    (_u16(bytes, offset) << 16) | _u16(bytes, offset + 2);
void _put16(Uint8List bytes, int offset, int value) {
  bytes[offset] = value >> 8;
  bytes[offset + 1] = value;
}

void _put32(Uint8List bytes, int offset, int value) {
  _put16(bytes, offset, value >> 16);
  _put16(bytes, offset + 2, value);
}

Uint8List _uint32(int value) {
  final bytes = Uint8List(4);
  _put32(bytes, 0, value);
  return bytes;
}

Uint8List _attribute(int type, List<int> value) {
  final bytes = Uint8List(4 + ((value.length + 3) & ~3));
  _put16(bytes, 0, type);
  _put16(bytes, 2, value.length);
  bytes.setRange(4, 4 + value.length, value);
  return bytes;
}

Uint8List _stun(
  int type,
  Uint8List transaction,
  List<Uint8List> attributes, {
  Uint8List? key,
}) {
  final length = attributes.fold<int>(0, (sum, value) => sum + value.length);
  final bytes = Uint8List(20 + length + (key == null ? 0 : 24));
  _put16(bytes, 0, type);
  _put16(bytes, 2, bytes.length - 20);
  _put32(bytes, 4, UsbTurnRelay._cookie);
  bytes.setRange(8, 20, transaction);
  var offset = 20;
  for (final attribute in attributes) {
    bytes.setRange(offset, offset + attribute.length, attribute);
    offset += attribute.length;
  }
  if (key != null) {
    final digest = Hmac(
      sha1,
      key,
    ).convert(Uint8List.sublistView(bytes, 0, offset)).bytes;
    bytes.setRange(offset, bytes.length, _attribute(0x0008, digest));
  }
  return bytes;
}
