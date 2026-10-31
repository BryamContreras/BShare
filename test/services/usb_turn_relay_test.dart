import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bshare/src/infrastructure/services/usb_turn_relay.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const _cookie = 0x2112a442;
int _u16(List<int> bytes, int offset) =>
    bytes[offset] * 256 + bytes[offset + 1];
void _put16(Uint8List bytes, int offset, int value) {
  bytes[offset] = value >> 8;
  bytes[offset + 1] = value;
}

Uint8List _attr(int type, List<int> data) {
  final value = Uint8List(4 + ((data.length + 3) ~/ 4) * 4);
  _put16(value, 0, type);
  _put16(value, 2, data.length);
  value.setRange(4, 4 + data.length, data);
  return value;
}

Uint8List _address(int port, {String ip = '127.0.0.1'}) {
  final value = Uint8List(8)..[1] = 1;
  _put16(value, 2, port ^ 0x2112);
  final address = InternetAddress(ip).rawAddress;
  for (var index = 0; index < 4; index++) {
    value[4 + index] = address[index] ^ [0x21, 0x12, 0xa4, 0x42][index];
  }
  return value;
}

Map<int, Uint8List> _attributes(Uint8List frame) {
  final attributes = <int, Uint8List>{};
  for (var offset = 20; offset < frame.length;) {
    final length = _u16(frame, offset + 2);
    attributes[_u16(frame, offset)] = Uint8List.sublistView(
      frame,
      offset + 4,
      offset + 4 + length,
    );
    offset += 4 + ((length + 3) ~/ 4) * 4;
  }
  return attributes;
}

int _error(Uint8List frame) {
  final error = _attributes(frame)[0x0009]!;
  return error[2] * 100 + error[3];
}

class _Client {
  _Client(this.socket, this.username, this.password)
    : input = StreamIterator(socket);
  final Socket socket;
  final StreamIterator<Uint8List> input;
  final String username;
  final String password;
  final List<int> _pending = [];
  int _transaction = 0;
  String? realm;
  String? nonce;
  Uint8List? get key => realm == null
      ? null
      : Uint8List.fromList(
          md5.convert(utf8.encode('$username:$realm:$password')).bytes,
        );
  static Future<_Client> connect(
    UsbTurnRelay relay,
    Map<String, dynamic> configuration, {
    String? password,
  }) async {
    final credentials = (configuration['iceServers'] as List).first as Map;
    return _Client(
      await Socket.connect('127.0.0.1', relay.port),
      credentials['username'] as String,
      password ?? credentials['credential'] as String,
    );
  }

  Future<Uint8List> read() async {
    Future<void> ensure(int length) async {
      while (_pending.length < length) {
        if (!await input.moveNext().timeout(const Duration(seconds: 2))) {
          throw StateError('TURN socket closed');
        }
        _pending.addAll(input.current);
      }
    }

    await ensure(4);
    final channel = (_pending[0] & 0xc0) == 0x40;
    final length = _u16(_pending, 2);
    final total = channel ? 4 + ((length + 3) ~/ 4) * 4 : 20 + length;
    await ensure(total);
    final frame = Uint8List.fromList(_pending.sublist(0, total));
    _pending.removeRange(0, total);
    return frame;
  }

  Uint8List frame(
    int type,
    List<Uint8List> attributes, {
    bool authenticate = true,
  }) {
    final fields = [...attributes];
    final signingKey = authenticate ? key : null;
    if (signingKey != null) {
      fields.addAll([
        _attr(0x0006, utf8.encode(username)),
        _attr(0x0014, utf8.encode(realm!)),
        _attr(0x0015, utf8.encode(nonce!)),
      ]);
    }
    final length = fields.fold<int>(0, (sum, field) => sum + field.length);
    final bytes = Uint8List(20 + length + (signingKey == null ? 0 : 24));
    final header = ByteData.sublistView(bytes);
    header.setUint16(0, type);
    header.setUint16(2, bytes.length - 20);
    header.setUint32(4, _cookie);
    header.setUint32(16, ++_transaction);
    var offset = 20;
    for (final field in fields) {
      bytes.setRange(offset, offset + field.length, field);
      offset += field.length;
    }
    if (signingKey != null) {
      final integrity = Hmac(
        sha1,
        signingKey,
      ).convert(bytes.sublist(0, offset)).bytes;
      bytes.setRange(offset, bytes.length, _attr(0x0008, integrity));
    }
    return bytes;
  }

