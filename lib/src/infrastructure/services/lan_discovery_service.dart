import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

class LanDiscoveryService {
  LanDiscoveryService(this._logger, {bool? isAndroid})
    : _isAndroid = isAndroid ?? Platform.isAndroid;

  static const int multicastPort = 53318;
  static const announceInterval = Duration(seconds: 3);
  static final InternetAddress multicastAddress = InternetAddress(
    '224.0.0.251',
  );
  static const String serviceType = '_bshare._tcp.local';
  static const String queryServiceType = '_bshare-query._udp.local';
  static const String goodbyeServiceType = '_bshare-goodbye._udp.local';
  static const _channel = MethodChannel('bshare/discovery');
  static final _broadcastAddress = InternetAddress('255.255.255.255');

  final AppLogger _logger;
  final bool _isAndroid;
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  Timer? _announceTimer;
  Future<void> _lifecycle = Future<void>.value();
  final _devices = StreamController<DeviceInfo>.broadcast();
  final _departures = StreamController<DeviceInfo>.broadcast();
  bool _disposed = false;
  bool _multicastAcquired = false;
  DeviceInfo? _self;
  List<InternetAddress> _outgoingAddresses = const [];
  final _senders = <String, _DiscoverySender>{};
  final _recentPackets = <String, DateTime>{};
  final _peerSessions = <String, String>{};
  Map<String, dynamic>? _advertisement;

  Stream<DeviceInfo> get devices => _devices.stream;
  Stream<DeviceInfo> get departures => _departures.stream;

  Future<void> _serialize(Future<void> Function() action) {
    final operation = _lifecycle.then((_) => action());
    _lifecycle = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return operation;
  }

  Future<void> start(DeviceInfo self, {required bool advertise}) =>
      _serialize(() async {
        if (_disposed) throw StateError('Discovery service is disposed');
        await _stop();
        try {
          if (_isAndroid) {
            try {
              await _channel.invokeMethod<void>('acquireMulticast');
              _multicastAcquired = true;
            } catch (error) {
              _logger.warn(
                'Wi-Fi multicast unavailable; using LAN fallback: $error',
              );
            }
          }
          await _startSocket(self, advertise: advertise);
        } catch (_) {
          await _stop();
          rethrow;
        }
      });

