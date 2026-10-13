// ignore_for_file: avoid_print

// OCR 原始回包调试: dart run tool/diagnostics/ocr_debug.dart <图片路径>
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:smart_scanner/core/protocol.dart';
import 'package:smart_scanner/core/ws_client.dart';

Future<void> main(List<String> args) async {
  final ws = await WsClient.connect(
    '127.0.0.1',
    22225,
    timeout: const Duration(seconds: 3),
  );
  print('已连接');

  // 心跳
  final hb = Timer.periodic(const Duration(seconds: 6), (_) {
    ws.sendBytes(KmMessage.heartbeat);
  });

  String img;
  if (args.isNotEmpty) {
    img = args[0];
  } else {
    // 开流（设备0, 画布1280x720, 采集1920x1080）
    ws.sendBytes(KmMessage.openCamera(0, 1280, 720, 1920, 1080));
    final openWaiter = Completer<void>();
    final subOpen = ws.messages.listen((m) {
      if (m.length > 3 && m[2] == 0x01 && !openWaiter.isCompleted) {
        openWaiter.complete();
      }
    });
    try {
      await openWaiter.future.timeout(const Duration(seconds: 10));
      print('开流: ok');
    } catch (_) {
      print('开流: 超时');
    }
    await subOpen.cancel();
    await Future.delayed(const Duration(seconds: 2));

    // 先拍照取一张新图
    final dir = Directory.systemTemp.createTempSync('ocr_dbg');
    img = '${dir.path}${Platform.pathSeparator}ocr_input.jpg';
    final capPackets = KmMessage.capture(img);
    for (int i = 0; i < capPackets.length; i++) {
      if (i > 0) await Future.delayed(const Duration(milliseconds: 80));
      ws.sendBytes(capPackets[i]);
    }
    final capWaiter = Completer<void>();
    final sub0 = ws.messages.listen((m) {
      if (m.length > 3 && m[2] == 0x10 && !capWaiter.isCompleted) {
        capWaiter.complete();
      }
    });
    try {
      await capWaiter.future.timeout(const Duration(seconds: 15));
    } catch (_) {}
    await sub0.cancel();
    print(
      '拍照: ${File(img).existsSync() ? '${File(img).lengthSync()} 字节' : '失败'}',
    );
  }
  print('图片: $img');
  if (!File(img).existsSync()) {
    print('图片不存在');
    exit(1);
  }

  final done = Completer<void>();
  ws.messages.listen((m) {
    if (m.length < 3) return;
    final cmd = m[2];
    final head = m.length > 24 ? m.sublist(0, 24) : m;
    print(
      '[${DateTime.now().toIso8601String().substring(11, 19)}] '
      'cmd=0x${cmd.toRadixString(16).padLeft(2, '0')} len=${m.length} '
      'head=${head.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}',
    );
    if (cmd == 0xC2 && m.length > 4) {
      final r = KmParser.parse(Uint8List.fromList(m));
      if (r is KmOcr) {
        print(
          '   -> flag=${m[3]} progress=${m[4]} ok=${r.ok} '
          'text=${r.text.length}字 ${r.text.isEmpty ? '' : r.text.substring(0, r.text.length > 40 ? 40 : r.text.length)}',
        );
        if (r.ok || m[3] != 1) {
          if (!done.isCompleted) done.complete();
        }
      }
    }
  });

  // 发送 OCR 请求（languageIndex=0）
  final packets = KmMessage.ocr(0, img, '');
  print('发送 ${packets.length} 个包');
  for (int i = 0; i < packets.length; i++) {
    if (i > 0) await Future.delayed(const Duration(milliseconds: 80));
    ws.sendBytes(packets[i]);
    print('  包$i: ${packets[i].length} 字节');
  }

  try {
    await done.future.timeout(const Duration(seconds: 120));
  } on TimeoutException {
    print('等待 120 秒无最终结果');
  }
  hb.cancel();
  ws.close();
  exit(0);
}
