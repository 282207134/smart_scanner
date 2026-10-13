import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_scanner/backend/km_server_backend.dart';
import 'package:image/image.dart' as img;

Uint8List preview(int width, int height, {int x = 0, int y = 0}) =>
    Uint8List.fromList([
      0x55,
      0x66,
      0xCC,
      width >> 8,
      width & 255,
      height >> 8,
      height & 255,
      x >> 8,
      x & 255,
      y >> 8,
      y & 255,
      ...List.filled(width * height * 3, 120),
    ]);

Future<KmServerBackend> serverBackend(
  void Function(WebSocket socket, int attempt) onOpen, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final sockets = <WebSocket>[];
  var attempt = 0;
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    sockets.add(socket);
    socket.listen((message) {
      if (message is List<int> && message.length >= 3 && message[2] == 1) {
        onOpen(socket, ++attempt);
      }
    });
  });
  final backend = KmServerBackend(
    serverPort: server.port,
    openTimeout: timeout,
    captureSettling: const Duration(milliseconds: 120),
  );
  addTearDown(() async {
    await backend.disconnect();
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  });
  await backend.connect();
  return backend;
}

Future<void> open(KmServerBackend backend) => backend.open(
  deviceIndex: 0,
  canvasW: 100,
  canvasH: 80,
  captureW: 640,
  captureH: 480,
);

void main() {
  test('高清拍照等待对焦，选择后续清晰帧并恢复预览尺寸', () async {
    final backend = await serverBackend((socket, attempt) {
      if (attempt != 2) {
        socket.add(preview(100, 75, y: 2));
        return;
      }
      socket.add(preview(640, 480));
      Timer(const Duration(milliseconds: 180), () {
        final clear = preview(640, 480);
        for (var y = 0; y < 480; y++) {
          for (var x = 0; x < 640; x++) {
            final offset = 11 + (y * 640 + x) * 3;
            clear[offset] = clear[offset + 1] = clear[offset + 2] =
                (x ~/ 3 + y ~/ 3) % 2 == 0 ? 240 : 20;
          }
        }
        socket.add(clear);
      });
    });
    await open(backend);
    final result = await backend.captureRaw();
    final decoded = img.decodeImage(result.imageBytes!)!;
    expect(decoded.width, 640);
    expect(decoded.height, 480);
    expect(
      (decoded.getPixel(1, 1).r - decoded.getPixel(4, 1).r).abs(),
      greaterThan(150),
    );
    expect(backend.isOpen, isTrue);
  });
  test('真实预览帧可确认打开，即使服务没有打开回执', () async {
    final backend = await serverBackend((socket, _) {
      socket.add(preview(100, 75, y: 2));
    });
    await open(backend);
    expect(backend.isOpen, isTrue);
    await backend.close();
    expect(backend.isOpen, isFalse);
    await open(backend);
    expect(backend.isOpen, isTrue);
  });

  test('服务明确拒绝打开时仍报告失败', () async {
    final backend = await serverBackend((socket, _) {
      socket.add([0x55, 0x66, 0x01, 0x00]);
    });
    await expectLater(open(backend), throwsStateError);
    expect(backend.isOpen, isFalse);
  });
  test('厂商按四像素取整的预览可确认打开，空白边不算打开失败', () async {
    final backend = await serverBackend((socket, _) {
      socket.add(preview(544, 408, x: 217));
    });
    await backend.open(
      deviceIndex: 0,
      canvasW: 980,
      canvasH: 410,
      captureW: 2592,
      captureH: 1944,
    );
    expect(backend.isOpen, isTrue);
  });

  test('旧画布的小帧不能冒充新画布打开成功', () async {
    final backend = await serverBackend((socket, _) {
      socket.add(preview(40, 30));
      socket.add([0x55, 0x66, 0x01, 0x00]);
    });
    await expectLater(open(backend), throwsStateError);
    expect(backend.isOpen, isFalse);
  });

  test('打开超时清除等待状态，允许再次打开', () async {
    final backend = await serverBackend((socket, attempt) {
      if (attempt > 1) socket.add(preview(100, 75, y: 2));
    }, timeout: const Duration(milliseconds: 150));
    await expectLater(open(backend), throwsA(isA<TimeoutException>()));
    expect(backend.isOpen, isFalse);
    await open(backend);
    expect(backend.isOpen, isTrue);
  });
}