  Future<void> _startSocket(DeviceInfo self, {required bool advertise}) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      multicastPort,
      reuseAddress: true,
      reusePort: !(_isAndroid || Platform.isWindows),
    );
    _socket = socket;
    _self = self;
    // Joining only the default route misses Wi-Fi/Ethernet when a VPN or a
    // second adapter is preferred. Send and listen on the actual LAN adapters.
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: true,
    );
    final outgoing = <InternetAddress>[];
    for (final interface in interfaces) {
      final name = interface.name.toLowerCase();
      if (!interface.addresses.any((address) => address.address == self.ip) &&
          (name.startsWith('docker') ||
              name.startsWith('veth') ||
              name.startsWith('br-') ||
              name.startsWith('virbr') ||
              name.startsWith('vmnet') ||
              name.contains('vmware') ||
              name.contains('virtualbox') ||
              name.startsWith('tun') ||
              name.startsWith('tap') ||
              name.startsWith('wg') ||
              name.startsWith('tailscale'))) {
        continue;
      }
      final addresses = interface.addresses.where(
        (address) => address.address == self.ip || _isLanAddress(address),
      );
      if (addresses.isEmpty) continue;
      try {
        socket.joinMulticast(multicastAddress, interface);
        outgoing.addAll(addresses);
      } catch (error) {
        _logger.warn('Multicast join on ${interface.name} unavailable: $error');
      }
    }
    _outgoingAddresses = outgoing;
    if (outgoing.isEmpty) {
      try {
        socket.joinMulticast(multicastAddress);
      } catch (error) {
        _logger.warn('Multicast join unavailable: $error');
      }
    }
    final advertisement = {
      ...self.toJson(),
      'service': serviceType,
      'session': const Uuid().v4(),
    };
    _advertisement = advertise ? advertisement : null;
    final data = utf8.encode(jsonEncode(advertisement));
    _subscription = socket.listen(
      (event) {
        if (event != RawSocketEvent.read || _disposed) return;
        // Drain every queued datagram per notification without referring to a
        // socket that a later start operation may have replaced.
        Datagram? datagram;
        while ((datagram = socket.receive()) != null) {
          try {
            if (datagram!.data.length > 8192) continue;
            final json =
                jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;
            if (json['id'] == self.id) {
              continue;
            }
            if (json['service'] == queryServiceType) {
              if (_advertisement != null &&
                  _acceptPacket('query:${datagram.address.address}')) {
                // Our sender has an ephemeral source port, while replies go
                // to the persistent discovery listener. Older query senders
                // can still receive a reply at their original source port.
                final replyPort = json['replyPort'] ?? datagram.port;
                if (replyPort is int && replyPort > 0 && replyPort <= 65535) {
                  unawaited(
                    _sender('unicast').send(data, datagram.address, replyPort),
                  );
                }
              }
              continue;
            }
            final departing = json['service'] == goodbyeServiceType;
            if (json['service'] != serviceType && !departing) continue;
            final device = DeviceInfo.fromJson({
              ...json,
              // The source is reachable on this LAN even when the advertised
              // address belongs to another adapter or an old DHCP lease.
              'ip': datagram.address.address,
              'lastSeen': DateTime.now().toIso8601String(),
            });
            if (device.id.isEmpty || device.port < 1 || device.port > 65535) {
              continue;
            }
            final endpoint = '${device.id}:${device.ip}:${device.port}';
            final session = json['session'];
            if (departing) {
              // A delayed goodbye from a previous listener must not remove a
              // renewed announcement at the same endpoint.
              if (session is String && _peerSessions[endpoint] == session) {
                _peerSessions.remove(endpoint);
                _departures.add(device);
              }
              continue;
            }
            if (!_acceptPacket('$endpoint:$session')) {
              continue;
            }
            if (session is String) {
              if (_peerSessions.length >= 256) {
                _peerSessions.remove(_peerSessions.keys.first);
              }
              _peerSessions[endpoint] = session;
            } else {
              _peerSessions.remove(endpoint);
            }
            _devices.add(device);
          } catch (error) {
            _logger.warn('Ignoring invalid discovery packet: $error');
          }
        }
      },
      onError: (Object error) {
        _logger.warn('Discovery socket failed: $error');
      },
    );
    requestDiscovery();
    if (advertise) {
      unawaited(_sendToLan(data));
      _announceTimer = Timer.periodic(
        announceInterval,
        (_) => unawaited(_sendToLan(data)),
      );
    }
  }

  bool _isLanAddress(InternetAddress address) {
    final bytes = address.rawAddress;
    return !address.isLoopback &&
        (bytes[0] == 10 ||
            (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
            (bytes[0] == 192 && bytes[1] == 168));
  }

  bool _acceptPacket(String key) {
    final now = DateTime.now();
    final previous = _recentPackets[key];
    if (previous != null &&
        now.difference(previous) < const Duration(milliseconds: 500)) {
      return false;
    }
    // Bound memory even on a noisy/untrusted network.
    if (_recentPackets.length >= 256) {
      _recentPackets.remove(_recentPackets.keys.first);
    }
    _recentPackets[key] = now;
    return true;
  }

  void requestDiscovery() {
    final self = _self;
    if (_disposed || self == null) return;
    unawaited(
      _sendToLan(
        utf8.encode(
          jsonEncode({
            'service': queryServiceType,
            'id': self.id,
            'replyPort': multicastPort,
          }),
        ),
      ),
    );
  }

  _DiscoverySender _sender(String name) =>
      _senders.putIfAbsent(name, () => _DiscoverySender(_logger, name));

  Future<void> _sendToLan(List<int> data) async {
    if (_socket == null || _disposed) return;
    // Dart closes a UDP socket after an asynchronous send error (for example
    // ENETUNREACH). Optional broadcast or an unavailable multicast adapter
    // must never close the persistent listener or another working transport.
    await Future.wait([
      for (final address in _outgoingAddresses)
        _sender('multicast:${address.address}').send(
          data,
          multicastAddress,
          multicastPort,
          multicastInterface: address,
        ),
      if (_outgoingAddresses.isEmpty)
        _sender('multicast').send(data, multicastAddress, multicastPort),
      _sender('broadcast').send(data, _broadcastAddress, multicastPort),
    ]);
  }

  Future<void> _stop() async {
    _announceTimer?.cancel();
    _announceTimer = null;
    _self = null;
    final advertisement = _advertisement;
    _advertisement = null;
    if (advertisement != null) {
      await _sendToLan(
        utf8.encode(
          jsonEncode({...advertisement, 'service': goodbyeServiceType}),
        ),
      );
    }
    final subscription = _subscription;
    _subscription = null;
    _socket?.close();
    _socket = null;
    await subscription?.cancel();
    final senders = _senders.values.toList();
    _senders.clear();
    await Future.wait(senders.map((sender) => sender.close()));
    _outgoingAddresses = const [];
    _recentPackets.clear();
    _peerSessions.clear();
    if (_multicastAcquired) {
      _multicastAcquired = false;
      try {
        await _channel.invokeMethod<void>('releaseMulticast');
      } catch (error) {
        _logger.warn('Could not release Wi-Fi multicast: $error');
      }
    }
  }

  Future<void> stop() => _serialize(_stop);

  Future<void> dispose() => _serialize(() async {
    if (_disposed) return;
    await _stop();
    _disposed = true;
    await _devices.close();
    await _departures.close();
  });
}

// Owns one outbound transport. It never shares the discovery receive socket,
// and failed sends are retried only on the next requested announcement/query.
class _DiscoverySender {
  _DiscoverySender(this._logger, this._name);

  final AppLogger _logger;
  final String _name;
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  Future<void> _pending = Future<void>.value();
  bool _closed = false;

  Future<void> send(
    List<int> data,
    InternetAddress destination,
    int port, {
    InternetAddress? multicastInterface,
  }) {
    if (_closed) return Future<void>.value();
    _pending = _pending.then((_) async {
      if (_closed) return;
      try {
        var socket = _socket;
        if (socket == null) {
          await _subscription?.cancel();
          _subscription = null;
          socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
          if (_closed) {
            socket.close();
            return;
          }
          _socket = socket;
          socket.broadcastEnabled = true;
          socket.readEventsEnabled = false;
          final owned = socket;
          _subscription = socket.listen(
            (_) {},
            onError: (Object error) {
              _logger.warn('Discovery $_name unavailable: $error');
              if (identical(_socket, owned)) _socket = null;
              owned.close();
            },
            onDone: () {
              if (identical(_socket, owned)) _socket = null;
            },
          );
        }
        if (multicastInterface != null) {
          socket.setRawOption(
            RawSocketOption(
              RawSocketOption.levelIPv4,
              RawSocketOption.IPv4MulticastInterface,
              multicastInterface.rawAddress,
            ),
          );
        }
        socket.send(data, destination, port);
      } catch (error) {
        _logger.warn('Discovery $_name unavailable: $error');
        _socket?.close();
        _socket = null;
      }
    });
    return _pending;
  }

  Future<void> close() async {
    _closed = true;
    await _pending;
    _socket?.close();
    _socket = null;
    await _subscription?.cancel();
    _subscription = null;
  }
}
