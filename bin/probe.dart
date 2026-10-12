// ignore_for_file: avoid_print

// KHServer 协议冒烟测试
// 运行: dart run bin/probe.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:smart_scanner/core/ws_client.dart';

const wsUrl = 'ws://127.0.0.1:22225';

int be2(Uint8List d, int o) => (d[o] << 8) | d[o + 1];
int be3(Uint8List d, int o) => (d[o] << 16) | (d[o + 1] << 8) | d[o + 2];

void writeBmp(String path, Uint8List rgb, int w, int h) {
  // rgb: top-down, 3 bytes/px -> BMP bottom-up BGR with 4-byte row padding
  final rowStride = ((w * 3 + 3) ~/ 4) * 4;
  final dataSize = rowStride * h;
  final buf = ByteData(54 + dataSize);
  final u8 = buf.buffer.asUint8List();
  u8[0] = 0x42; u8[1] = 0x4D;
  buf.setUint32(2, 54 + dataSize, Endian.little);
  buf.setUint32(10, 54, Endian.little);
  buf.setUint32(14, 40, Endian.little);
  buf.setInt32(18, w, Endian.little);
  buf.setInt32(22, h, Endian.little);
  buf.setUint16(26, 1, Endian.little);
  buf.setUint16(28, 24, Endian.little);
  buf.setUint32(34, dataSize, Endian.little);
  for (int y = 0; y < h; y++) {
    final srcRow = y * w * 3;
    final dstRow = 54 + (h - 1 - y) * rowStride;
    for (int x = 0; x < w; x++) {
      final s = srcRow + x * 3;
      final d = dstRow + x * 3;
      u8[d] = rgb[s + 2];
      u8[d + 1] = rgb[s + 1];
      u8[d + 2] = rgb[s];
    }
  }
  File(path).writeAsBytesSync(u8);
}