  Future<Uint8List> request(int type, List<Uint8List> attributes) async {
    socket.add(frame(type, attributes));
    await socket.flush();
    return read();
  }

  Future<Uint8List> allocate() async {
    final challenge = await request(0x0003, [
      _attr(0x0019, [17, 0, 0, 0]),
    ]);
    expect(_error(challenge), 401);
    final fields = _attributes(challenge);
    realm = utf8.decode(fields[0x0014]!);
    nonce = utf8.decode(fields[0x0015]!);
    return request(0x0003, [
      _attr(0x0019, [17, 0, 0, 0]),
    ]);
  }

  Future<void> close() async {
    socket.destroy();
    await input.cancel();
  }
}

void main() {
  test(
    'allocations require real credentials, enforce role quota and authenticate responses',
    () async {
      final relay = await UsbTurnRelay.start();
      addTearDown(relay.close);
      final config = relay.desktopIceConfiguration();
      final wrong = await _Client.connect(relay, config, password: 'incorrect');
      addTearDown(wrong.close);
      expect(_error(await wrong.allocate()), 401);
      expect(relay.allocationCount, 0);
      final client = await _Client.connect(relay, config);
      addTearDown(client.close);
      final allocation = await client.allocate();
      expect(_u16(allocation, 0), 0x0103);
      expect(relay.allocationCount, 1);
      final integrityOffset = allocation.length - 24;
      expect(
        _attributes(allocation)[0x0008],
        Hmac(
          sha1,
          client.key!,
        ).convert(allocation.sublist(0, integrityOffset)).bytes,
      );
      final duplicate = await _Client.connect(relay, config);
      addTearDown(duplicate.close);
      expect(_error(await duplicate.allocate()), 486);
      final corrupt = client.frame(0x0004, []);
      corrupt[corrupt.length - 1] ^= 1;
      client.socket.add(corrupt);
      await client.socket.flush();
      expect(_error(await client.read()), 401);
      expect(relay.allocationCount, 1);
    },
  );

  test(
    'only live assigned loopback peers can receive framed channel data',
    () async {
      final relay = await UsbTurnRelay.start();
      addTearDown(relay.close);
      final a = await _Client.connect(relay, relay.desktopIceConfiguration());
      addTearDown(a.close);
      final b = await _Client.connect(
        relay,
        relay.androidIceConfiguration(relay.port),
      );
      addTearDown(b.close);
      final aAllocation = await a.allocate();
      final bAllocation = await b.allocate();
      final aPort = _u16(_attributes(aAllocation)[0x0016]!, 2) ^ 0x2112;
      final bPort = _u16(_attributes(bAllocation)[0x0016]!, 2) ^ 0x2112;
      expect(
        _error(
          await a.request(0x0008, [
            _attr(0x0012, _address(9, ip: '192.168.1.1')),
          ]),
        ),
        403,
      );
      expect(
        _error(await a.request(0x0008, [_attr(0x0012, _address(9))])),
        403,
      );
      expect(
        _error(await a.request(0x0008, [_attr(0x0012, _address(aPort))])),
        403,
      );
      expect(
        _u16(await a.request(0x0008, [_attr(0x0012, _address(bPort))]), 0),
        0x0108,
      );
      expect(
        _u16(await b.request(0x0008, [_attr(0x0012, _address(aPort))]), 0),
        0x0108,
      );
      a.socket.add(
        a.frame(0x0016, [
          _attr(0x0012, _address(bPort)),
          _attr(0x0013, [1, 2, 3]),
        ], authenticate: false),
      );
      final indication = await b.read();
      expect(_u16(indication, 0), 0x0017);
      expect(_attributes(indication)[0x0013], [1, 2, 3]);
      expect(
        _u16(
          await a.request(0x0009, [
            _attr(0x000c, [0x40, 0, 0, 0]),
            _attr(0x0012, _address(bPort)),
          ]),
          0,
        ),
        0x0109,
      );
      expect(
        _u16(
          await b.request(0x0009, [
            _attr(0x000c, [0x40, 1, 0, 0]),
            _attr(0x0012, _address(aPort)),
          ]),
          0,
        ),
        0x0109,
      );
      // Odd payload length, TCP padding and deliberately fragmented framing.
      a.socket.add([0x40, 0]);
      await a.socket.flush();
      a.socket.add([0, 3, 7, 8, 9, 0]);
      await a.socket.flush();
      expect(await b.read(), [0x40, 1, 0, 3, 7, 8, 9, 0]);
      final refreshed = await a.request(0x0004, [
        _attr(0x000d, [0, 0, 0, 0]),
      ]);
      expect(_u16(refreshed, 0), 0x0104);
      expect(relay.allocationCount, 1);
      expect(
        _error(await b.request(0x0008, [_attr(0x0012, _address(aPort))])),
        403,
      );
    },
  );

  test(
    'malformed TCP framing closes client and shutdown releases the listener',
    () async {
      final relay = await UsbTurnRelay.start();
      final port = relay.port;
      final socket = await Socket.connect('127.0.0.1', port);
      final closed = socket.drain<void>();
      socket.add([0x80, 0, 0, 0]);
      await socket.flush();
      await closed.timeout(const Duration(seconds: 2));
      socket.destroy();
      await relay.close();
      await relay.close();
      await expectLater(
        Socket.connect('127.0.0.1', port),
        throwsA(isA<SocketException>()),
      );
    },
  );

  test(
    'desktop self listeners support NIC-bound clients while relayed candidates remain loopback',
    () async {
      final relay = await UsbTurnRelay.start();
      addTearDown(relay.close);
      final servers = relay.desktopIceConfiguration()['iceServers'] as List;
      expect(servers.length, inInclusiveRange(1, 8));
      expect((servers.last as Map)['urls'], [
        'turn:127.0.0.1:${relay.port}?transport=tcp',
      ]);
      expect(
        (relay.androidIceConfiguration(51000)['iceServers'] as List)
            .single['urls'],
        ['turn:127.0.0.1:51000?transport=tcp'],
      );
      final owned = {
        for (final interface in await NetworkInterface.list(
          type: InternetAddressType.IPv4,
        ))
          for (final address in interface.addresses) address.address,
      };
      var verified = false;
      for (final item in servers.take(servers.length - 1)) {
        final entry = item as Map;
        final match = RegExp(
          r'^turn:([^:]+):(\d+)\?transport=tcp$',
        ).firstMatch((entry['urls'] as List).single as String)!;
        final address = match[1]!;
        final port = int.parse(match[2]!);
        expect(owned, contains(address));
        expect(address, isNot('0.0.0.0'));
        Socket socket;
        try {
          socket = await Socket.connect(
            address,
            port,
            sourceAddress: address,
            timeout: const Duration(milliseconds: 250),
          );
        } on SocketException {
          continue;
        }
        final client = _Client(
          socket,
          entry['username'] as String,
          entry['credential'] as String,
        );
        addTearDown(client.close);
        final allocated = _attributes(await client.allocate());
        expect(allocated[0x0016]!.sublist(4), _address(0).sublist(4));
        expect(
          allocated[0x0020]!.sublist(4),
          _address(0, ip: address).sublist(4),
        );
        expect(relay.diagnostics['localInterfaceClients'], greaterThan(0));
        expect(relay.diagnostics['allocateSuccess'], 1);
        verified = true;
        break;
      }
      if (servers.length > 1) expect(verified, isTrue);
      expect(relay.diagnostics.values, everyElement(isA<int>()));
    },
  );
}
