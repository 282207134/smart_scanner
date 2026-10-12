// ignore_for_file: avoid_print

// OCR 参数变体探针: dart run bin/ocr_probe.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:smart_scanner/core/protocol.dart';
import 'package:smart_scanner/core/ws_client.dart';

late WsClient ws;
final _log = <String>[];

void logMsg(Uint8List m) {
  if (m.length < 3) return;
  final cmd = m[2];
  final head = m.length > 20 ? m.sublist(0, 20) : m;
  final hex = head.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  _log.add('cmd=0x${cmd.toRadixString(16)} len=${m.length} [$hex]');
}

/// 等待不含 0xCC 的响应（或超时）
Future<List<String>> collect(Duration window) async {
  _log.clear();
  await Future.delayed(window);
  // 过滤掉预览帧噪声
  return _log.where((s) => !s.contains('cmd=0xcc')).toList();
}

Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('ocr_probe');
  ws = await WsClient.connect('127.0.0.1', 22225,
      timeout: const Duration(seconds: 3));
  ws.messages.listen(logMsg);
  Timer.periodic(const Duration(seconds: 6), (_) => ws.sendBytes(KmMessage.heartbeat));
  print('已连接');

  // 开流并等待服务端确认
  final opened = Completer<void>();
  final sub = ws.messages.listen((m) {
    if (m.length > 3 && m[2] == 0x01 && !opened.isCompleted) opened.complete();
  });
  ws.sendBytes(KmMessage.openCamera(0, 1280, 720, 1920, 1080));
  try {
    await opened.future.timeout(const Duration(seconds: 10));
    print('开流: ok');
  } catch (_) {
    print('开流: 超时');
    exit(1);
  }
  await sub.cancel();
  await Future.delayed(const Duration(milliseconds: 2500));

  // 拍一张
  final img = '${dir.path}\\t.jpg';
  final captured = Completer<void>();
  final sub2 = ws.messages.listen((m) {
    if (m.length > 3 && m[2] == 0x10 && !captured.isCompleted) {
      print('  拍照回包: len=${m.length} flag=${m[3]}');
      captured.complete();
    }
  });
  for (final p in KmMessage.capture(img)) {
    ws.sendBytes(p);
    await Future.delayed(const Duration(milliseconds: 60));
  }
  try {
    await captured.future.timeout(const Duration(seconds: 15));
  } catch (_) {
    print('  拍照回包: 超时');
  }
  await sub2.cancel();
  await Future.delayed(const Duration(seconds: 1));
  print('拍照: ${File(img).existsSync() ? '${File(img).lengthSync()}B' : '失败'}\n');

  // 变体1: language=0, txt 输出
  final out1 = '${dir.path}\\out1.txt';
  print('--- 变体1: 0xC2 lang=0 txt=$out1');
  for (final p in KmMessage.ocr(0, img, out1)) {
    ws.sendBytes(p);
    await Future.delayed(const Duration(milliseconds: 80));
  }
  print((await collect(const Duration(seconds: 25))).join('\n'));
  print('输出文件: ${File(out1).existsSync() ? '${File(out1).lengthSync()}B' : '无'}\n');

  // 变体2: language=1
  final out2 = '${dir.path}\\out2.txt';
  print('--- 变体2: 0xC2 lang=1 txt=$out2');
  for (final p in KmMessage.ocr(1, img, out2)) {
    ws.sendBytes(p);
    await Future.delayed(const Duration(milliseconds: 80));
  }
  print((await collect(const Duration(seconds: 25))).join('\n'));
  print('输出文件: ${File(out2).existsSync() ? '${File(out2).lengthSync()}B' : '无'}\n');

  // 变体3: 0xC4 OcrCallProEx (目录, 不删源) —— 把图放进目录
  if (!File(img).existsSync()) {
    print('无图片，跳过变体3');
    exit(1);
  }
  final subDir = Directory('${dir.path}\\batch')..createSync();
  File(img).copySync('${subDir.path}\\a.jpg');
  print('--- 变体3: 0xC4 lang=0 outpath=${subDir.path}');
  // 0xC4: [77 88 C4 lang delSrc len(3) pkgCount(2) chunk(1) pindex(2) ...]
  final body = KmMessage.encodePath(subDir.path);
  final packets = KmMessage.chunked(0xC4, [
    0x00, // language
    0x00, // isDelSrcFile
    body.length >> 16 & 0xff, body.length >> 8 & 0xff, body.length & 0xff,
  ], body);
  for (final p in packets) {
    ws.sendBytes(p);
    await Future.delayed(const Duration(milliseconds: 80));
  }
  print((await collect(const Duration(seconds: 25))).join('\n'));

  print('\n目录 ${dir.path}:');
  for (final f in dir.listSync(recursive: true)) {
    print('  $f ${f is File ? '(${f.lengthSync()}B)' : ''}');
  }
  exit(0);
}
