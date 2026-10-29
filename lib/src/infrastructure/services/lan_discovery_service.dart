import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/network_service.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

class LanDiscoveryService {
  LanDiscoveryService(
    this._logger, {
    bool? isAndroid,
    NetworkService? networkService,
  }) : _isAndroid = isAndroid ?? Platform.isAndroid,
       _networkService = networkService ?? NetworkService();

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
  final NetworkService _networkService;
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
  List<LanInterface> _lanInterfaces = const [];
  final _broadcastDestinations = <String, InternetAddress>{};
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
      includeLinkLocal: true,
    );
    final lan = await _networkService.lanInterfaces();
    _lanInterfaces = lan;
    final eligibleAddresses = <String, int?>{
      for (final interface in lan)
        for (final address in interface.addresses)
          address.address: interface.prefixLengths[address.address],
    };
    final outgoing = <InternetAddress>[];
    for (final interface in interfaces) {
      final addresses = interface.addresses
          .where(
            (address) =>
                eligibleAddresses.containsKey(address.address) ||
                (address.isLoopback && address.address == self.ip),
          )
          .toList();
      if (addresses.isEmpty) continue;
      // Sending on an interface does not depend on multicast reception.
      outgoing.addAll(addresses);
      for (final address in addresses) {
        if (address.isLoopback) continue;
        final prefix = eligibleAddresses[address.address];
        if (prefix == 31 || prefix == 32) continue;
        _broadcastDestinations[address.address] =
            _subnetBroadcast(address, prefix) ?? _broadcastAddress;
      }
      try {
        socket.joinMulticast(multicastAddress, interface);
      } catch (error) {
        _logger.warn('Multicast join on ${interface.name} unavailable: $error');
      }
    }
    _outgoingAddresses = outgoing;
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
                final localAddress = _replyAddress(datagram.address);
                if (replyPort is int &&
                    replyPort > 0 &&
                    replyPort <= 65535 &&
                    localAddress != null) {
                  unawaited(
                    _sender('unicast:${localAddress.address}').send(
                      data,
                      datagram.address,
                      replyPort,
                      localAddress: localAddress,
                    ),
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

  InternetAddress? _subnetBroadcast(
    InternetAddress address,
    int? prefixLength,
  ) {
    if (prefixLength == null || prefixLength < 1 || prefixLength > 30) {
      return null;
    }
    final bytes = address.rawAddress;
    return InternetAddress.fromRawAddress(
      Uint8List.fromList([
        for (var i = 0; i < bytes.length; i++)
          bytes[i] | (0xff >> (prefixLength - i * 8).clamp(0, 8)),
      ]),
    );
  }

  InternetAddress? _replyAddress(InternetAddress remote) {
    if (remote.isLoopback) {
      return _outgoingAddresses
          .where((address) => address.isLoopback)
          .firstOrNull;
    }
    InternetAddress? best;
    var longestPrefix = -1;
    for (final interface in _lanInterfaces) {
      for (final local in interface.addresses) {
        final prefix = interface.prefixLengths[local.address];
        if (prefix != null &&
            prefix > longestPrefix &&
            sameIpv4Subnet(local, remote, prefix)) {
          best = local;
          longestPrefix = prefix;
        }
      }
    }
    return best ?? _lanInterfaces.firstOrNull?.addresses.firstOrNull;
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
          localAddress: address,
        ),
      for (final entry in _broadcastDestinations.entries)
        _sender('broadcast:${entry.key}').send(
          data,
          entry.value,
          multicastPort,
          localAddress: InternetAddress(entry.key),
        ),
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
    _lanInterfaces = const [];
    _broadcastDestinations.clear();
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

// Owns one outbound transport. It never shares the discovery receive socket.
// Would-block writes get a bounded retry; socket errors wait for the next send.
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
    InternetAddress? localAddress,
  }) {
    if (_closed) return Future<void>.value();
    _pending = _pending.then((_) async {
      if (_closed) return;
      try {
        var socket = _socket;
        if (socket == null) {
          await _subscription?.cancel();
          _subscription = null;
          socket = await RawDatagramSocket.bind(
            localAddress ?? InternetAddress.anyIPv4,
            0,
          );
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
        final retryClock = Stopwatch()..start();
        while (!_closed && identical(_socket, socket)) {
          final sent = socket.send(data, destination, port);
          if (sent == data.length) return;
          if (sent != 0) {
            _logger.warn(
              'Discovery $_name dropped a datagram after a short UDP write',
            );
            return;
          }
          if (retryClock.elapsed >= const Duration(milliseconds: 250)) {
            _logger.warn(
              'Discovery $_name dropped a datagram: UDP remained blocked for 250 ms',
            );
            return;
          }
          // Windows can have an outstanding native send even though this
          // transport serializes Dart calls. Let its completion run first.
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
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
