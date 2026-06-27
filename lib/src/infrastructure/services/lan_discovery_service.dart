import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';

class LanDiscoveryService {
  LanDiscoveryService(this._logger);

  static const int multicastPort = 53318;
  static final InternetAddress multicastAddress = InternetAddress(
    '224.0.0.251',
  );
  static const String serviceType = '_bshare._tcp.local';

  final AppLogger _logger;
  RawDatagramSocket? _socket;
  Timer? _announceTimer;
  final _devices = StreamController<DeviceInfo>.broadcast();

  Stream<DeviceInfo> get devices => _devices.stream;

  Future<void> start(DeviceInfo self, {required bool advertise}) async {
    await stop();
    _socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      multicastPort,
      reuseAddress: true,
      reusePort: true,
    );
    try {
      _socket!.joinMulticast(multicastAddress);
    } catch (error) {
      _logger.warn('Multicast join unavailable: $error');
    }
    _socket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _socket!.receive();
      if (datagram == null) return;
      try {
        final payload = utf8.decode(datagram.data);
        final json = jsonDecode(payload) as Map<String, dynamic>;
        if (json['service'] != serviceType || json['id'] == self.id) return;
        final device = DeviceInfo.fromJson({
          ...json,
          'lastSeen': DateTime.now().toIso8601String(),
        });
        _devices.add(device);
      } catch (error) {
        _logger.warn('Ignoring invalid discovery packet: $error');
      }
    });
    if (advertise) {
      _announce(self);
      _announceTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => _announce(self),
      );
    }
  }

  void _announce(DeviceInfo self) {
    final data = utf8.encode(
      jsonEncode({...self.toJson(), 'service': serviceType}),
    );
    _socket?.send(data, multicastAddress, multicastPort);
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _announceTimer = null;
    _socket?.close();
    _socket = null;
  }

  Future<void> dispose() async {
    await stop();
    await _devices.close();
  }
}