Future<void> main() async {
  stdout.writeln('== KHServer 协议探针 ==');
  final WsClient chan;
  try {
    chan = await WsClient.connect('127.0.0.1', 22225);
  } catch (e) {
    stdout.writeln('!! 连接失败: $e');
    exit(1);
  }
  final ctrl = StreamController<Uint8List>();
  chan.messages.listen(ctrl.add,
      onDone: () => stdout.writeln('[ws] closed'));
  chan.closes.listen((why) => stdout.writeln('[ws] $why'));

  final frames = <Uint8List>[];
  int frameBytes = 0;
  int frameCount = 0;
  bool gotDevices = false, gotRes = false, opened = false;
  Uint8List? captureBytes;

  final heart = Timer.periodic(const Duration(seconds: 6), (_) {
    chan.sendBytes([0x11, 0x11, 0x11]);
  });

  Future<void> send(List<int> b) async {
    chan.sendBytes(b);
  }

  final sub = ctrl.stream.listen((d) {
    if (d.length < 3) return;
    if (d[0] == 0x11 && d[1] == 0x11 && d[2] == 0x11) {
      stdout.writeln('[srv] heartbeat-ack');
      return;
    }
    if (d[0] != 0x55 || d[1] != 0x66) {
      stdout.writeln('[srv] unknown header ${d[0]} ${d[1]} len=${d.length}');
      return;
    }
    final cmd = d[2];
    switch (cmd) {
      case 0x50:
        gotDevices = true;
        final count = d[3];
        final names = utf8.decode(d.sublist(4), allowMalformed: true);
        stdout.writeln('[srv] devices($count): $names');
        break;
      case 0x51:
        gotRes = true;
        final count = d[3];
        final res = <String>[];
        for (int i = 0; i < count; i++) {
          res.add('${be2(d, 4 + i * 4)}*${be2(d, 6 + i * 4)}');
        }
        stdout.writeln('[srv] resolutions($count): ${res.join(', ')}');
        break;
      case 0x01:
        opened = d[3] == 0x01;
        stdout.writeln('[srv] open status: ${d[3] == 0x01 ? "OK" : "FAIL(${d[3]})"}');
        break;
      case 0x10:
        final flag = d[3];
        if (flag == 0x01) {
          final pathLen = be2(d, 4);
          final b64Len = be3(d, 6);
          final path = pathLen > 0
              ? Uri.decodeComponent(String.fromCharCodes(d.sublist(9, 9 + pathLen)))
              : '';
          final b64 = String.fromCharCodes(d.sublist(9 + pathLen, 9 + pathLen + b64Len));
          stdout.writeln('[srv] capture OK path="$path" b64Len=$b64Len');
          try {
            captureBytes = base64.decode(b64);
          } catch (e) {
            stdout.writeln('  base64 decode failed: $e');
          }
        } else {
          stdout.writeln('[srv] capture FAIL flag=$flag');
        }
        break;
      case 0xcc:
        frameCount++;
        frameBytes += d.length;
        if (frames.length < 60) frames.add(d);
        break;
      default:
        stdout.writeln('[srv] cmd=0x${cmd.toRadixString(16)} len=${d.length}');
    }
  });

  // 1. 枚举设备 (最长等5秒)
  await send([0x77, 0x88, 0x50]);
  for (int i = 0; i < 50 && !gotDevices; i++) {
    await Future.delayed(const Duration(milliseconds: 100));
  }
  if (!gotDevices) {
    stdout.writeln('!! 未收到设备列表 —— KHServer 未运行?');
    heart.cancel();
    chan.close();
    exit(1);
  }

  // 2. 分辨率
  await send([0x77, 0x88, 0x51, 0x00]);
  for (int i = 0; i < 50 && !gotRes; i++) {
    await Future.delayed(const Duration(milliseconds: 100));
  }
  if (!gotRes) {
    stdout.writeln('!! 未收到分辨率列表');
    heart.cancel();
    chan.close();
    exit(1);
  }

  // 3. 打开摄像头: canvas 640x480, 采集 2592x1944 (demo默认)
  const cw = 640, ch = 480, capW = 2592, capH = 1944;
  await send([
    0x77, 0x88, 0x01, 0x00,
    cw >> 8, cw & 0xff, ch >> 8, ch & 0xff,
    capW >> 8, capW & 0xff, capH >> 8, capH & 0xff,
  ]);
  await Future.delayed(const Duration(milliseconds: 2500));
  if (!opened) {
    stdout.writeln('!! 打开摄像头失败');
    heart.cancel();
    chan.close();
    exit(1);
  }
  stdout.writeln('[preview] frames in 2.5s: $frameCount, total ${(frameBytes / 1048576).toStringAsFixed(2)} MB');

  // 分析帧结构
  for (final f in frames.take(3)) {
    if (f[2] == 0xcc && f.length > 11) {
      final w = be2(f, 3), h = be2(f, 5), x = be2(f, 7), y = be2(f, 9);
      final expect = w * h * 3 + 11;
      stdout.writeln('[frame] ${w}x$h @($x,$y) bytes=${f.length} expect=$expect');
    }
  }

  // 合成第一张画布并写BMP
  final canvas = Uint8List(cw * ch * 3);
  int painted = 0;
  for (final f in frames) {
    if (f[2] != 0xcc || f.length < 11) continue;
    final w = be2(f, 3), h = be2(f, 5), x = be2(f, 7), y = be2(f, 9);
    if (x + w > cw || y + h > ch) continue;
    for (int row = 0; row < h; row++) {
      final src = 11 + row * w * 3;
      final dst = ((y + row) * cw + x) * 3;
      canvas.setRange(dst, dst + w * 3, f, src);
    }
    painted++;
  }
  if (painted > 0) {
    writeBmp('probe_frame.bmp', canvas, cw, ch);
    stdout.writeln('[preview] 合成 $painted 块 -> probe_frame.bmp');
  }

  // 4. 拍照 (不带路径, 服务端返回 base64)
  await send([
    0x77, 0x88, 0x10, 0x00,
    0, 0, 0, // path len = 0
    0, 1, // packageCount = 1
    0, 0, // 分包长度
    0, 0, // 包序号
  ]);
  await Future.delayed(const Duration(seconds: 6));
  if (captureBytes != null) {
    File('probe_capture.bin').writeAsBytesSync(captureBytes!);
    final head = captureBytes!.sublist(0, 4);
    stdout.writeln('[capture] ${captureBytes!.length} bytes, magic=${head.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
  } else {
    stdout.writeln('!! 未收到拍照结果');
  }

  // 5. 关闭
  await send([0x77, 0x88, 0x02, 0x00]);
  await Future.delayed(const Duration(milliseconds: 300));
  await send([0x77, 0x88, 0xFF]);
  heart.cancel();
  await sub.cancel();
  chan.close();
  stdout.writeln('== 探针结束 ==');
  exit(0);
}
