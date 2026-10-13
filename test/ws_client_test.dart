import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_scanner/core/ws_client.dart';

Uint8List frame(List<int> payload) {
  final header = ByteData(10)
    ..setUint8(0, 0x82)
    ..setUint8(1, 127)
    ..setUint64(2, payload.length);
  return Uint8List.fromList([...header.buffer.asUint8List(), ...payload]);
}

void main() {
  test('跨 TCP 分包保留下一帧的尾部且接收缓冲区不污染已发送消息', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final first = Uint8List.fromList(List.generate(100000, (i) => i & 255));
    final second = Uint8List.fromList(
      List.generate(85000, (i) => 255 - (i & 255)),
    );
    final third = Uint8List.fromList([55, 66, 77]);
    final completed = Completer<Socket>();
    server.listen((socket) {
      completed.complete(socket);
      var upgraded = false;
      socket.listen((chunk) async {
        if (!upgraded) {
          upgraded = true;
          socket.write(
            'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n',
          );
        } else {
          final b = frame(second);
          socket.add([...frame(first), ...b.take(41)]);
          await socket.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
          socket.add([...b.skip(41), ...frame(third)]);
        }
      });
    });
    final client = await WsClient.connect('127.0.0.1', server.port);
    final received = client.messages.take(3).toList();
    client.sendBytes([1]);
    final messages = await received.timeout(const Duration(seconds: 5));
    expect(messages[0], first);
    expect(messages[1], second);
    expect(messages[2], third);
    client.close();
    (await completed.future).destroy();
    await server.close();
  });
}
