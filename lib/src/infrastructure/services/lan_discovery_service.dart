import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';

class LanDiscoveryService {
  LanDiscoveryService(this._logger);

  static const int multicastPort = 53318;
  static const announceInterval = Duration(seconds: 3);
  static final InternetAddress multicastAddress = InternetAddress(
    '224.0.0.251',
  );
  static const String serviceType = '_bshare._tcp.local';

  final AppLogger _logger;
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  Timer? _announceTimer;
  Future<void> _lifecycle = Future<void>.value();
  final _devices = StreamController<DeviceInfo>.broadcast();
  bool _disposed = false;

  Stream<DeviceInfo> get devices => _devices.stream;

  Future<void> _serialize(Future<void> Function() action) {
    final operation = _lifecycle.then((_) => action());
    _lifecycle = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return operation;
  }

  Future<void> start(
    DeviceInfo self, {
    required bool advertise,
  }) => _serialize(() async {
    if (_disposed) throw StateError('Discovery service is disposed');
    await _stop();
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      multicastPort,
      reuseAddress: true,
      reusePort: !Platform.isAndroid,
    );
    _socket = socket;
    try {
      socket.joinMulticast(multicastAddress);
    } catch (error) {
      _logger.warn('Multicast join unavailable: $error');
    }
    _subscription = socket.listen(
      (event) {
        if (event != RawSocketEvent.read || _disposed) return;
        // Drain every queued datagram per notification without referring to a
        // socket that a later start operation may have replaced.
        Datagram? datagram;
        while ((datagram = socket.receive()) != null) {
          try {
            final json =
                jsonDecode(utf8.decode(datagram!.data)) as Map<String, dynamic>;
            if (json['service'] != serviceType || json['id'] == self.id) {
              continue;
            }
            final device = DeviceInfo.fromJson({
              ...json,
              'lastSeen': DateTime.now().toIso8601String(),
            });
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
    if (advertise) {
      final data = utf8.encode(
        jsonEncode({...self.toJson(), 'service': serviceType}),
      );
      void announce() {
        try {
          socket.send(data, multicastAddress, multicastPort);
        } catch (error) {
          _logger.warn('Discovery announcement failed: $error');
        }
      }

      announce();
      _announceTimer = Timer.periodic(announceInterval, (_) => announce());
    }
  });

  Future<void> _stop() async {
    _announceTimer?.cancel();
    _announceTimer = null;
    final subscription = _subscription;
    _subscription = null;
    _socket?.close();
    _socket = null;
    await subscription?.cancel();
  }

  Future<void> stop() => _serialize(_stop);

  Future<void> dispose() => _serialize(() async {
    if (_disposed) return;
    _disposed = true;
    await _stop();
    await _devices.close();
  });
}
